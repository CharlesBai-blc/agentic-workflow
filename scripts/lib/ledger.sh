#!/usr/bin/env bash
# scripts/lib/ledger.sh — the single source of truth for task and layer state.
# set_status is the ONLY function allowed to change a task's status; it writes
# .agents/ledger.json and the task file's frontmatter in one step so Dataview
# and the loop never drift. Every write is atomic and schema-validated.
[[ -n "${__FLEET_LEDGER_LOADED:-}" ]] && return 0
__FLEET_LEDGER_LOADED=1
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LEDGER_SCHEMA="$SCHEMA_DIR/ledger.json"
TASK_STATUSES="PENDING RUNNING GATE_FAILED IN_REVIEW MERGED CONTRACT_DEFECT STRIKE_3_FAILED QUARANTINED IN_SURGERY"

ledger_validate() { check-jsonschema --schemafile "$LEDGER_SCHEMA" "${1:-$LEDGER}" >>"$LOG_DIR/jsonschema.log" 2>&1; }

# ledger_write '<jq filter>' [jq args...] — atomic, validated. $now is always bound.
ledger_write() {
  local filter="$1"; shift
  local tmp; tmp="$(mktemp "$TMP_DIR/ledger.XXXXXX")"
  if ! jq --arg now "$(now)" "$@" "($filter) | .updated_at = \$now" "$LEDGER" > "$tmp"; then
    rm -f "$tmp"; die "ledger jq failed: $filter"
  fi
  if ! ledger_validate "$tmp"; then
    cp "$tmp" "$TMP_DIR/ledger.invalid.json"; rm -f "$tmp"
    die "ledger would be invalid after: $filter (see .agents/tmp/ledger.invalid.json, .agents/logs/jsonschema.log)"
  fi
  mv -f "$tmp" "$LEDGER"
}
ledger_get() { jq -r "$@" "$LEDGER"; }
task_get() { jq -r --arg t "$1" ".tasks[\$t]$2" "$LEDGER"; }      # task_get TASK '.status'
task_status() { task_get "$1" '.status // "PENDING"'; }
task_exists() { [[ "$(jq -r --arg t "$1" '.tasks | has($t)' "$LEDGER")" == true ]]; }
task_set() { local t="$1" f="$2"; shift 2; ledger_write ".tasks[\$t] |= ($f)" --arg t "$t" "$@"; }
task_incr() { task_set "$1" ".$2 = ((.$2 // 0) + 1)"; }
run_state_set() { ledger_write '.run_state=$s | .halt_reason=(if $r=="" then null else $r end)' --arg s "$1" --arg r "${2:-}"; }
ledger_incident() {  # ledger_incident <kind> <layer> <detail> [task]
  ledger_write '.incidents += [{at:$now, kind:$k, layer:($l|tonumber), task:(if $t=="" then null else $t end), detail:($d|.[0:600])}]' \
    --arg k "$1" --arg l "$2" --arg d "$3" --arg t "${4:-}"
}

# ---- set_status: the only status writer ------------------------------------
set_status() {  # set_status TASK STATUS BY [note]
  local t="$1" st="$2" by="$3" note="${4:-}" prev
  [[ " $TASK_STATUSES " == *" $st "* ]] || die "set_status: unknown status '$st'"
  task_exists "$t" || die "set_status: unknown task $t"
  prev="$(task_status "$t")"
  ledger_write '.tasks[$t].status = $st
    | .tasks[$t].history += [{at:$now, from:$prev, to:$st, by:$by, note:($note|.[0:400])}]
    | (if $st == "RUNNING" and .tasks[$t].started_at == null then .tasks[$t].started_at = $now else . end)
    | (if ($st == "MERGED" or $st == "STRIKE_3_FAILED" or $st == "QUARANTINED") then .tasks[$t].finished_at = $now else . end)' \
    --arg t "$t" --arg st "$st" --arg prev "$prev" --arg by "$by" --arg note "$note"
  local tf; tf="$(task_file "$t")"
  task_fm_sync "$t"
  log "status $t: $prev -> $st [$by]${note:+ — $note}"
  declare -F checkpoint_write >/dev/null && checkpoint_write "status $t -> $st"
  return 0
}

# ---- layers ----------------------------------------------------------------
layer_get() { jq -r --argjson l "$1" ".layers[] | select(.layer==\$l)$2" "$LEDGER"; }
layer_set() { local l="$1" f="$2"; shift 2; ledger_write "(.layers[] | select(.layer==\$l)) |= ($f)" --argjson l "$l" "$@"; }
layer_set_status() { layer_set "$1" '.status=$s' --arg s "$2"; log "layer $1 -> $2"; }
layer_status() { layer_get "$1" '.status'; }
layer_exists() { [[ -n "$(layer_get "$1" '.layer' 2>/dev/null)" ]]; }
layer_count() { jq '.layers | length' "$LEDGER"; }
layer_tasks() { jq -r --argjson l "$1" '.tasks[] | select(.layer==$l) | .id' "$LEDGER"; }
layer_wave_count() { layer_get "$1" '.waves | length'; }
wave_tasks() { jq -r --argjson l "$1" --argjson w "$2" '.layers[] | select(.layer==$l) | .waves[$w][]?' "$LEDGER"; }
tasks_with_status() { jq -r --argjson l "$1" --arg s "$2" '.tasks[] | select(.layer==$l and .status==$s) | .id' "$LEDGER"; }
layer_open_tasks() { jq -r --argjson l "$1" '.tasks[] | select(.layer==$l and .status!="MERGED") | .id' "$LEDGER"; }
layer_blocked_tasks() { jq -r --argjson l "$1" '.tasks[] | select(.layer==$l and (.status=="CONTRACT_DEFECT" or .status=="STRIKE_3_FAILED" or .status=="QUARANTINED" or .status=="IN_SURGERY")) | .id' "$LEDGER"; }

