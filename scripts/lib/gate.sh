#!/usr/bin/env bash
# scripts/lib/gate.sh — zero-token pre-review gate (Section 3), run inside the task worktree.
# gate_run TASK -> 0/1. Output goes to .agents/logs/gate-TASK.log only; the failing step and a
# short tail are written to .agents/tmp/gate-TASK.reason for re-dispatch prompts.
[[ -n "${__FLEET_GATE_LOADED:-}" ]] && return 0
__FLEET_GATE_LOADED=1
# shellcheck source=worktree.sh
source "$(dirname "${BASH_SOURCE[0]}")/worktree.sh"

GATE_ANTICHEAT_RULES="$RULES_DIR/anti-cheat.yml"
COMMENT_MARK_RE='@ts-ignore|@ts-expect-error|@ts-nocheck|eslint-disable|type:[[:space:]]*ignore|#[[:space:]]*noqa|NotImplementedError|\.skip\(|\.only\(|\bTODO\b|\bFIXME\b|\bXXX\b'

_g() { printf '%s\n' "$*" >> "$GATE_LOG"; }
_gfail() { _g "GATE: FAIL $1: $2"; printf '%s: %s\n' "$1" "$2" > "$GATE_REASON"; tail -n 40 "$GATE_LOG" | cut -c1-300 >> "$GATE_REASON"; return 1; }

# added lines of the worktree vs main as "file:line" (untracked files included via intent-to-add)
_added_lines() {
  git -C "$WT" diff -U0 --no-color "$(wt_base "$WT")" -- . ':(exclude)node_modules' ':(exclude).venv' |
    awk '/^\+\+\+ b\//{f=substr($0,7)} /^@@/{split($3,a,","); s=substr(a[1],2); n=(a[2]==""?1:a[2]); for(i=0;i<n;i++) print f":"(s+i)}'
}

gate_just_check() {
  _g "== just check"
  local rc=0
  have just || { _gfail "just-check" "just not installed"; return 1; }
  (cd "$WT" && run_with_timeout "$(tier_timeout gate)" "$GATE_LOG" -- just check) || rc=$?
  [[ $rc -eq 0 ]] && return 0
  [[ $rc -eq 124 ]] && _gfail "just-check" "timed out after $(tier_timeout gate)s" && return 1
  _gfail "just-check" "exit $rc"
}

gate_ownership() {
  _g "== ownership"
  local f bad=""
  mapfile -t owned < <(task_owned_files "$TASK")
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local ok=0 o; for o in "${owned[@]}"; do [[ "$f" == "$o" ]] && ok=1 && break; done
    [[ $ok -eq 1 ]] || bad+="$f "
  done < <(wt_changed_files "$TASK")
  [[ -z "$bad" ]] && return 0
  _gfail "ownership" "changed outside OWNED_FILES: $bad"
}

gate_anti_cheat() {
  _g "== anti-cheat (added lines only)"
  local added hits="" f
  added="$(_added_lines)"; [[ -z "$added" ]] && return 0
  mapfile -t files < <(printf '%s\n' "$added" | cut -d: -f1 | sort -u)
  if have ast-grep; then
    hits="$(cd "$WT" && ast-grep scan --rule "$GATE_ANTICHEAT_RULES" --json=compact "${files[@]}" 2>>"$GATE_LOG" |
      jq -r '.[] | "\(.file):\(.range.start.line + 1) \(.ruleId)"' 2>/dev/null | grep -Ff <(printf '%s\n' "$added" | sed 's/$/ /') || true)"
  fi
  # grep fallback for languages ast-grep cannot parse (shell, vue, svelte, config)
  for f in "${files[@]}"; do
    case "$f" in *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py) have ast-grep && continue ;; esac
    hits+="$(git -C "$WT" diff -U0 --no-color "$(wt_base "$WT")" -- "$f" | grep -E '^\+[^+]' | grep -nE "$COMMENT_MARK_RE" | sed "s|^|$f:+|" || true)"
  done
  hits="$(printf '%s' "$hits" | sed '/^$/d')"
  [[ -z "$hits" ]] && return 0
  _g "$hits"; _gfail "anti-cheat" "$(printf '%s' "$hits" | head -n 5 | tr '\n' ';')"
}

gate_line_limit() {
  _g "== line limit ($LINE_LIMIT)"
  local f n bad=""
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$WT/$f" ]] && continue
    line_limit_excluded "$f" && continue
    n="$(wc -l < "$WT/$f" | tr -d ' ')"; [[ "$n" -gt "$LINE_LIMIT" ]] && bad+="$f($n) "
  done < <(wt_changed_files "$TASK")
  [[ -z "$bad" ]] && return 0
  _gfail "line-limit" "over $LINE_LIMIT lines: $bad"
}

