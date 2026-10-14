#!/usr/bin/env bash
# scripts/lib/tripwire.sh — zero-token tripwires (Section 4) run after every Tier 3 pass.
# tripwire_snapshot TASK before the pass; tripwire_check TASK [--skip-remote] after it.
# Any failure => task QUARANTINED, worktree preserved, merge blocked, Surgery triggered.
[[ -n "${__FLEET_TRIPWIRE_LOADED:-}" ]] && return 0
__FLEET_TRIPWIRE_LOADED=1
# shellcheck source=worktree.sh
source "$(dirname "${BASH_SOURCE[0]}")/worktree.sh"

MANIFEST_GLOBS=('package.json' '*/package.json' 'pnpm-lock.yaml' 'package-lock.json' 'yarn.lock' 'pnpm-workspace.yaml'
                'pyproject.toml' '*/pyproject.toml' 'uv.lock' 'poetry.lock' 'requirements*.txt' 'Cargo.toml' 'Cargo.lock')

_tw_dir() { printf '%s/tripwire-%s' "$TMP_DIR" "$1"; }
# Root status minus the paths orchestrate.sh itself writes between snapshot and check (ledger, STATE,
# task frontmatter, reviews, reports). Everything else in the root must be byte-for-byte unchanged.
ORCH_OWNED_RE='^.. (\.agents/(ledger\.json|STATE\.md|tasks/|reviews/|frozen\.sha256|frozen\.list|layers\.yaml)|docs/(PROGRESS\.md|reports/))'
_root_status() { git -C "$ROOT" status --porcelain --untracked-files=all | grep -Ev "$ORCH_OWNED_RE" || true; }
_sibling_status() {  # status + HEAD of every worktree except the task's own
  local t="$1" w
  for w in $(wt_list); do
    [[ "$w" == "$(wt_dir "$t")" ]] && continue
    echo "## $w $(git -C "$w" rev-parse HEAD 2>/dev/null)"
    git -C "$w" status --porcelain --untracked-files=all 2>/dev/null
  done
}
_manifest_hashes() {
  local d; d="$(wt_dir "$1")"
  (cd "$d" && git ls-files -- "${MANIFEST_GLOBS[@]}" 2>/dev/null | sort -u | xargs -r shasum -a 256)
}

tripwire_snapshot() {  # tripwire_snapshot TASK
  local t="$1" s; s="$(_tw_dir "$t")"; mkdir -p "$s"
  main_sha > "$s/main.sha"
  remote_main_sha > "$s/remote.sha"
  _root_status > "$s/root.status"
  _sibling_status "$t" > "$s/siblings.status"
  _manifest_hashes "$t" > "$s/manifests.sha"
  log "tripwire snapshot taken for $t"
}

