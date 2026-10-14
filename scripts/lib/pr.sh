#!/usr/bin/env bash
# scripts/lib/pr.sh — the ONLY place the fleet pushes or calls gh. Honors FLEET_DRY_RUN=1 by stubbing
# every remote operation (local merges emulate GitHub so the loop can be tested offline).
[[ -n "${__FLEET_PR_LOADED:-}" ]] && return 0
__FLEET_PR_LOADED=1
# shellcheck source=ledger.sh
source "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

PR_LOG="$LOG_DIR/pr.log"
_pr_retry() {  # exponential backoff 2,4,8,16 for network operations
  local i d=2
  for i in 1 2 3 4 5; do "$@" >>"$PR_LOG" 2>&1 && return 0; [[ $i -eq 5 ]] && return 1; log "retry $i: $*"; sleep $d; d=$((d*2)); done
}
_gh() { gh "$@" 2>>"$PR_LOG"; }
_pr_num() { task_get "$1" '.pr_number // empty'; }
_dry() { [[ "$FLEET_DRY_RUN" == 1 ]]; }
_dry_remote_sync() { main_sha > "$TMP_DIR/remote-main.sha"; }

pr_push_branch() {  # pr_push_branch TASK
  local t="$1"
  _dry && { log "[dry-run] push agent/$t"; return 0; }
  _pr_retry git -C "$(wt_dir "$t")" push -u origin "agent/$t" --force-with-lease
}

pr_create() {  # pr_create TASK <title> <bodyfile> -> prints URL; records pr_url/pr_number
  local t="$1" title="$2" body="$3" url n
  if _dry; then
    n=$(( $(cat "$TMP_DIR/pr.counter" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP_DIR/pr.counter"
    url="https://github.invalid/dry-run/$REPO_NAME/pull/$n"
  else
    url="$(_gh pr create --base "$(base_branch)" --head "agent/$t" --title "$title" --body-file "$body")" || die "gh pr create failed for $t"
    n="${url##*/}"
  fi
  task_set "$t" '.pr_url=$u | .pr_number=($n|tonumber)' --arg u "$url" --arg n "$n"
  log "PR #$n opened for $t: $url"; echo "$url"
}

pr_comment() {  # pr_comment TASK <markdown body>
  local t="$1" n; n="$(_pr_num "$t")"; [[ -n "$n" ]] || { warn "pr_comment: $t has no PR"; return 0; }
  _dry && { printf '%s\n---\n' "$2" >> "$TMP_DIR/pr-$n.comments"; return 0; }
  _pr_retry gh pr comment "$n" --body "$2"
}

pr_review_comment_body() {  # pr_review_comment_body TASK <review.json> -> markdown
  jq -r --arg t "$1" '"## Tier 3 review: **\(.verdict)** (\($t))\n\ncontract: `\(.contract_adherence)` · tests: `\(.test_adherence)`\n" +
    (if (.reasons|length)==0 then "\nNo findings." else "\n" + (.reasons | map("- **\(.severity)** `\(.location)` — \(.reason)") | join("\n")) end) +
    "\n\n_Posted by orchestrate.sh; the reviewer runs read-only with no network._"' "$2"
}

pr_checks_ok() {  # pr_checks_ok TASK -> 0 when GitHub checks pass (or none exist / waiting disabled)
  local t="$1" n js; n="$(_pr_num "$t")"
  [[ "$(idea_get '.pr.wait_for_checks' true)" == true ]] || return 0
  _dry && return 0
  js="$(_gh pr checks "$n" --json name,state,bucket 2>/dev/null || echo '[]')"
  [[ "$(jq 'length' <<<"$js")" -eq 0 ]] && return 0
  if [[ "$(jq '[.[] | select(.bucket=="pending")] | length' <<<"$js")" -gt 0 ]]; then
    run_with_timeout 1800 "$PR_LOG" -- gh pr checks "$n" --watch --fail-fast || true
    js="$(_gh pr checks "$n" --json name,state,bucket 2>/dev/null || echo '[]')"
  fi
  [[ "$(jq '[.[] | select(.bucket!="pass" and .bucket!="skipping")] | length' <<<"$js")" -eq 0 ]] && return 0
  jq -r '.[] | select(.bucket!="pass" and .bucket!="skipping") | "check failed: \(.name) (\(.bucket))"' <<<"$js" | tee -a "$PR_LOG" >&2
  return 1
}

pr_mergeable() {  # pr_mergeable TASK -> 0 MERGEABLE, 1 CONFLICTING/unknown after retries
  local t="$1" n m i; n="$(_pr_num "$t")"
  if _dry; then git -C "$ROOT" merge-tree --write-tree "$(base_branch)" "agent/$t" >/dev/null 2>&1; return $?; fi
  for i in 1 2 3 4 5 6; do
    m="$(_gh pr view "$n" --json mergeable -q .mergeable 2>/dev/null)"
    case "$m" in MERGEABLE) return 0 ;; CONFLICTING) return 1 ;; *) sleep 5 ;; esac
  done
  return 1
}

pr_merge() {  # pr_merge TASK -> prints merge SHA on main; merge commits only (git revert -m 1 must work)
  local t="$1" n st; n="$(_pr_num "$t")"
  if _dry; then
    git -C "$ROOT" merge --no-ff --no-edit -m "Merge pull request #$n from agent/$t" "agent/$t" >>"$PR_LOG" 2>&1 || return 1
    _dry_remote_sync; main_sha; return 0
  fi
  gh pr merge "$n" --merge --delete-branch --subject "Merge pull request #$n from agent/$t" >>"$PR_LOG" 2>&1 || true
  st="$(_gh pr view "$n" --json state -q .state 2>/dev/null)"
  [[ "$st" == MERGED ]] || { log "PR #$n not merged (state=$st)"; return 1; }
  _pr_retry git -C "$ROOT" pull --ff-only origin "$(base_branch)" || die "ff pull of $(base_branch) failed after merging #$n"
  main_sha
}

pr_push_main() {
  _dry && { _dry_remote_sync; return 0; }
  _pr_retry git -C "$ROOT" push origin "$(base_branch)"
}
pr_push_tag() {  # pr_push_tag TAG
  _dry && return 0
  _pr_retry git -C "$ROOT" push origin "refs/tags/$1"
}
pr_delete_remote_branch() {  # after a revert re-dispatch, the old branch is gone with the merge; ensure
  _dry && return 0
  git -C "$ROOT" push origin --delete "agent/$1" >>"$PR_LOG" 2>&1 || true
}
pr_body_for_task() {  # pr_body_for_task TASK <receipt.json> <bodyfile>
  local t="$1" r="$2"
  { echo "## $t — $(task_get "$t" '.title')"; echo
    echo "Layer $(task_layer "$t") · wave $(task_get "$t" '.wave') · risk \`$(task_risk "$t")\`"; echo
    echo "Task file: \`.agents/tasks/$t.md\`"; echo
    echo "### Receipt"; echo '```json'; jq '{status, attempt, files_changed, test_summary}' "$r"; echo '```'; echo
    echo "_Opened by orchestrate.sh after the zero-token gate and tripwires passed._"; } > "$3"
}