# Layer boundaries generated from the ```yaml boundaries``` block in SYSTEM_SPEC.md:
#   layers: [{name, path|module, may_import: [names]}]
_boundaries_yaml() { awk 'BEGIN{p=0} /^```yaml boundaries[[:space:]]*$/{p=1;next} p&&/^```/{exit} p{print}' "$SPEC_FILE" 2>/dev/null; }
gate_boundaries() {
  _g "== layer boundaries"
  local y rc=0; y="$(_boundaries_yaml)"; [[ -z "$y" ]] && { _g "no boundaries block in SYSTEM_SPEC.md; skipped"; return 0; }
  local cfg="$TMP_DIR/boundaries-$TASK"
  if is_ts; then
    printf '%s' "$y" | yq -o=json '.' | jq '{forbidden: [ .layers as $L | $L[] as $a | $L[] as $b
        | select($a.name != $b.name and (($a.may_import // []) | index($b.name) | not))
        | {name: ($a.name+"->"+$b.name), severity:"error", from:{path:("^"+$a.path+"/")}, to:{path:("^"+$b.path+"/")}} ],
      options:{doNotFollow:{path:"node_modules"}, tsPreCompilationDeps:true, tsConfig:(if $ts then {fileName:"tsconfig.json"} else null end)}}' \
      --argjson ts "$([[ -f "$WT/tsconfig.json" ]] && echo true || echo false)" > "$cfg.json"
    mapfile -t dirs < <(printf '%s' "$y" | yq -r '.layers[].path')
    (cd "$WT" && depcruise --config "$cfg.json" --output-type err "${dirs[@]}") >>"$GATE_LOG" 2>&1 || rc=1
  elif is_py; then
    { echo "[importlinter]"; echo "root_packages ="; printf '%s' "$y" | yq -r '.layers[].module' | cut -d. -f1 | sort -u | sed 's/^/    /'
      printf '%s' "$y" | yq -o=json '.' | jq -r '.layers as $L | $L[] as $a | $L[] as $b
        | select($a.name != $b.name and (($a.may_import // []) | index($b.name) | not))
        | "\n[importlinter:contract:\($a.name)-\($b.name)]\nname = \($a.name) must not import \($b.name)\ntype = forbidden\nsource_modules = \($a.module)\nforbidden_modules = \($b.module)"'; } > "$cfg.ini"
    (cd "$WT" && lint-imports --config "$cfg.ini") >>"$GATE_LOG" 2>&1 || rc=1
  fi
  [[ $rc -eq 0 ]] && return 0
  _gfail "boundaries" "layer boundary violation (see gate log)"
}

gate_secrets() {
  _g "== gitleaks (diff vs main)"
  have gitleaks || { [[ "$FLEET_DRY_RUN" == 1 ]] && { _g "gitleaks missing: skipped (dry-run only)"; return 0; }; _gfail "gitleaks" "gitleaks not installed"; return 1; }
  if git -C "$WT" diff --no-color "$(wt_base "$WT")" | gitleaks stdin --no-banner --redact --exit-code 1 >>"$GATE_LOG" 2>&1; then return 0; fi
  _gfail "gitleaks" "secret detected in diff"
}

gate_run() {  # gate_run TASK
  TASK="$1"; WT="$(wt_dir "$TASK")"; GATE_LOG="$LOG_DIR/gate-$TASK.log"; GATE_REASON="$TMP_DIR/gate-$TASK.reason"
  : > "$GATE_REASON"; echo "=== gate $TASK $(now)" >> "$GATE_LOG"
  wt_stage_all "$TASK"
  gate_ownership && gate_line_limit && gate_anti_cheat && gate_secrets && gate_boundaries && gate_just_check || return 1
  _g "GATE: PASS"; rm -f "$GATE_REASON"; return 0
}

# Post-merge gate on main (Section 3): just check only; boundaries/anti-cheat were checked pre-merge.
gate_main() {
  local logf="$LOG_DIR/gate-main-$(date +%s).log"
  (cd "$ROOT" && run_with_timeout "$(tier_timeout gate)" "$logf" -- just check) && return 0
  echo "$logf"; return 1
}

# Layer-level deterministic pre-audit (Phase B): dead code + optional mutation sample; summary lines only.
gate_layer_summary() {  # gate_layer_summary <layer> -> prints <=12 summary lines
  local l="$1" logf="$LOG_DIR/layer-$1-preaudit.log" sample; sample="$(idea_get '.quality.mutation_sampling' false)"
  if is_ts; then
    (cd "$ROOT" && knip --no-progress --reporter compact) >"$logf" 2>&1 || true
    echo "knip: $(grep -cE '^[^ ]' "$logf" 2>/dev/null || echo 0) finding line(s)"; head -n 6 "$logf" | cut -c1-200
    [[ "$sample" == true ]] && { (cd "$ROOT" && npx --no-install stryker run --reporters clear-text 2>&1 | grep -E 'All files|mutation score' | tail -n 2) || echo "stryker: not run"; }
  elif is_py; then
    (cd "$ROOT" && vulture . --min-confidence 80 --exclude .venv,node_modules) >"$logf" 2>&1 || true
    echo "vulture: $(wc -l < "$logf" | tr -d ' ') finding(s)"; head -n 6 "$logf" | cut -c1-200
    [[ "$sample" == true ]] && { (cd "$ROOT" && mutmut run --max-children 2 >/dev/null 2>&1; mutmut results 2>/dev/null | tail -n 3) || echo "mutmut: not run"; }
  else
    echo "pre-audit: no stack-specific dead-code tool for stack '$(stack)'"
  fi
}