# ---- dependency diffing: every NEW dependency must be in APPROVED_DEPS -------
_dep_names_ts() {   # _dep_names_ts <json-file-or-"-"> : dependency names from a package.json
  jq -r '((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}) + (.optionalDependencies // {})) | keys[]' "$1" 2>/dev/null
}
_dep_names_py() {   # pyproject [project].dependencies + optional-dependencies + dependency-groups
  yq -p toml -o json '.' "$1" 2>/dev/null | jq -r '
    [(.project.dependencies // []), ((.project."optional-dependencies" // {}) | to_entries[].value),
     ((."dependency-groups" // {}) | to_entries[].value), ((.tool.poetry.dependencies // {}) | keys)] | flatten[]
    | if type=="object" then (.include // "") else . end' 2>/dev/null | sed -E 's/^[[:space:]]*([A-Za-z0-9_.-]+).*/\1/' | tr 'A-Z_' 'a-z-' | sed '/^$/d'
}
_new_deps() {  # _new_deps TASK -> names present in the worktree manifests but not in main's
  local t="$1" d f base wt kind; d="$(wt_dir "$t")"
  for f in $(cd "$d" && git ls-files -- 'package.json' '*/package.json' 'pyproject.toml' '*/pyproject.toml' 2>/dev/null); do
    git -C "$d" diff --quiet "$(base_branch)" -- "$f" 2>/dev/null && [[ -z "$(git -C "$d" ls-files --others --exclude-standard -- "$f")" ]] && continue
    case "$f" in *package.json) kind=ts ;; *) kind=py ;; esac
    base="$(mktemp "$TMP_DIR/dep.XXXXXX")"; wt="$d/$f"
    git -C "$d" show "$(base_branch):$f" > "$base" 2>/dev/null || : > "$base"
    if [[ $kind == ts ]]; then comm -13 <(_dep_names_ts "$base" | sort -u) <(_dep_names_ts "$wt" | sort -u)
    else comm -13 <(_dep_names_py "$base" | sort -u) <(_dep_names_py "$wt" | sort -u); fi
    rm -f "$base"
  done | sort -u
}
_manifests_ok() {  # unchanged, or every new dep approved
  local t="$1" s="$2" approved new n ok=0
  diff -q <(_manifest_hashes "$t") "$s/manifests.sha" >/dev/null 2>&1 && return 0
  approved="$(task_approved_deps "$t" | sed -E 's/[<>=!~@[:space:]].*//' | tr 'A-Z_' 'a-z-' | sort -u)"
  [[ -z "$approved" ]] && { echo "manifest changed but APPROVED_DEPS is empty"; return 1; }
  new="$(_new_deps "$t")"
  for n in $new; do
    grep -qx "$(printf '%s' "$n" | tr 'A-Z_' 'a-z-')" <<<"$approved" || { echo "unapproved dependency: $n"; ok=1; }
  done
  return $ok
}

# tripwire_check TASK [--skip-remote] -> prints "TRIPWIRE: PASS" or "TRIPWIRE: <reason>" as last line
tripwire_check() {
  local t="$1" skip_remote=0 s fail="" d; [[ "${2:-}" == "--skip-remote" ]] && skip_remote=1
  s="$(_tw_dir "$t")"; d="$(wt_dir "$t")"
  [[ -d "$s" ]] || { echo "TRIPWIRE: no snapshot for $t"; return 1; }
  [[ "$(main_sha)" == "$(cat "$s/main.sha")" ]] || fail="main HEAD changed during the pass"
  if [[ -z "$fail" && $skip_remote -eq 0 ]]; then
    [[ "$(remote_main_sha)" == "$(cat "$s/remote.sha")" ]] || fail="remote main changed during the pass"
  fi
  [[ -z "$fail" ]] && { diff -q <(_root_status) "$s/root.status" >/dev/null 2>&1 || fail="root repository working tree changed"; }
  [[ -z "$fail" ]] && { diff -q <(_sibling_status "$t") "$s/siblings.status" >/dev/null 2>&1 || fail="a sibling worktree changed"; }
  [[ -z "$fail" ]] && { frozen_verify "$ROOT" || fail="frozen.sha256 mismatch in root"; }
  [[ -z "$fail" && -d "$d" ]] && { frozen_verify "$d" || fail="frozen contract/acceptance test modified in worktree"; }
  if [[ -z "$fail" && -d "$d" ]]; then
    local why; why="$(_manifests_ok "$t" "$s")" || fail="manifest/lockfile: ${why:-changed}"
  fi
  if [[ -z "$fail" ]]; then echo "TRIPWIRE: PASS"; return 0; fi
  echo "TRIPWIRE: $fail"; return 1
}

# tripwire_quarantine TASK <reason> — the Section 4 consequence
tripwire_quarantine() {
  local t="$1" why="$2"
  set_status "$t" QUARANTINED tripwire "$why"
  ledger_incident QUARANTINED "$(task_layer "$t")" "$t: $why" "$t"
  wt_preserve "$t" "$why"
  ntfy_send "QUARANTINED $t" "$why" high
}
