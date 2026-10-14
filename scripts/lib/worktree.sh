#!/usr/bin/env bash
# scripts/lib/worktree.sh — sibling worktrees (../<repo>.wt/TASK on agent/TASK) with per-worktree installs.
[[ -n "${__FLEET_WORKTREE_LOADED:-}" ]] && return 0
__FLEET_WORKTREE_LOADED=1
# shellcheck source=ledger.sh
source "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

WT_LOG="$LOG_DIR/worktree.log"

wt_exists() { local d; d="$(wt_dir "$1")"; [[ -d "$d" ]] && git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# wt_create TASK — fresh worktree on a fresh agent/TASK branch from main (old one is discarded)
wt_create() {
  local t="$1" d; d="$(wt_dir "$t")"; mkdir -p "$WT_ROOT"
  wt_exists "$t" && wt_remove "$t"
  [[ -e "$d" ]] && rm -rf "$d"
  git -C "$ROOT" worktree prune >>"$WT_LOG" 2>&1
  git -C "$ROOT" branch -D "agent/$t" >>"$WT_LOG" 2>&1 || true
  git -C "$ROOT" worktree add "$d" -b "agent/$t" "$(base_branch)" >>"$WT_LOG" 2>&1 || die "worktree add failed for $t (see .agents/logs/worktree.log)"
  task_set "$t" '.worktree=$w | .branch=$b' --arg w "$d" --arg b "agent/$t"
  wt_install_deps "$t"
  log "worktree ready: $d (agent/$t @ $(git -C "$d" rev-parse --short HEAD))"
}

# wt_ensure TASK — reuse an existing worktree (review-fix rounds), else create
wt_ensure() { wt_exists "$1" && return 0; wt_create "$1"; }

# Per-worktree dependency install (Section 3). Symlinking root deps is only safe
# for a flat single-package repo with no editable installs (IDEA.md repo.symlink_root_deps).
wt_install_deps() {
  local t="$1" d symlink; d="$(wt_dir "$t")"; symlink="$(idea_get '.repo.symlink_root_deps' false)"
  case "$(stack)" in
    ts)
      if [[ "$symlink" == true && -d "$ROOT/node_modules" ]]; then
        ln -sfn "$ROOT/node_modules" "$d/node_modules"
      else
        (cd "$d" && pnpm install --offline --frozen-lockfile) >>"$WT_LOG" 2>&1 \
          || (cd "$d" && pnpm install --prefer-offline --frozen-lockfile) >>"$WT_LOG" 2>&1 \
          || die "pnpm install failed in $d"
      fi ;;
    python)
      if [[ "$symlink" == true && -d "$ROOT/.venv" ]]; then
        ln -sfn "$ROOT/.venv" "$d/.venv"
      else
        (cd "$d" && uv sync --frozen) >>"$WT_LOG" 2>&1 || die "uv sync failed in $d"
      fi ;;
    *) : ;;
  esac
}

# wt_remove TASK — remove worktree and local branch; keeps nothing (use wt_preserve for QUARANTINED)
wt_remove() {
  local t="$1" d; d="$(wt_dir "$t")"
  git -C "$ROOT" worktree remove --force "$d" >>"$WT_LOG" 2>&1 || rm -rf "$d"
  git -C "$ROOT" worktree prune >>"$WT_LOG" 2>&1
  git -C "$ROOT" branch -D "agent/$t" >>"$WT_LOG" 2>&1 || true
  task_exists "$t" && task_set "$t" '.worktree=null'
  return 0
}

# wt_preserve TASK — keep the worktree for human inspection; detach it from the ledger's active set
wt_preserve() {
  local t="$1" d; d="$(wt_dir "$t")"
  [[ -d "$d" ]] || return 0
  printf 'preserved at %s for inspection (%s)\n' "$(now)" "${2:-quarantine}" > "$d/.QUARANTINED"
  log "worktree preserved for inspection: $d"
}

# wt_stage_all TASK — make every change (incl. new files) visible to `git diff main`
wt_stage_all() { local d; d="$(wt_dir "$1")"; git -C "$d" add -A -N . >>"$WT_LOG" 2>&1; }

# wt_changed_files TASK — every path that differs from main (committed, staged, unstaged, untracked)
wt_changed_files() {
  local d; d="$(wt_dir "$1")"
  { git -C "$d" diff --name-only "$(base_branch)" HEAD
    git -C "$d" diff --name-only HEAD
    git -C "$d" ls-files --others --exclude-standard; } 2>/dev/null | sed '/^$/d' | sort -u
}

# wt_commit TASK <message> — orchestrate.sh is the only committer; returns the new SHA
wt_commit() {
  local t="$1" msg="$2" d; d="$(wt_dir "$t")"
  git -C "$d" add -A >>"$WT_LOG" 2>&1
  if git -C "$d" diff --cached --quiet; then log "nothing to commit for $t"; git -C "$d" rev-parse HEAD; return 0; fi
  git -C "$d" -c user.name="fleet-bot" -c user.email="fleet-bot@localhost" commit -q -m "$msg" >>"$WT_LOG" 2>&1 || die "commit failed for $t"
  git -C "$d" rev-parse HEAD
}

# wt_clean_all — remove every task worktree whose task is MERGED (post-run hygiene)
wt_clean_all() {
  local w t
  for w in $(wt_list); do
    t="$(basename "$w")"
    [[ -f "$w/.QUARANTINED" ]] && continue
    task_exists "$t" && [[ "$(task_status "$t")" == MERGED ]] && wt_remove "$t"
  done
}
