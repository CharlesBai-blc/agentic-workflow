@AGENTS.md

# CLAUDE.md — Claude-only additions

Everything that applies to all tiers lives in `AGENTS.md` (imported above) so the two files cannot
drift. The rules below exist only because Claude Code has tools and settings Codex does not.

## Permissions and hooks you run under
- Passes run with `--dangerously-skip-permissions`; the only guarantees are deny rules and hooks, so
  treat them as law, not as prompts to work around.
- `permissions.deny`: `Task`, `Agent`, `Bash(git reset --hard:*)`, `Bash(rm -rf:*)`, `WebFetch`,
  `WebSearch`. Never attempt an equivalent through another tool.
- PreToolUse on `Glob`/`Grep` (`.claude/hooks/search-guard.sh`): blocked for source code once a graph
  exists. Use `graphify query` / `graphify path` through Bash; the hook's error text tells you which
  paths are still searchable (contracts, schemas, config, `.agents/`, `docs/`).
- PostToolUse on `mcp__codex__codex` (`.claude/hooks/surgery-integrity.sh`): every Surgery dispatch is
  answered with `GATE: PASS` or `GATE: FAIL — <reason>`. On FAIL, re-dispatch at most once with the
  reason included; then stop and record the outcome in `.agents/reviews/TASK-ID-surgery.md`.

## Pass discipline
- You are launched by `orchestrate.sh` with `--max-turns` from `IDEA.md`. Budget turns: read what the
  prompt already contains before opening anything else; write outputs early so a turn cap still
  leaves usable files.
- Only the Surgery pass has MCP servers (`--mcp-config .claude/surgery-mcp.json --strict-mcp-config`).
  In Phase A and Phase B there is no `codex` tool; do not look for one.
- Structured output: Phase B returns its verdict through `--json-schema`. If your final message cannot
  carry structured output, write the same JSON to `.agents/reviews/LAYER-N-verdict.json`; the
  orchestrator accepts either.
- Never run `git commit`, `git push`, `gh`, `graphify update`, or edit `.agents/ledger.json`. Write
  files, list frozen paths in `.agents/frozen.list`, and exit; the loop does the rest.

## Where your outputs go
| Pass | Files |
|---|---|
| Phase A | contracts, `tests/acceptance/*`, `.agents/frozen.list` (append), `.agents/tasks/TASK-LLL-NNN.md` |
| Phase B | `.agents/reviews/LAYER-N-signoff.md`, optional rework task files, verdict JSON |
| Surgery | patched contract/test (root repo, not the worktree) or rewritten task file, `.agents/reviews/TASK-ID-surgery.md` |

## Tone
Write for a bash script and a sleeping human: deterministic file names, exact frontmatter keys, short
summaries. No questions, there is nobody to answer them until morning.
