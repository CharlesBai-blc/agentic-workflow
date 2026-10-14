---
title: AGENTS
type: constitution
tags: [fleet, rules]
---

# AGENTS.md — fleet constitution

This file is the first thing in every compiled prompt and is read by every tier (Codex Tier 1 and
Tier 3, Claude Tier 2). `CLAUDE.md` imports it; nothing here is Claude-specific. Where a rule has a
machine enforcer, the enforcer is named; passing it is not optional.

## 1. Hierarchy and roles
| Tier | Model | Pass | Owns |
|---|---|---|---|
| 1 | gpt-6.1-sol (high) | `codex exec`, once per project | `SYSTEM_SPEC.md`, `.agents/layers.yaml`, target diagram, initial dashboard |
| 2 | claude-opus-5-5 (high) | `claude -p`, once per layer for Phase A and Phase B; Surgery on escalation | contracts, acceptance tests, task files, layer sign-off, contract patches |
| 3 | gpt-6.1-sol (medium/low) | `codex exec`, per task | implementation in a worktree, per-task review verdict, closeout diagram, narrative |
| bash | `orchestrate.sh` | the loop | ledger, STATE.md, commits, tags, pushes, PRs, merges, gates, tripwires, quota, reports |

Every model invocation is a standalone pass that writes files and exits. No tier spawns another model
except Tier 2 Surgery, which may call Tier 3 through the `codex` MCP tool only. Claude never uses its
native `Task` / `Agent` subagents (denied in `.claude/settings.json`); all subagent work, including
Archify diagrams, runs on gpt-6.1-sol.

## 2. What only `orchestrate.sh` does
Commits, tags, pushes, `gh` calls, merges, reverts, `graphify update`, ledger writes, status changes,
STATE.md, PROGRESS.md and LAYER-N.md generation, worktree creation and removal. A model that does any
of these breaks the run: the tripwires compare `main`, remote `main`, the root working tree, sibling
worktrees, frozen hashes and manifests before and after every Tier 3 pass and quarantine the task on
any difference.

## 3. File ownership laws (Tier 3)
1. Work only inside `../<repo>.wt/TASK-ID` on branch `agent/TASK-ID`. Never in the root repo.
2. Modify only the task's `OWNED_FILES`. Gate: ownership check on `git diff main...agent/TASK-ID`.
3. Read only the compiled prompt (AGENTS.md, skill, frozen contracts and acceptance tests, task file,
   allowlist pack) plus your own `OWNED_FILES`. The pack is the whole allowlist; do not search the tree.
4. Never edit frozen contracts or acceptance tests. Tripwire: `.agents/frozen.sha256`.
5. Add packages only from `APPROVED_DEPS`. Tripwire: manifest and lockfile diff.
6. Tasks in one wave have disjoint `OWNED_FILES`; `orchestrate.sh` refuses to import a layer otherwise.

## 4. Graphify before search (Tier 1 and Tier 2)
Structure questions are answered from the local AST graph, zero tokens:
```bash
graphify query "<question>"        # what depends on X, where is Y used
graphify path <fileA> <fileB>      # dependency chain between two files
```
`graphify-out/GRAPH_REPORT.md` is the map; `orchestrate.sh` rebuilds it on `main` after contract
freeze, Surgery patches and every merge. Grep/Glob fallback is allowed only for files the graph cannot
hold: contracts (`*.d.ts`, `contracts/`, `schemas/`, `*.schema.json`, OpenAPI), config (`*.yaml`,
`*.toml`, `package.json`, `pyproject.toml`, `justfile`, lint and test configs) and markdown under
`.agents/` or `docs/`. A Claude PreToolUse hook blocks everything else with exit 2. Graphify runs
strictly in tree-sitter code mode (`.graphifyignore` excludes all prose); never run `graphify hook
install` or any semantic/doc mode.

## 5. Coding and design standards (all tiers)
- Files under 300 lines, excluding lockfiles, generated code, snapshots, migrations and data files.
- Zero stubs: no `TODO`, `FIXME`, `NotImplementedError`, `throw new Error("not implemented")`,
  placeholder bodies, `.skip`/`.only`/`.todo`, `@ts-ignore`, `eslint-disable`, `# type: ignore`,
  `# noqa`, new `any`. Gate: `ast-grep` anti-cheat on added lines.
- Layer boundaries from the spec's `yaml boundaries` block. Gate: dependency-cruiser / import-linter.
- No secrets. Gate: gitleaks on the diff.
- `just check` passes in the worktree before a receipt says `DONE`, and again on `main` after merge
  (failure reverts the merge and re-dispatches the task).
