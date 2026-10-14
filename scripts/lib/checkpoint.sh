#!/usr/bin/env bash
# scripts/lib/checkpoint.sh — jq transform ledger.json -> .agents/STATE.md (machine state + resume prompt).
# Called by set_status after every task transition and by orchestrate.sh at pauses/halts.
[[ -n "${__FLEET_CHECKPOINT_LOADED:-}" ]] && return 0
__FLEET_CHECKPOINT_LOADED=1
# shellcheck source=ledger.sh
source "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

checkpoint_write() {  # checkpoint_write [reason]
  local reason="${1:-periodic}" tmp; tmp="$(mktemp "$TMP_DIR/state.XXXXXX")"
  jq -r --arg reason "$reason" --arg now "$(now)" --arg repo "$REPO_NAME" '
    def pad: tostring;
    def link: "[[" + . + "]]";
    def open_statuses: ["RUNNING","GATE_FAILED","IN_REVIEW","CONTRACT_DEFECT","STRIKE_3_FAILED","QUARANTINED","IN_SURGERY","PENDING"];
    (.tasks | to_entries | map(.value)) as $T
    | ($T | map(select(.status!="MERGED")) | sort_by(.layer, .wave, .id)) as $open
    | ($T | map(select(.status=="MERGED")) | length) as $merged
    | ($T | map(select(.status=="CONTRACT_DEFECT" or .status=="STRIKE_3_FAILED" or .status=="QUARANTINED" or .status=="IN_SURGERY"))) as $blocked
    | (.layers[] | select(.layer==$current_layer) // null) as $cur
    | "---",
      "title: STATE", "type: state", "project: \(.project)", "run_state: \(.run_state // "IDLE")",
      "current_layer: \(.current_layer)", "tasks_total: \($T|length)", "tasks_merged: \($merged)", "tasks_blocked: \($blocked|length)",
      "updated: \($now)", "reason: \"\($reason)\"", "halt_reason: \"\(.halt_reason // "")\"", "tags: [state, fleet]", "---", "",
      "# Fleet state — \(.project)", "",
      "> [!info] Machine-written by `scripts/lib/checkpoint.sh` from `.agents/ledger.json`. Do not edit. Dashboard: [[PROGRESS]].", "",
      "| run_state | layer | merged | open | blocked | updated |", "|---|---|---|---|---|---|",
      "| **\(.run_state // "IDLE")** | \(.current_layer) | \($merged) | \($open|length) | \($blocked|length) | \($now) |", "",
      "## Layers", "", "| layer | title | status | base tag | waves | merged/total | report |", "|---|---|---|---|---|---|---|",
      (.layers[] | . as $L | ($T | map(select(.layer==$L.layer))) as $lt
        | "| \($L.layer) | \($L.title) | \($L.status) | \($L.base_tag // "—") | \($L.waves|length) | \($lt|map(select(.status=="MERGED"))|length)/\($lt|length) | \(if $L.report_file then ("LAYER-"+($L.layer|tostring)|link) else "—" end) |"),
      "", "## Open tasks", "",
      (if ($open|length)==0 then "_none_" else
        "| task | status | layer | wave | risk | strikes | rejects | PR |", "|---|---|---|---|---|---|---|---|",
        ($open[] | "| \(.id|link) | \(.status) | \(.layer) | \(.wave) | \(.risk) | \(.strikes) | \(.reviews|map(select(.verdict=="REJECT"))|length) | \(.pr_url // "—") |") end),
      "", "## Quota", "", "| cli | 5h % | weekly % | state | resets at | source | checked |", "|---|---|---|---|---|---|---|",
      (.quota | to_entries[] | "| \(.key) | \(.value.five_hour_pct // "?") | \(.value.weekly_pct // "?") | \(.value.state // "UNKNOWN") | \(.value.resets_at // "—") | \(.value.source) | \(.value.checked_at // "—") |"),
      "", "## Recent incidents", "",
      (if (.incidents|length)==0 then "_none_" else (.incidents[-8:][] | "- `\(.at)` **\(.kind)** L\(.layer) \(if .task then (.task|link) else "" end) — \(.detail)") end),
      "", "## Resume prompt (Tier 1, paste into `codex`)", "", "```text",
      "You are Tier 1 (gpt-6.1-sol, high reasoning) resuming the fleet for project \"\(.project)\" in repository \($repo).",
      "Read, in this order: .agents/STATE.md, .agents/ledger.json, .agents/architecture/SYSTEM_SPEC.md, .agents/layers.yaml, graphify-out/GRAPH_REPORT.md (if present).",
      "Current layer: \(.current_layer) (\($cur.status // "unknown")). Run state: \(.run_state // "IDLE")\(if .halt_reason then ". Halt reason: " + .halt_reason else "" end).",
      "Merged tasks: \($merged)/\($T|length). Open: \($open|map(.id)|join(", ") | if .=="" then "none" else . end).",
      "Blocked (needs Surgery or human): \($blocked|map(.id + "=" + .status)|join(", ") | if .=="" then "none" else . end).",
      "Rules: do NOT re-plan layers whose status is SIGNED_OFF or CLOSED. Do NOT edit .agents/ledger.json or any .agents/tasks/*.md; orchestrate.sh owns them.",
      "Job: confirm SYSTEM_SPEC.md and .agents/layers.yaml still satisfy IDEA.md for layers >= \(.current_layer). If a change is required, edit only those two files and explain it in .agents/architecture/RESUME-NOTES.md. If nothing is required, write the single line OK to .agents/resume.ok and exit.",
      "Then exit. orchestrate.sh resumes the loop from the ledger.",
      "```", ""
  ' --argjson current_layer "$(jq '.current_layer' "$LEDGER")" "$LEDGER" > "$tmp" || { rm -f "$tmp"; warn "checkpoint jq failed"; return 1; }
  mv -f "$tmp" "$STATE_FILE"
}
