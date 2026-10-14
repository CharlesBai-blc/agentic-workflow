#!/usr/bin/env bash
# scripts/lib/compile-prompt.sh — zero-token prompt builder (Section 1.7).
# Layout, most static first for prefix-cache hits:
#   AGENTS.md -> skill(s) -> contracts -> role template -> task/layer context -> attempt extras -> repomix pack
# Library use:  compile_prompt <role> <id> <outfile> [--extra FILE]...
# CLI use:      scripts/lib/compile-prompt.sh <role> <id> <outfile> [--extra FILE]...
# roles: tier1 phase_a phase_b surgery coder reviewer closeout narrative
[[ -n "${__FLEET_COMPILE_LOADED:-}" ]] && return 0 2>/dev/null
__FLEET_COMPILE_LOADED=1
# shellcheck source=ledger.sh
source "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"
TEMPLATE_DIR="$ROOT/scripts/prompts"

_sec() { printf '\n\n<!-- ========== %s ========== -->\n\n' "$1"; }
_file() { [[ -f "$1" ]] && { _sec "FILE: $2"; cat "$1"; }; }
_skill() { _file "$SKILL_DIR/$1/SKILL.md" ".agents/skills/$1/SKILL.md"; }
_role_skills() {
  case "$1" in
    tier1) echo "01-spec-writing 07-archify-diagramming" ;; phase_a) echo "02-task-slicing 09-acceptance-tests" ;;
    phase_b) echo "05-code-review" ;; surgery) echo "10-failure-triage 02-task-slicing 09-acceptance-tests" ;;
    coder) echo "04-code-execution 10-failure-triage" ;; reviewer) echo "05-code-review" ;;
    closeout) echo "07-archify-diagramming" ;; narrative) echo "08-progress-narrative" ;;
  esac
}
_template() {  # _template <role> <id> : substitute {{VARS}} in scripts/prompts/<role>.md
  local role="$1" id="$2" tf="$TEMPLATE_DIR/$role.md" layer wt attempt effort
  [[ -f "$tf" ]] || die "missing prompt template $tf"
  case "$role" in coder|reviewer) layer="$(task_layer "$id")"; wt="$(wt_dir "$id")" ;; *) layer="$id"; wt="$ROOT" ;; esac
  attempt=1; task_exists "$id" 2>/dev/null && attempt=$(( $(task_get "$id" '.strikes // 0') + 1 ))
  effort=medium; [[ "$role" == reviewer && "$(task_risk "$id")" == high ]] && effort=high
  sed -e "s|{{TASK}}|$id|g" -e "s|{{LAYER}}|$layer|g" -e "s|{{WT}}|$wt|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{BASE}}|$(base_branch)|g" \
      -e "s|{{ATTEMPT}}|$attempt|g" -e "s|{{EFFORT}}|$effort|g" -e "s|{{REPO}}|$REPO_NAME|g" -e "s|{{TAG}}|$(layer_tag "$layer")|g" \
      -e "s|{{PROJECT}}|$(idea_get '.project' "$REPO_NAME")|g" "$tf"
}
_contracts_for_task() {  # frozen contracts + acceptance tests in READONLY_FILES (static per layer)
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if is_contract_path "$f" || grep -qx "$f" "$FROZEN_FILE" 2>/dev/null || grep -q " $f\$" "$FROZEN_FILE" 2>/dev/null; then _file "$ROOT/$f" "$f"; fi
  done < <(task_readonly_files "$1")
}
_pack_allowlist() {  # _pack_allowlist TASK : repomix pack of the non-contract readonly files + existing owned files, run in the worktree
  local t="$1" wt f list=() tmp
  wt="$(wt_dir "$t")"; [[ -d "$wt" ]] || wt="$ROOT"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_contract_path "$f" && continue; grep -q " $f\$" "$FROZEN_FILE" 2>/dev/null && continue
    [[ -f "$wt/$f" ]] && list+=("$f")
  done < <(task_readonly_files "$t")
  while IFS= read -r f; do [[ -n "$f" && -f "$wt/$f" ]] && list+=("$f"); done < <(task_owned_files "$t")
  [[ ${#list[@]} -eq 0 ]] && return 0
  _sec "ALLOWLIST PACK (${#list[@]} files; read nothing else)"
  tmp="$(mktemp "$TMP_DIR/pack.XXXXXX")"
  if have repomix && (cd "$wt" && repomix --include "$(IFS=,; echo "${list[*]}")" --style markdown --output "$tmp" \
        --no-file-summary --no-directory-structure --no-security-check --quiet >>"$LOG_DIR/repomix.log" 2>&1); then
    cat "$tmp"
  else
    for f in "${list[@]}"; do printf '\n## File: %s\n```\n' "$f"; cat "$wt/$f"; printf '\n```\n'; done
  fi
  rm -f "$tmp"
}
_graph_report() { [[ -f "$ROOT/graphify-out/GRAPH_REPORT.md" ]] && { _sec "graphify-out/GRAPH_REPORT.md (head)"; head -n 200 "$ROOT/graphify-out/GRAPH_REPORT.md"; }; }
_layer_task_files() { local l="$1" f; for f in "$TASKS_DIR"/TASK-"$(printf '%03d' "$l")"-*.md; do [[ -f "$f" ]] && _file "$f" ".agents/tasks/$(basename "$f")"; done; }

compile_prompt() {
  local role="$1" id="$2" out="$3"; shift 3; local extras=() s
  while [[ $# -gt 0 ]]; do case "$1" in --extra) extras+=("$2"); shift 2 ;; *) die "compile_prompt: unknown arg $1" ;; esac; done
  mkdir -p "$(dirname "$out")"
  {
    _file "$ROOT/AGENTS.md" "AGENTS.md"
    for s in $(_role_skills "$role"); do _skill "$s"; done
    case "$role" in
      coder|reviewer) _contracts_for_task "$id" ;;
      phase_a|phase_b|surgery) _file "$SPEC_FILE" ".agents/architecture/SYSTEM_SPEC.md" ;;
    esac
    _sec "ROLE INSTRUCTIONS ($role)"; _template "$role" "$id"
    case "$role" in
      tier1) if [[ -f "$STATE_FILE" ]]; then _file "$STATE_FILE" ".agents/STATE.md"; else _file "$IDEA_FILE" "IDEA.md"; fi; _graph_report ;;
      phase_a) _file "$IDEA_FILE" "IDEA.md"; _graph_report; _sec "LAYER $id (from ledger)"; layer_get "$id" '' ;;
      phase_b) _sec "LAYER $id TASKS (ledger view)"; jq -r --argjson l "$id" '.tasks[] | select(.layer==$l) | "- \(.id) [\(.status)] \(.title) — owned: \(.owned_files|join(", "))"' "$LEDGER" ;;
      surgery) : ;;   # the trigger context arrives via --extra (task file, .fail.md, tripwire report)
      coder|reviewer) _file "$(task_file "$id")" ".agents/tasks/$id.md" ;;
      closeout|narrative) _file "$DOCS_DIR/reports/LAYER-$id.md" "docs/reports/LAYER-$id.md"; _file "$REVIEW_DIR/LAYER-$id-signoff.md" ".agents/reviews/LAYER-$id-signoff.md" ;;
    esac
    for s in "${extras[@]}"; do _file "$s" "ATTEMPT CONTEXT: $(basename "$s")"; done
    [[ "$role" == coder ]] && _pack_allowlist "$id"
    _sec "END OF PROMPT"
  } > "$out"
  local bytes tokens; bytes="$(wc -c < "$out" | tr -d ' ')"; tokens=$(( bytes / 4 ))
  log "prompt $role/$id: ${bytes}B (~${tokens} tokens) -> $out"
  if [[ "$role" == coder || "$role" == reviewer ]] && [[ $tokens -gt $PROMPT_TOKEN_LIMIT ]]; then
    log "prompt for $id exceeds ${PROMPT_TOKEN_LIMIT} tokens; allowlist too large"; return 2
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -ge 3 ]] || { echo "usage: $0 <role> <id> <outfile> [--extra FILE]..." >&2; exit 64; }
  compile_prompt "$@"
fi
