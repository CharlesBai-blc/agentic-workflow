#!/usr/bin/env bash
# orchestrate.sh — the bash-driven fleet loop (Section 2).  Usage: ./orchestrate.sh [--max-layers N]
# Per layer: tag base -> Tier 2 Phase A (freeze + slice) -> Tier 3 waves (code, gate, review, merge)
#            -> Tier 2 Phase B (sign-off, rework loop) -> Tier 3 closeout (diagram + report + narrative).
# Tier 2 Surgery runs only on escalation. Every model call is a standalone pass (scripts/lib/passes.sh).
# Resume is automatic from .agents/ledger.json; STATE.md carries the human resume prompt.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FLEET_ROOT="${FLEET_ROOT:-$HERE}"
for lib in common ledger worktree tripwire gate quota dryrun passes pr compile-prompt checkpoint progress-report; do
  # shellcheck disable=SC1090
  source "$HERE/scripts/lib/$lib.sh"
done
MAX_LAYERS=999
while [[ $# -gt 0 ]]; do case "$1" in --max-layers) MAX_LAYERS="$2"; shift 2 ;; *) die "unknown argument: $1" ;; esac; done

cur_layer() { jq '.current_layer' "$LEDGER"; }
max_turns() { idea_get ".max_turns.$1" 50; }

# ---- run hygiene (Section 4) -------------------------------------------------------------------
acquire_lock() {
  local pid
  if mkdir "$RUN_LOCK" 2>/dev/null; then echo $$ > "$RUN_LOCK/pid"; return 0; fi
  pid="$(cat "$RUN_LOCK/pid" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && die "another orchestrate.sh is running (pid $pid)"
  log "reclaiming stale run.lock (pid ${pid:-?})"; rm -rf "$RUN_LOCK"; mkdir "$RUN_LOCK" && echo $$ > "$RUN_LOCK/pid"
}
release_lock() { [[ "$(cat "$RUN_LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$RUN_LOCK"; }
trap release_lock EXIT
bundle_snapshot() {
  mkdir -p "$BUNDLE_ROOT"
  git -C "$ROOT" bundle create "$BUNDLE_ROOT/$(date -u +%Y%m%dT%H%M%SZ).bundle" --all >>"$LOG_DIR/bundle.log" 2>&1 || warn "git bundle failed"
}
halt() {  # halt <reason> — STATE.md + human report + ntfy, then exit 2
  run_state_set HALTED "$1"; ledger_incident HALT "$(cur_layer)" "$1"
  checkpoint_write "halt: $1"; incident_report HALT "$1" >/dev/null
  ntfy_send "HALTED" "$1" urgent; log "HALT: $1"; exit 2
}
quota_or_pause() {  # quota_or_pause <codex|claude> — sleep until reset or halt when too far away
  local cli="$1" why
  while ! quota_gate "$cli" > "$TMP_DIR/quota.reason"; do
    why="$(cat "$TMP_DIR/quota.reason")"
    run_state_set PAUSED_QUOTA "$why"; ledger_incident QUOTA_PAUSE "$(cur_layer)" "$why; reset $QUOTA_RESETS_AT"
    checkpoint_write "quota pause: $why"; incident_report QUOTA_PAUSE "$why. Resuming at $QUOTA_RESETS_AT." >/dev/null
    ntfy_send "Quota pause ($cli)" "$why. Resuming at $QUOTA_RESETS_AT" high
    quota_sleep_until "$QUOTA_RESETS_AT" || halt "$why; reset $QUOTA_RESETS_AT is beyond MAX_SLEEP_HOURS"
    quota_clear "$cli"; run_state_set RUNNING; ledger_incident QUOTA_RESUME "$(cur_layer)" "$cli resumed"
  done
}
graphify_update() {  # only ever on main (Section 3 rebuild policy)
  [[ "$FLEET_DRY_RUN" == 1 ]] && return 0
  have graphify || { warn "graphify not installed; graph not rebuilt"; return 0; }
  (cd "$ROOT" && graphify update .) >>"$LOG_DIR/graphify.log" 2>&1 || warn "graphify update failed"
}
commit_main() {  # commit_main <message> — commit everything in the root repo and push main
  git -C "$ROOT" add -A >>"$LOG_DIR/git.log" 2>&1
  git -C "$ROOT" diff --cached --quiet && { log "nothing to commit: $1"; return 0; }
  git -C "$ROOT" commit -q -m "$1" >>"$LOG_DIR/git.log" 2>&1 || die "commit on $(base_branch) failed: $1"
  pr_push_main || die "push of $(base_branch) failed"
}
run_claude() {  # run_claude <phase> <id> [--schema S --out O --mcp] [--extra F]... ; two tries, quota-aware
  local phase="$1" id="$2"; shift 2; local -a extras=() opts=(); local try rc
  while [[ $# -gt 0 ]]; do case "$1" in --extra) extras+=(--extra "$2"); shift 2 ;; --mcp) opts+=(--mcp); shift ;; *) opts+=("$1" "$2"); shift 2 ;; esac; done
  for try in 1 2; do
    quota_or_pause claude
    compile_prompt "$phase" "$id" "$PROMPT_DIR/$phase-$id.md" ${extras[@]+"${extras[@]}"} || return 1
    claude_pass "$phase" "$id" "$PROMPT_DIR/$phase-$id.md" "$LOG_DIR/$phase-$id.log" "$(tier_timeout "$phase")" "$(max_turns "$phase")" ${opts[@]+"${opts[@]}"}; rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $rc -eq 124 ]] && ledger_incident TIMEOUT "$(cur_layer)" "$phase $id timed out (try $try)"
    log "$phase $id failed (rc=$rc, try $try)"
  done
  return 1
}

# ---- Tier 1 ---------------------------------------------------------------------------------------
tier1() {
  if [[ -f "$SPEC_FILE" && -f "$LAYERS_FILE" && "$(layer_count)" -gt 0 ]]; then log "resume: spec and layer plan present, skipping Tier 1"; return 0; fi
  quota_or_pause codex
  compile_prompt tier1 0 "$PROMPT_DIR/tier1.md"
  codex_exec tier1 0 "$ROOT" "$PROMPT_DIR/tier1.md" "$LOG_DIR/tier1.log" "$(tier_timeout tier1)" --effort high || halt "Tier 1 pass failed (see .agents/logs/tier1.log)"
  [[ -f "$SPEC_FILE" && -f "$LAYERS_FILE" ]] || halt "Tier 1 did not write SYSTEM_SPEC.md and .agents/layers.yaml"
  ledger_init "$(idea_get '.project' "$REPO_NAME")" "$LAYERS_FILE"
  commit_main "Tier 1: system spec, layer plan and target architecture"; graphify_update
}

# ---- Tier 2 Phase A: freeze + slice ---------------------------------------------------------------
tag_layer_base() {
  local l="$1" tag; tag="$(layer_tag "$l")"
  git -C "$ROOT" tag -f "$tag" "$(base_branch)" >>"$LOG_DIR/git.log" 2>&1; pr_push_tag "$tag"
  layer_set "$l" '.base_tag=$t | .base_sha=$s' --arg t "$tag" --arg s "$(main_sha)"; log "tagged $tag at $(main_sha | cut -c1-7)"
}
phase_a() {
  local l="$1"
  run_claude phase_a "$l" || halt "Phase A failed for layer $l"
  [[ -s "$AGENTS_DIR/frozen.list" ]] || halt "Phase A wrote no .agents/frozen.list for layer $l"
  # shellcheck disable=SC2046
  frozen_record $(sort -u "$AGENTS_DIR/frozen.list")
  layer_set "$l" '.frozen_at=$now'; layer_set_status "$l" FROZEN
  commit_main "Layer $l: freeze contracts and acceptance tests"; graphify_update
  ledger_import_layer_tasks "$l" tier2-phaseA || halt "layer $l: overlapping OWNED_FILES inside a wave"
  [[ -n "$(layer_tasks "$l")" ]] || halt "Phase A produced no task files for layer $l"
  commit_main "Layer $l: task slices"; layer_set_status "$l" SLICED
  ntfy_send "Layer $l sliced" "$(layer_tasks "$l" | wc -l | tr -d ' ') tasks in $(layer_wave_count "$l") waves"
}

# ---- Tier 3: dispatch, verify, ship ---------------------------------------------------------------
bump_strike() {  # bump_strike TASK <why> — bash gate failures and timeouts share the coder's 3-strike budget
  local t="$1" why="$2" n
  task_set "$t" '.strikes=([(.strikes // 0)+1, 3]|min) | .gate_failures=(.gate_failures+1)'; n="$(task_get "$t" '.strikes')"
  ledger_incident GATE_FAILED "$(task_layer "$t")" "$t strike $n: $why" "$t"
  if [[ "$n" -ge 3 ]]; then write_fail_md "$t" "$why"; set_status "$t" STRIKE_3_FAILED gate "$why"; ledger_incident STRIKE_3 "$(task_layer "$t")" "$t: $why" "$t"
  else set_status "$t" GATE_FAILED gate "$why"; fi
}
write_fail_md() {  # write_fail_md TASK [why] -> .agents/tasks/TASK.fail.md (Obsidian frontmatter)
  local t="$1" f="$TASKS_DIR/$1.fail.md" r="$RECEIPT_DIR/$1.json"
  { printf -- '---\nid: %s\ntype: failure\ntask: "[[%s]]"\nstatus: STRIKE_3_FAILED\nlayer: %s\nat: %s\ntags: [failure, strike-3]\n---\n\n# %s failed after 3 strikes\n\n**Reason:** %s\n\n## Receipt\n\n```json\n' \
      "$t" "$t" "$(task_layer "$t")" "$(now)" "$t" "${2:-see receipt}"
    [[ -f "$r" ]] && jq '{status, attempt, test_summary, root_cause, triage_hypothesis}' "$r"
    printf '```\n\n## Log tail\n\n```text\n'; log_tail "$LOG_DIR/$t.log" 40; printf '```\n'; } > "$f"
  task_set "$t" '.fail_file=$f' --arg f ".agents/tasks/$t.fail.md"
}
prepare_task() {  # worktree, compiled prompt with attempt context, tripwire snapshot, RUNNING
  local t="$1" f; local -a extras=()
  if [[ -f "$(wt_dir "$t")/.QUARANTINED" ]]; then wt_create "$t"; else wt_ensure "$t"; fi
  f="$TMP_DIR/gate-$t.reason"; [[ -s "$f" ]] && extras+=(--extra "$f")
  if [[ "$(task_reject_count "$t")" -gt 0 && -f "$REVIEW_DIR/$t.json" ]]; then pr_review_comment_body "$t" "$REVIEW_DIR/$t.json" > "$TMP_DIR/review-$t.md"; extras+=(--extra "$TMP_DIR/review-$t.md"); fi
  [[ -f "$REVIEW_DIR/$t-surgery.md" ]] && extras+=(--extra "$REVIEW_DIR/$t-surgery.md")
  compile_prompt coder "$t" "$PROMPT_DIR/coder-$t.md" ${extras[@]+"${extras[@]}"} || return 1
  tripwire_snapshot "$t"; set_status "$t" RUNNING orchestrate "attempt $(( $(task_get "$t" '.strikes') + 1 ))"
}
run_batch() {  # run_batch TASK... — parallel coder passes, then sequential verify, then sequential ship
  local t; local -a launched=() pids=()
  export TRIPWIRE_SIBLING_EXCLUDE="$*"
  for t in "$@"; do
    if prepare_task "$t"; then launched+=("$t"); else set_status "$t" IN_SURGERY orchestrate "compiled prompt exceeds the token budget"; fi
  done
  for t in ${launched[@]+"${launched[@]}"}; do
    ( QUOTA_NO_LEDGER=1 codex_exec coder "$t" "$(wt_dir "$t")" "$PROMPT_DIR/coder-$t.md" "$LOG_DIR/$t.log" "$(tier_timeout coder)" \
        --schema "$SCHEMA_DIR/receipt.json" --out "$RECEIPT_DIR/$t.json" --effort "$(idea_get '.effort.coder' medium)"; echo $? > "$TMP_DIR/rc-$t" ) &
    pids+=($!)
  done
  wait ${pids[@]+"${pids[@]}"}; quota_refresh codex
  local -a verified=()
  for t in ${launched[@]+"${launched[@]}"}; do verify_task "$t" "$(cat "$TMP_DIR/rc-$t" 2>/dev/null || echo 1)" && verified+=("$t"); done
  unset TRIPWIRE_SIBLING_EXCLUDE
  for t in ${verified[@]+"${verified[@]}"}; do ship_task "$t"; done
}
verify_task() {  # verify_task TASK <rc> — tripwires, receipt, gate, commit (no main changes here)
  local t="$1" rc="$2" r="$RECEIPT_DIR/$1.json" tw st
  if [[ "$rc" -eq 124 ]]; then ledger_incident TIMEOUT "$(task_layer "$t")" "$t coder timed out" "$t"; bump_strike "$t" "coder pass timed out"; return 1; fi
  tw="$(tripwire_check "$t" | tail -n 1)"
  [[ "$tw" == "TRIPWIRE: PASS" ]] || { tripwire_quarantine "$t" "${tw#TRIPWIRE: }"; return 1; }
  [[ "$rc" -eq 0 ]] || { bump_strike "$t" "no schema-valid receipt (rc=$rc)"; return 1; }
  ledger_record_receipt "$t" "$r"; st="$(jq -r .status "$r")"
  task_set "$t" '.strikes=([(.strikes // 0)+$a, 3]|min)' --argjson a "$(( $(jq .attempt "$r") - 1 ))"
  case "$st" in
    CONTRACT_DEFECT) set_status "$t" CONTRACT_DEFECT orchestrate "$(jq -r .defect_location "$r")"
      ledger_incident CONTRACT_DEFECT "$(task_layer "$t")" "$t: $(jq -r '.defect_location + " — " + .root_cause' "$r")" "$t"; return 1 ;;
    ESCALATE_STRIKE_3) write_fail_md "$t" "$(jq -r .root_cause "$r")"; set_status "$t" STRIKE_3_FAILED orchestrate "$(jq -r .root_cause "$r")"
      ledger_incident STRIKE_3 "$(task_layer "$t")" "$t: $(jq -r .root_cause "$r")" "$t"; return 1 ;;
  esac
  gate_run "$t" || { bump_strike "$t" "gate: $(head -n 1 "$TMP_DIR/gate-$t.reason")"; return 1; }
  task_set "$t" '.commit_sha=$s' --arg s "$(wt_commit "$t" "$t: $(task_get "$t" '.title')")"
}
ship_task() {  # push branch, open PR (once), review, merge
  local t="$1"
  pr_push_branch "$t" || { bump_strike "$t" "branch push failed"; return 1; }
  if [[ -z "$(task_get "$t" '.pr_number // empty')" ]]; then
    pr_body_for_task "$t" "$RECEIPT_DIR/$t.json" "$TMP_DIR/pr-body-$t.md"
    pr_create "$t" "$t: $(task_get "$t" '.title')" "$TMP_DIR/pr-body-$t.md" >/dev/null
  fi
  set_status "$t" IN_REVIEW orchestrate "PR #$(task_get "$t" '.pr_number')"
  review_task "$t"
}
review_task() {
  local t="$1" effort=medium out="$REVIEW_DIR/$1.json" try rc=1
  [[ "$(task_risk "$t")" == high ]] && effort=high
  for try in 1 2; do
    quota_or_pause codex; compile_prompt reviewer "$t" "$PROMPT_DIR/reviewer-$t.md" || break
    codex_exec reviewer "$t" "$(wt_dir "$t")" "$PROMPT_DIR/reviewer-$t.md" "$LOG_DIR/$t-review.log" "$(tier_timeout reviewer)" \
      --readonly --effort "$effort" --schema "$SCHEMA_DIR/review.json" --out "$out" && { rc=0; break; }
  done
  [[ $rc -eq 0 ]] || { bump_strike "$t" "reviewer produced no valid verdict"; return 1; }
  ledger_record_review "$t" "$out" "$effort"; pr_comment "$t" "$(pr_review_comment_body "$t" "$out")"
  if [[ "$(jq -r .verdict "$out")" == APPROVE ]]; then merge_task "$t"; return $?; fi
  ledger_incident REVIEW_REJECT "$(task_layer "$t")" "$t: $(jq -r '[.reasons[].reason] | join("; ")' "$out" | cut -c1-300)" "$t"
  if [[ "$(task_reject_count "$t")" -ge 2 ]]; then set_status "$t" IN_SURGERY review "rejected twice"
  else set_status "$t" GATE_FAILED review "REJECT: fix with the review reasons, same branch"; fi
  return 1
}
merge_task() {
  local t="$1" sha logf body
  pr_checks_ok "$t" || { bump_strike "$t" "GitHub checks failed"; return 1; }
  if ! pr_mergeable "$t"; then
    if git -C "$(wt_dir "$t")" rebase "$(base_branch)" >>"$LOG_DIR/git.log" 2>&1 && pr_push_branch "$t" && pr_mergeable "$t"; then log "$t rebased onto $(base_branch)"
    else git -C "$(wt_dir "$t")" rebase --abort >/dev/null 2>&1; bump_strike "$t" "PR not mergeable"; return 1; fi
  fi
  sha="$(pr_merge "$t")" || { bump_strike "$t" "merge failed"; return 1; }
  task_set "$t" '.merge_sha=$s' --arg s "$sha"; set_status "$t" MERGED merge "$sha"
  if logf="$(gate_main)"; then graphify_update; wt_remove "$t"; return 0; fi
  git -C "$ROOT" revert -m 1 --no-edit "$sha" >>"$LOG_DIR/git.log" 2>&1 || die "revert of $sha failed; $(base_branch) is red"
  pr_push_main; ledger_incident REVERT "$(task_layer "$t")" "$t: post-merge just check failed; reverted $sha" "$t"
  printf -v body 'Post-merge `just check` failed on %s; merge %s reverted and the task re-dispatched.\n\n```text\n%s\n```' "$(base_branch)" "$sha" "$(log_tail "$logf" 25)"
  pr_comment "$t" "$body"; wt_remove "$t"; task_set "$t" '.pr_url=null | .pr_number=null | .merge_sha=null'
  bump_strike "$t" "post-merge gate failed; merge reverted"; return 1
}

# ---- Surgery (escalation only) ----------------------------------------------------------------------
surgery() {  # surgery <layer> TASK...
  local l="$1"; shift; local t st f; local -a extras
  for t in "$@"; do
    [[ "$(layer_get "$l" '.surgery_failures')" -ge 2 ]] && halt "Surgery breaker: two failed Surgeries in layer $l"
    [[ "$(task_get "$t" '.surgery_count')" -ge 2 ]] && halt "Surgery breaker: $t still failing after two Surgeries"
    st="$(task_status "$t")"; [[ "$st" == IN_SURGERY ]] || set_status "$t" IN_SURGERY orchestrate "escalated from $st"
    ledger_incident SURGERY_START "$l" "$t ($st)" "$t"; ntfy_send "Surgery $t" "layer $l, escalated from $st" high
    export AGENTS_SURGERY_TASK="$t"; echo "$t" > "$AGENTS_DIR/surgery.current"; rm -f "$REVIEW_DIR/$t-surgery.md"
    extras=(--extra "$(task_file "$t")")
    for f in "$TASKS_DIR/$t.fail.md" "$RECEIPT_DIR/$t.json" "$REVIEW_DIR/$t.json" "$TMP_DIR/gate-$t.reason"; do [[ -s "$f" ]] && extras+=(--extra "$f"); done
    if run_claude surgery "$t" --mcp "${extras[@]}" && [[ -f "$REVIEW_DIR/$t-surgery.md" ]]; then
      # shellcheck disable=SC2046
      [[ -s "$AGENTS_DIR/frozen.list" ]] && frozen_record $(sort -u "$AGENTS_DIR/frozen.list")
      ledger_refresh_task "$t"; commit_main "Surgery $t: $(yq --front-matter=extract -r '.action // "patch"' "$REVIEW_DIR/$t-surgery.md")"; graphify_update
      task_set "$t" '.strikes=0 | .surgery_count=(.surgery_count+1)'; set_status "$t" GATE_FAILED tier2-surgery "re-dispatch after Surgery"
      ledger_incident SURGERY_DONE "$l" "$t" "$t"
    else
      layer_set "$l" '.surgery_failures += 1'; ledger_incident SURGERY_FAILED "$l" "$t: Surgery pass failed" "$t"
    fi
    unset AGENTS_SURGERY_TASK; rm -f "$AGENTS_DIR/surgery.current"
  done
}

# ---- waves and layers ---------------------------------------------------------------------------------
run_wave() {  # no new dispatch while any task in the wave needs Surgery (Section 2 pause rule)
  local l="$1" w="$2" t; local -a blocked todo
  while :; do
    mapfile -t blocked < <(for t in $(wave_tasks "$l" "$w"); do case "$(task_status "$t")" in CONTRACT_DEFECT|STRIKE_3_FAILED|QUARANTINED|IN_SURGERY) echo "$t" ;; esac; done)
    if [[ ${#blocked[@]} -gt 0 ]]; then surgery "$l" "${blocked[@]}"; continue; fi
    mapfile -t todo < <(for t in $(wave_tasks "$l" "$w"); do case "$(task_status "$t")" in IN_REVIEW) ship_task "$t" >/dev/null ;; PENDING|GATE_FAILED|RUNNING) echo "$t" ;; esac; done)
    [[ ${#todo[@]} -eq 0 ]] && break
    quota_or_pause codex; run_batch "${todo[@]:0:$(max_parallel)}"
  done
}
coding_loop() {
  local l="$1" w n; layer_set_status "$l" CODING; n="$(layer_wave_count "$l")"
  for ((w = 0; w < n; w++)); do run_wave "$l" "$w"; done
  [[ -z "$(layer_open_tasks "$l")" ]] || halt "layer $l still has unmerged tasks: $(layer_open_tasks "$l" | tr '\n' ' ')"
}
phase_b() {  # returns 0 on SIGNED_OFF, 1 on REWORK (caller loops back into coding)
  local l="$1" out="$REVIEW_DIR/LAYER-$1-verdict.json" pre="$TMP_DIR/layer-$1-preaudit.md"
  layer_set_status "$l" SIGNOFF
  { echo "Deterministic pre-audit on $(base_branch) (summary lines only):"; gate_layer_summary "$l"; } > "$pre"
  run_claude phase_b "$l" --schema "$SCHEMA_DIR/layer-verdict.json" --out "$out" --extra "$pre" || halt "Phase B failed for layer $l"
  layer_set "$l" '.signoff_file=$f' --arg f "$(jq -r .audit_file "$out")"
  if [[ "$(jq -r .verdict "$out")" == SIGNED_OFF ]]; then
    layer_set "$l" '.signed_off_at=$now'; commit_main "Layer $l: signed off"; layer_set_status "$l" SIGNED_OFF
    ntfy_send "Layer $l SIGNED_OFF" "$(jq -r .summary "$out")"; return 0
  fi
  [[ "$(layer_get "$l" '.rework_rounds')" -lt 2 ]] || halt "layer $l: REWORK requested a third time"
  layer_set "$l" '.rework_rounds += 1'; ledger_import_layer_tasks "$l" tier2-phaseB || halt "layer $l: rework tasks overlap"
  commit_main "Layer $l: rework tasks"; layer_set_status "$l" REWORK; return 1
}
closeout() {
  local l="$1"
  quota_or_pause codex; compile_prompt closeout "$l" "$PROMPT_DIR/closeout-$l.md"
  codex_exec closeout "$l" "$ROOT" "$PROMPT_DIR/closeout-$l.md" "$LOG_DIR/closeout-$l.log" "$(tier_timeout closeout)" || warn "closeout diagram pass failed for layer $l"
  [[ -f "$DOCS_DIR/architecture/layer-$l-actual.html" ]] && layer_set "$l" '.diagram_file=$f' --arg f "docs/architecture/layer-$l-actual.html"
  progress_report "$l"
  compile_prompt narrative "$l" "$PROMPT_DIR/narrative-$l.md"
  codex_exec narrative "$l" "$ROOT" "$PROMPT_DIR/narrative-$l.md" "$LOG_DIR/narrative-$l.log" "$(tier_timeout closeout)" --effort low || warn "narrative pass failed for layer $l"
  commit_main "Layer $l: closeout diagram and progress report"; layer_set_status "$l" CLOSED; checkpoint_write "layer $l closed"
}
run_layer() {
  local l="$1"; ledger_write '.current_layer=$l' --argjson l "$l"
  case "$(layer_status "$l")" in CLOSED) return 0 ;; PLANNED) tag_layer_base "$l"; phase_a "$l" ;; FROZEN) phase_a "$l" ;; esac
  while :; do coding_loop "$l"; phase_b "$l" && break; done
  closeout "$l"
}

main() {
  subscription_only; acquire_lock
  [[ -f "$IDEA_FILE" ]] || die "IDEA.md missing in $ROOT"
  bundle_snapshot; run_state_set RUNNING; checkpoint_write "run start"; tier1
  local l start n; start="$(cur_layer)"; n="$(layer_count)"
  for ((l = start; l < n && l < start + MAX_LAYERS; l++)); do run_layer "$l"; done
  if [[ $l -ge $n ]]; then run_state_set COMPLETE; ntfy_send "Fleet complete" "all $n layers closed"; else run_state_set IDLE; fi
  checkpoint_write "run end"; wt_clean_all; log "orchestrate.sh finished (run_state=$(jq -r .run_state "$LEDGER"))"
}
main "$@"