- Contracts and acceptance tests are immutable once frozen; only a Surgery pass changes them, and
  `orchestrate.sh` re-hashes, commits and pushes the change.

## 6. Contract defect protocol
A frozen contract or acceptance test that cannot be satisfied (syntax error, impossible type,
contradictory assertions, import of a module no task creates) is never worked around. The coder
returns on strike 1:
`{"status":"CONTRACT_DEFECT","defect_location":"<file>:<line>","root_cause":"<=3 sentences"}`.
`orchestrate.sh` pauses new dispatch in the layer and launches Surgery; Opus patches the contract or
test, or rewrites the task, and the coder is re-dispatched.

## 7. Strikes, escalation and breakers
- Three verification failures end a coder pass with `ESCALATE_STRIKE_3`; triage (skill 10) is
  mandatory before the third attempt. Bash gate failures and timeouts share the same budget.
- A review `REJECT` re-dispatches the coder once with the reasons on the same branch; a second
  `REJECT` escalates to Surgery.
- Tripwire failure quarantines the task, preserves the worktree and escalates to Surgery.
- Two failed Surgeries in a layer, or two Surgeries on one task without a merge, halt the run with
  `STATE.md`, an incident report and an ntfy push.

## 8. Receipts, not transcripts
No pass returns diffs, file contents or logs to any model. Tier 3 ends with one JSON object
(`.agents/schemas/receipt.json` or `review.json`); Tier 2 Phase B ends with one JSON object
(`layer-verdict.json`). `orchestrate.sh` keeps the full event stream in `.agents/logs/` and adds
`commit_sha` and `pr_url` to the ledger itself.

## 9. Cost guardrails
- Subscription auth only. `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are unset before every pass; a
  pass that needs them is misconfigured and must fail.
- Tier 2 (Claude Pro) is the scarce resource: one Phase A, one Phase B per layer, Surgery only on
  escalation, `--max-turns` capped from `IDEA.md`, no MCP servers except the `codex` bridge in Surgery.
- Tier 3 prompts stay under 100K input tokens: 3–8 allowlisted files, static content first for
  prefix caching. `compile-prompt.sh` refuses larger prompts and escalates the task.
- Quota is read from the CLIs' own signals (Codex rollout `rate_limits`, Claude `rate_limit_event`),
  `ccusage` is a secondary check. At the soft ceiling the loop pauses and auto-resumes at reset.

## 10. MCP delegation (Surgery only)
Only a Surgery pass loads `.claude/surgery-mcp.json`. Opus may dispatch at most two Tier 3 fixes per
Surgery through `mcp__codex__codex`, each with `cwd` set to the task worktree and the task file plus
defect embedded. A PostToolUse hook answers each dispatch with one line, `GATE: PASS` or
`GATE: FAIL — <reason>`, after checking the worktree is consistent, every change is in `OWNED_FILES`,
no file exceeds 300 lines and the tripwires hold. The hook never re-runs the test suite.

## 11. Vault conventions
Every markdown file under `.agents/` and `docs/` carries YAML frontmatter (`title`/`id`, `type`,
`tags`, plus `status`, `layer`, `wave`, `risk` where relevant) and links other notes with
`[[Wikilinks]]`; HTML diagrams are linked with relative markdown links. `set_status` in
`scripts/lib/ledger.sh` is the only writer of task status, and it writes the ledger and the task
frontmatter together, so Dataview and the loop never disagree.

## 12. Skills
| Skill | Used by |
|---|---|
| `.agents/skills/01-spec-writing/SKILL.md` | Tier 1 |
| `.agents/skills/02-task-slicing/SKILL.md` | Tier 2 Phase A, Surgery |
| `.agents/skills/04-code-execution/SKILL.md` | Tier 3 coder |
| `.agents/skills/05-code-review/SKILL.md` | Tier 3 reviewer (Mode A), Tier 2 Phase B (Mode B) |
| `.agents/skills/07-archify-diagramming/SKILL.md` | Tier 1, Tier 3 closeout |
| `.agents/skills/08-progress-narrative/SKILL.md` | Tier 3 closeout |
| `.agents/skills/09-acceptance-tests/SKILL.md` | Tier 2 Phase A, Surgery |
| `.agents/skills/10-failure-triage/SKILL.md` | Tier 3 coder (strike 2), Surgery |
| `.agents/skills/archify/SKILL.md` | installed with `npx skills add tt-a1i/archify --skill archify` |

Claude discovers the same directory through the `.claude/skills -> ../.agents/skills` symlink.
