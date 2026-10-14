#!/usr/bin/env bash
# PostToolUse hook on mcp__codex__codex — Surgery Integrity Gate (zero tokens, <1s).
#
# After every Tier 3 fix dispatched by Opus through the Codex MCP bridge, verify
# the task worktree without re-running the test suite:
#   (a) consistent working tree: no unmerged paths, no merge/rebase in progress,
#       no untracked files outside OWNED_FILES (uncommitted edits inside
#       OWNED_FILES are expected — Tier 3 never commits; orchestrate.sh does);
#   (b) every changed path (index + working tree, vs. main) is in OWNED_FILES;
#   (c) no changed, non-excluded file exceeds LINE_LIMIT (300) lines;
#   (d) the Section 4 tripwires pass (local checks; the remote-main check is
#       repeated by orchestrate.sh after the Surgery pass, so this stays <1s).
#
# Output to the model is exactly one line: "GATE: PASS" (as additionalContext)
# or "GATE: FAIL — <reason>" (stderr, exit 2). Details go to .agents/logs/.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" || exit 0
# shellcheck source=../../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/tripwire.sh
source "$ROOT/scripts/lib/tripwire.sh"

input="$(cat)"
task="${AGENTS_SURGERY_TASK:-}"
[[ -z "$task" && -f "$ROOT/.agents/surgery.current" ]] && task="$(tr -d '[:space:]' < "$ROOT/.agents/surgery.current")"

logf="$ROOT/.agents/logs/surgery-gate-${task:-unknown}.log"
mkdir -p "$ROOT/.agents/logs"
{
  echo "=== $(date -u +%FT%TZ) surgery-integrity task=${task:-?}"
  printf '%s' "$input" | jq -c '{tool_name, cwd: .tool_input.cwd, prompt_len: (.tool_input.prompt // "" | length)}'
} >> "$logf" 2>&1

pass() { printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"GATE: PASS"}}\n'; echo "GATE: PASS" >> "$logf"; exit 0; }
fail() { echo "GATE: FAIL — $1" | tee -a "$logf" >&2; exit 2; }

[[ -n "$task" ]] || fail "no active Surgery task (AGENTS_SURGERY_TASK unset and .agents/surgery.current missing)"
wt="$(wt_dir "$task")"
[[ -d "$wt/.git" || -f "$wt/.git" ]] || fail "worktree $wt does not exist for $task"

mapfile -t owned < <(task_owned_files "$task")
[[ "${#owned[@]}" -gt 0 ]] || fail "$task has no OWNED_FILES in ledger or task file"

in_owned() { local f; for f in "${owned[@]}"; do [[ "$1" == "$f" ]] && return 0; done; return 1; }

# (a) consistent tree
if [[ -n "$(git -C "$wt" diff --name-only --diff-filter=U)" ]]; then fail "unmerged paths in worktree"; fi
for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD; do
  [[ -e "$(git -C "$wt" rev-parse --git-path "$marker")" ]] && fail "$marker present: merge/rebase in progress"
done
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  in_owned "$f" || fail "untracked file outside OWNED_FILES: $f"
done < <(git -C "$wt" ls-files --others --exclude-standard)

# (b) ownership of every change vs main (committed, staged and unstaged)
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  in_owned "$f" || fail "changed file outside OWNED_FILES: $f"
done < <(git -C "$wt" diff --name-only main)

# (c) line limit on changed files
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$wt/$f" ]] && continue
  line_limit_excluded "$f" && continue
  n="$(wc -l < "$wt/$f" | tr -d ' ')"
  [[ "$n" -le "$LINE_LIMIT" ]] || fail "$f has $n lines (> $LINE_LIMIT)"
done < <(git -C "$wt" diff --name-only main)

# (d) tripwires (local-only; remote main is re-verified by orchestrate.sh)
if ! tripwire_check "$task" --skip-remote >> "$logf" 2>&1; then
  fail "tripwire failed: $(tail -n 1 "$logf" | sed 's/^TRIPWIRE: //')"
fi

pass
