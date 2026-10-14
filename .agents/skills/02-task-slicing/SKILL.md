---
name: 02-task-slicing
description: Tier 2 Phase A (claude-opus-5-5). Freeze the layer's interface contracts, then slice the layer into atomic, disjoint task files grouped into parallel-safe waves, computing READONLY_FILES with graphify first and Grep/Glob only for contracts, schemas and config.
tier: 2
model: claude-opus-5-5
tags: [skill, tier-2, slicing]
---

# 02 — Contract freeze and task slicing (Tier 2 Phase A)

## When this runs
Once per layer, as a standalone `claude -p` pass. The layer's base tag already exists on `main`. You write files and exit. `orchestrate.sh` commits the freeze, records `.agents/frozen.sha256`, runs `graphify update`, imports your task files into the ledger, and pushes. You never commit, push, edit `.agents/ledger.json`, or spawn subagents (`Task`/`Agent` are denied).

## Part 1 — Contract-first freeze
1. From SYSTEM_SPEC §5 and §6, write every interface this layer introduces or changes: `.d.ts` / `.py` Protocols / traits, JSON schemas, OpenAPI fragments, DB schema files. Put them where the spec says (`contracts/`, `schemas/`, `src/**/contracts/`). Contracts are complete and compilable: real types, documented error cases, no `TODO`.
2. Invoke [[09-acceptance-tests]] to write one frozen acceptance test file per task you are about to create.
3. Append each frozen path (contracts and acceptance tests), one per line, repo-relative, to `.agents/frozen.list`. Never remove earlier lines; earlier layers stay frozen.
4. Contracts and tests are immutable after this pass. Only a Surgery pass may change them.

## Part 2 — Structure first (zero-token mapping)
Before deciding allowlists, map the code with the AST graph, via Bash:
```bash
graphify query "what depends on <module or symbol>"
graphify path <fileA> <fileB>
```
Use the results to find every file a task's implementation will import or be imported by. `Glob`/`Grep` are blocked by a hook for source files; they are allowed only for contracts (`*.d.ts`, `contracts/`, `schemas/`, OpenAPI), config (`package.json`, `pyproject.toml`, `justfile`, `*.yaml`, `*.toml`) and markdown under `.agents/` or `docs/`, because those are not in the graph. If the graph is empty (greenfield layer 0), the allowlist is the contracts plus the acceptance tests plus the files the task creates.

## Part 3 — Slicing into tasks
Write `.agents/tasks/TASK-LLL-NNN.md` (layer zero-padded to 3 digits, NNN from 001). One task equals one PR a careful engineer finishes in one sitting: 1–4 owned files, one contract, one acceptance test. Required frontmatter:
```yaml
---
id: TASK-001-003
type: task
title: Implement UserRepository against the Postgres adapter contract
layer: 1
wave: 0
status: PENDING
risk: low                      # high => reviewer runs at high reasoning effort
kind: feature                  # feature | rework | fix
owned_files: [src/adapters/user-repo.ts, src/adapters/user-repo.test.ts]
readonly_files: [contracts/user-repo.d.ts, tests/acceptance/user-repo.acc.test.ts, src/domain/user.ts]
approved_deps: []              # packages the coder may add; empty means none
acceptance_tests: [tests/acceptance/user-repo.acc.test.ts]
depends_on: []                 # task ids in earlier waves
tags: [task, layer-1, adapters]
---
```
Body sections: **Goal** (2–4 sentences), **Contract** (`[[user-repo.d]]`-style wikilinks to the frozen files), **Acceptance criteria** (bullets mirroring the test names), **Implementation notes** (≤6 bullets), **Non-goals**.

Rules the gate and tripwires enforce, so get them right here:
- `owned_files` of tasks in the same `wave` are pairwise disjoint. Tasks that must touch the same file go in different waves, or the file is split first by an earlier task.
- `readonly_files` has 3–8 entries and always includes the task's acceptance test(s) and contract(s). The compiled prompt packs these files verbatim, so the budget is real: keep the total under roughly 100K tokens.
- Every file the task will import that is not a contract goes in `readonly_files`, otherwise the coder cannot see it.
- `approved_deps` lists exact package names. A manifest change with a package not listed here quarantines the task.
- `risk: high` for auth, payments, persistence migrations, concurrency, or anything touching a public API; `low` otherwise.
- Waves are numbered from 0; `depends_on` only references lower waves.

## Sizing heuristics
- A layer typically yields 4–12 tasks in 1–3 waves. More than 15 tasks means the layer plan is too coarse; note it in the task body and slice anyway.
- If a feature cannot be split so that each piece passes its own acceptance test, the contract is wrong: fix the contract in Part 1 before slicing.
- Prefer creating new files over editing shared ones; shared files become their own tiny tasks in wave 0.

## Rework and fix tasks (Phase B / Surgery reuse)
Same format, `kind: rework` or `kind: fix`, next free NNN, a wave number higher than every existing wave in the layer, and `depends_on` naming the tasks whose output is being corrected.

## Exit checklist
- `.agents/frozen.list` lists every contract and acceptance test path.
- Every task file validates: frontmatter keys above, lists as YAML flow sequences, acceptance tests present in `readonly_files`.
- No two same-wave tasks share an owned file. Then exit.
