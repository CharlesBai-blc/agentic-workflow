#!/usr/bin/env bash
# scripts/lib/quota.sh — subscription quota gating (Section 1.8). Primary signals: Codex rollout
# logs (token_count.rate_limits) and Claude stream-json rate_limit_event. ccusage is a secondary proxy.
[[ -n "${__FLEET_QUOTA_LOADED:-}" ]] && return 0
__FLEET_QUOTA_LOADED=1
# shellcheck source=ledger.sh
source "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

QUOTA_RESETS_AT=""          # set by quota_gate when it returns 1
soft_ceiling() { idea_get '.quota.soft_ceiling_pct' 80; }
max_sleep_hours() { idea_get '.quota.max_sleep_hours' 6; }

_q_json() {  # _q_json five weekly resets_at source state
  jq -nc --arg f "$1" --arg w "$2" --arg r "$3" --arg s "$4" --arg st "$5" --arg now "$(now)" \
    '{five_hour_pct:(if $f=="" then null else ($f|tonumber) end), weekly_pct:(if $w=="" then null else ($w|tonumber) end),
      resets_at:(if $r=="" then null else $r end), checked_at:$now, source:$s, state:$st}'
}
_q_store() {  # _q_store <cli> <json>
  printf '%s\n' "$2" > "$QUOTA_DIR/$1.json"
  [[ -f "$LEDGER" ]] && ledger_write '.quota[$c] = $q' --arg c "$1" --argjson q "$2"
}
_q_state_for() {  # _q_state_for five weekly -> OK|WARNING
  local c; c="$(soft_ceiling)"
  { [[ -n "$1" && "${1%.*}" -ge "$c" ]] || [[ -n "$2" && "${2%.*}" -ge "$c" ]]; } && echo WARNING || echo OK
}

# ---- Codex: newest token_count event across the 5 most recent rollout files ------------
quota_codex_read() {
  local dir="${CODEX_HOME:-$HOME/.codex}/sessions" files ev five weekly r5 rw ts reset=""
  files="$(find "$dir" -name 'rollout-*.jsonl' -type f 2>/dev/null | xargs -r ls -t 2>/dev/null | head -n 5)"
  [[ -z "$files" ]] && { _q_json "" "" "" none UNKNOWN; return; }
  # shellcheck disable=SC2086
  ev="$(cat $files 2>/dev/null | grep -E '"token_count"' | jq -c 'select(.payload.type=="token_count" and .payload.rate_limits!=null)
        | {ts:(.timestamp // ""), w:([.payload.rate_limits.primary, .payload.rate_limits.secondary] | map(select(.!=null)))}' 2>/dev/null | sort | tail -n 1)"
  [[ -z "$ev" ]] && { _q_json "" "" "" none UNKNOWN; return; }
  IFS='|' read -r ts five r5 weekly rw < <(printf '%s' "$ev" | jq -r '
    (.w | map(select(.window_minutes==300)) | .[0]) as $f | (.w | map(select(.window_minutes>=10000)) | .[0]) as $wk
    | [.ts, ($f.used_percent // ""), ($f.resets_at // $f.resets_in_seconds // ""), ($wk.used_percent // ""), ($wk.resets_at // $wk.resets_in_seconds // "")] | join("|")')
  local c; c="$(soft_ceiling)"; local pick="$r5"
  [[ -n "$weekly" && "${weekly%.*}" -ge "$c" ]] && pick="$rw"
  if [[ -n "$pick" ]]; then
    if [[ "$pick" -gt 100000000 ]]; then reset="$(iso_of "$pick")"           # absolute epoch seconds
    else reset="$(iso_of $(( $(epoch_of "${ts:-$(now)}" 2>/dev/null || date +%s) + pick )))"; fi  # relative seconds
  fi
  _q_json "$five" "$weekly" "$reset" rollout-log "$(_q_state_for "$five" "$weekly")"
}

# ---- Claude: rate_limit_event trapped from a pass's stream-json log -----------------------
# returns 0 (ok/none), 1 (allowed_warning: finish, then pause), 2 (rejected: stop now)
quota_claude_scan() {  # quota_claude_scan <stream-json log>
  local ev st reset="" util pct="" rc=0
  ev="$(grep -E '^\{' "$1" 2>/dev/null | jq -c 'select(.type=="rate_limit_event") | (.rate_limit_info // .)' 2>/dev/null | tail -n 1)"
  [[ -z "$ev" ]] && return 0
  IFS='|' read -r st reset util < <(printf '%s' "$ev" | jq -r '[(.status // ""), (.resetsAt // .resets_at // ""), (.utilization // "")] | join("|")')
  [[ -n "$reset" && "$reset" =~ ^[0-9]+$ ]] && reset="$(iso_of "$reset")"
  [[ -n "$util" ]] && pct="$(awk -v u="$util" 'BEGIN{printf "%.0f", (u<=1?u*100:u)}')"
  case "$st" in rejected) rc=2; st=REJECTED ;; allowed_warning) rc=1; st=WARNING ;; *) st=OK ;; esac
  _q_store claude "$(_q_json "$pct" "" "$reset" rate_limit_event "$st")"
  [[ $rc -gt 0 ]] && log "claude rate_limit_event: $st resets_at=${reset:-?}"
  return $rc
}

# ---- ccusage secondary proxy ---------------------------------------------------------------
quota_ccusage_pct() {  # quota_ccusage_pct <cli> -> percent or ""
  case "$1" in
    claude) have ccusage && ccusage blocks --json --active -t max 2>/dev/null | jq -r '.blocks[0].tokenLimitStatus.percentUsed // empty' 2>/dev/null ;;
    codex)  : ;;   # @ccusage/codex reports tokens, not limits: no percentage available
  esac
}
quota_ccusage_reset() { have ccusage && ccusage blocks --json --active 2>/dev/null | jq -r '.blocks[0].endTime // empty' 2>/dev/null; }

