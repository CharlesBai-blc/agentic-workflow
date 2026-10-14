#!/usr/bin/env bash
# scripts/lib/passes.sh — standalone CLI pass launchers. Every model call in the fleet goes through
# codex_exec or claude_pass: hard timeout, subscription-only env, event stream to .agents/logs/,
# schema-validated output file, quota signals trapped. Nothing here returns model output to a caller
# except the validated JSON file path.
[[ -n "${__FLEET_PASSES_LOADED:-}" ]] && return 0
__FLEET_PASSES_LOADED=1
# shellcheck source=quota.sh
source "$(dirname "${BASH_SOURCE[0]}")/quota.sh"
# shellcheck source=dryrun.sh
source "$(dirname "${BASH_SOURCE[0]}")/dryrun.sh"

# codex_exec <kind> <id> <cwd> <promptfile> <logfile> <timeout_s> [--schema S --out O --effort low|medium|high --readonly]
# kinds: tier1 coder reviewer closeout narrative.  rc: 0 ok, 1 fail/invalid, 124 timeout
codex_exec() {
  local kind="$1" id="$2" cwd="$3" prompt="$4" logf="$5" tmo="$6"; shift 6
  local schema="" out="" effort="medium" sandbox="--dangerously-bypass-approvals-and-sandbox" rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --schema) schema="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; --effort) effort="$2"; shift 2 ;;
      --readonly) sandbox="--sandbox read-only"; shift ;; *) die "codex_exec: unknown arg $1" ;;
    esac
  done
  subscription_only
  [[ -n "$out" ]] && rm -f "$out"
  if [[ "$FLEET_DRY_RUN" == 1 ]]; then dryrun_codex "$kind" "$id" "$cwd" "$out"; return $?; fi
  local model="$TIER3_MODEL"; [[ "$kind" == tier1 ]] && model="$TIER1_MODEL"
  # shellcheck disable=SC2206
  local args=(exec -C "$cwd" --model "$model" -c "model_reasoning_effort=\"$effort\"" --json --color never --skip-git-repo-check $sandbox)
  [[ -n "$schema" ]] && args+=(--output-schema "$schema")
  [[ -n "$out" ]] && args+=(--output-last-message "$out")
  args+=(-)
  { echo "=== codex $kind $id $(now) model=$model effort=$effort cwd=$cwd"; echo "prompt bytes: $(wc -c < "$prompt")"; } >> "$logf"
  run_with_timeout "$tmo" "$logf" -- codex "${args[@]}" < "$prompt" || rc=$?
  quota_refresh codex
  if [[ $rc -eq 124 ]]; then log "codex $kind $id TIMEOUT after ${tmo}s"; return 124; fi
  if [[ -n "$schema" && -n "$out" ]]; then
    [[ -s "$out" ]] || { log "codex $kind $id: no output file written (rc=$rc)"; return 1; }
    json_validate "$schema" "$out" || { log "codex $kind $id: output failed schema $(basename "$schema")"; return 1; }
    return 0
  fi
  return $rc
}

# claude_pass <phase> <layer> <promptfile> <logfile> <timeout_s> <max_turns> [--schema S --out O --mcp]
# phases: phase_a phase_b surgery.  rc: 0 ok, 1 fail/invalid, 3 rate-limit rejected (pause), 124 timeout
claude_pass() {
  local phase="$1" layer="$2" prompt="$3" logf="$4" tmo="$5" turns="$6"; shift 6
  local schema="" out="" mcp=0 rc=0 q=0 so
  while [[ $# -gt 0 ]]; do
    case "$1" in --schema) schema="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; --mcp) mcp=1; shift ;; *) die "claude_pass: unknown arg $1" ;; esac
  done
  subscription_only
  [[ -n "$out" ]] && rm -f "$out"
  if [[ "$FLEET_DRY_RUN" == 1 ]]; then dryrun_claude "$phase" "$layer" "$out"; return $?; fi
  local args=(-p --dangerously-skip-permissions --model "$TIER2_MODEL" --max-turns "$turns"
              --output-format stream-json --verbose --disallowedTools "Task,Agent" --strict-mcp-config)
  [[ $mcp -eq 1 ]] && args+=(--mcp-config "$ROOT/.claude/surgery-mcp.json")
  [[ -n "$schema" ]] && args+=(--json-schema "$(jq -c . "$schema")")
  export CLAUDE_CODE_EFFORT_LEVEL=high
  { echo "=== claude $phase layer=$layer $(now) model=$TIER2_MODEL turns=$turns mcp=$mcp"; echo "prompt bytes: $(wc -c < "$prompt")"; } >> "$logf"
  (cd "$ROOT" && run_with_timeout "$tmo" "$logf" -- claude "${args[@]}" < "$prompt") || rc=$?
  quota_claude_scan "$logf" || q=$?
  if [[ $rc -eq 124 ]]; then log "claude $phase layer $layer TIMEOUT after ${tmo}s"; return 124; fi
  if [[ -n "$schema" && -n "$out" ]]; then
    so="$(grep -E '^\{' "$logf" | jq -c 'select(.type=="result") | .structured_output // empty' 2>/dev/null | tail -n 1)"
    if [[ -n "$so" ]]; then printf '%s\n' "$so" > "$out"
    elif [[ ! -s "$out" ]]; then log "claude $phase: no structured_output and no verdict file at $out"; return 1; fi
    json_validate "$schema" "$out" || { log "claude $phase: verdict failed schema $(basename "$schema")"; return 1; }
  fi
  [[ $q -eq 2 ]] && return 3
  return $rc
}

# pass_result_subtype <stream-json log> -> result subtype (success, error_max_turns, ...) for diagnostics
pass_result_subtype() { grep -E '^\{' "$1" 2>/dev/null | jq -r 'select(.type=="result") | .subtype // "unknown"' 2>/dev/null | tail -n 1; }