# ledger_init <project> <layers.yaml written by Tier 1>
ledger_init() {
  local layers; layers="$(yq -o=json '.layers' "$2")" || die "cannot read $2"
  ledger_write '.project=$p | .run_state="RUNNING" | .halt_reason=null
    | .created_at=(if .created_at=="1970-01-01T00:00:00Z" then $now else .created_at end)
    | .layers = ($layers | map({layer:(.layer|tonumber), title:(.title // ("Layer "+(.layer|tostring))), status:"PLANNED",
        base_tag:null, base_sha:null, frozen_at:null, signed_off_at:null, surgery_failures:0, rework_rounds:0,
        waves:[], signoff_file:null, diagram_file:null, report_file:null}) | sort_by(.layer))' \
    --arg p "$1" --argjson layers "$layers"
  log "ledger initialized: $(layer_count) layers"
}

# ---- importing task files written by Tier 2 --------------------------------
ledger_import_task() {  # ledger_import_task TASK [by]
  local t="$1" tf fm; tf="$(task_file "$t")"; [[ -f "$tf" ]] || die "no task file for $t"
  fm="$(yq --front-matter=extract -o=json '.' "$tf")" || die "bad frontmatter in $tf"
  ledger_write '.tasks[$t] = {
      id:$t, layer:($fm.layer|tonumber), wave:(($fm.wave // 0)|tonumber), title:(($fm.title // $t)|tostring),
      status:"PENDING", risk:(if $fm.risk=="high" then "high" else "low" end), kind:($fm.kind // "feature"), file:$file,
      owned_files:($fm.owned_files // []), readonly_files:($fm.readonly_files // []),
      approved_deps:($fm.approved_deps // []), acceptance_tests:($fm.acceptance_tests // []),
      depends_on:($fm.depends_on // []), branch:("agent/"+$t), worktree:null, strikes:0, gate_failures:0,
      reviews:[], receipt:null, receipt_status:null, defect_location:null, root_cause:null,
      commit_sha:null, merge_sha:null, pr_url:null, pr_number:null, fail_file:null, surgery_count:0,
      created_at:$now, started_at:null, finished_at:null,
      history:[{at:$now, from:null, to:"PENDING", by:$by, note:"imported from task file"}]}' \
    --arg t "$t" --argjson fm "$fm" --arg file ".agents/tasks/$t.md" --arg by "${2:-orchestrate}"
  yq --front-matter=process -i '.status = "PENDING" | .type = "task"' "$tf"
}
ledger_rebuild_waves() {
  ledger_write '(.layers[] | select(.layer==$l)).waves = ([.tasks[] | select(.layer==$l)] | group_by(.wave) | map(sort_by(.id) | map(.id)))' --argjson l "$1"
}
wave_check_disjoint() {  # fails if two tasks in one wave share an OWNED_FILES entry
  local dup
  dup="$(jq -r --argjson l "$1" '[.tasks[] | select(.layer==$l and .status!="MERGED")] | group_by(.wave)[]
      | [.[] | {w:.wave, id:.id, f:.owned_files[]}] | group_by(.f) | map(select(length>1))[]
      | "wave \(.[0].w): \(.[0].f) owned by \(map(.id)|join(", "))"' "$LEDGER")"
  [[ -z "$dup" ]] && return 0
  log "OWNED_FILES OVERLAP: $dup"; return 1
}
ledger_import_layer_tasks() {  # ledger_import_layer_tasks <layer> [by] -> imports new task files, rebuilds waves
  local l="$1" by="${2:-tier2-phaseA}" f t n=0
  for f in "$TASKS_DIR"/TASK-"$(printf '%03d' "$l")"-*.md; do
    [[ -f "$f" && "$f" != *.fail.md ]] || continue
    t="$(basename "$f" .md)"
    task_exists "$t" || { ledger_import_task "$t" "$by"; n=$((n+1)); }
  done
  ledger_rebuild_waves "$l"
  log "layer $l: imported $n new task(s), $(layer_wave_count "$l") wave(s)"
  wave_check_disjoint "$l"
}

# ---- receipts & reviews into the ledger ------------------------------------
ledger_record_receipt() {  # ledger_record_receipt TASK <receipt.json>
  local r="$2"
  task_set "$1" '.receipt=$p | .receipt_status=$r.status | .defect_location=$r.defect_location | .root_cause=$r.root_cause' \
    --arg p ".agents/receipts/$1.json" --argjson r "$(jq -c '{status, defect_location, root_cause}' "$r")"
}
ledger_record_review() {  # ledger_record_review TASK <review.json> <effort>
  task_set "$1" '.reviews += [{at:$now, verdict:$v, file:$f, effort:$e}]' \
    --arg v "$(jq -r .verdict "$2")" --arg f ".agents/reviews/$1.json" --arg e "$3"
}
task_reject_count() { task_get "$1" '.reviews | map(select(.verdict=="REJECT")) | length'; }

# task_fm_sync TASK — mirror ledger fields into the task file frontmatter (Dataview view)
task_fm_sync() {
  local t="$1" tf; tf="$(task_file "$t")"; [[ -f "$tf" ]] || return 0
  local st wave risk strikes pr
  IFS='|' read -r st wave risk strikes pr < <(jq -r --arg t "$t" '.tasks[$t] | [.status, (.wave|tostring), .risk, (.strikes|tostring), (.pr_url // "")] | join("|")' "$LEDGER")
  yq --front-matter=process -i ".status = \"$st\" | .wave = $wave | .risk = \"$risk\" | .strikes = $strikes | .pr_url = \"$pr\" | .updated = \"$(now)\"" "$tf"
}