quota_refresh() {  # quota_refresh codex | quota_refresh claude <log>
  case "$1" in
    codex) _q_store codex "$(quota_codex_read)" ;;
    claude) [[ -n "${2:-}" ]] && quota_claude_scan "$2" ;;
  esac
  return 0
}

# quota_gate <cli> -> 0 proceed; 1 pause (QUOTA_RESETS_AT set, reason on stdout)
quota_gate() {
  local cli="$1" f st pct5 pctw reset c cc; c="$(soft_ceiling)"
  [[ "$cli" == codex ]] && quota_refresh codex
  f="$QUOTA_DIR/$cli.json"; QUOTA_RESETS_AT=""
  if [[ -f "$f" ]]; then
    IFS='|' read -r st pct5 pctw reset < <(jq -r '[(.state // "UNKNOWN"), (.five_hour_pct // ""), (.weekly_pct // ""), (.resets_at // "")] | join("|")' "$f")
    if [[ "$st" == REJECTED ]]; then
      QUOTA_RESETS_AT="${reset:-$(iso_of $(( $(date +%s) + 3600 )))}"; echo "$cli reported a rate-limit rejection"; return 1
    fi
    if [[ "$st" == WARNING ]] || { [[ -n "$pct5" && "${pct5%.*}" -ge "$c" ]] || [[ -n "$pctw" && "${pctw%.*}" -ge "$c" ]]; }; then
      QUOTA_RESETS_AT="${reset:-$(iso_of $(( $(date +%s) + 3600 )))}"
      echo "$cli quota 5h=${pct5:-?}% weekly=${pctw:-?}% (soft ceiling ${c}%)"; return 1
    fi
  fi
  cc="$(quota_ccusage_pct "$cli")"
  if [[ -n "$cc" && "${cc%.*}" -ge "$c" ]]; then
    QUOTA_RESETS_AT="$(quota_ccusage_reset)"; [[ -n "$QUOTA_RESETS_AT" ]] || QUOTA_RESETS_AT="$(iso_of $(( $(date +%s) + 3600 )))"
    _q_store "$cli" "$(_q_json "$cc" "" "$QUOTA_RESETS_AT" ccusage WARNING)"
    echo "$cli ccusage proxy at ${cc}% (soft ceiling ${c}%)"; return 1
  fi
  return 0
}

# quota_sleep_until <iso> -> 0 after sleeping; 1 if the wait exceeds MAX_SLEEP_HOURS (caller halts)
quota_sleep_until() {
  local target wait max; target="$(epoch_of "$1")" || target=$(( $(date +%s) + 3600 ))
  wait=$(( target - $(date +%s) + 60 )); max=$(( $(max_sleep_hours) * 3600 ))
  [[ $wait -le 0 ]] && return 0
  [[ $wait -gt $max ]] && { log "reset at $1 is ${wait}s away (> MAX_SLEEP_HOURS=$(max_sleep_hours)h)"; return 1; }
  log "sleeping ${wait}s until $1"
  [[ "$FLEET_DRY_RUN" == 1 ]] && return 0
  while [[ $wait -gt 0 ]]; do sleep $(( wait > 300 ? 300 : wait )); wait=$(( target - $(date +%s) + 60 )); done
  return 0
}
quota_clear() { _q_store "$1" "$(_q_json "" "" "" none UNKNOWN)"; }   # after a successful resume
