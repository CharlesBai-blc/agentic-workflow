---
name: 05-code-review
description: Two modes. Tier 3 per-task review (gpt-6.1-sol, read-only sandbox) of `git diff main...agent/TASK-ID` returning an APPROVE/REJECT JSON verdict; and Tier 2 Phase B layer audit (claude-opus-5-5) of `git diff layer-N-base...main` returning SIGNED_OFF/REWORK plus a sign-off note.
tier: 3
model: gpt-6.1-sol
tags: [skill, tier-3, tier-2, review]
---

# 05 — Code review (per-task) and layer audit (Phase B)

Both modes share one stance: the contract and the acceptance tests are the spec. Review against them, not against taste. Findings are specific (`file:line`) and few. No diffs or logs are ever copied into the output.

## Mode A — Tier 3 per-task review (read-only, offline)
You run in the task worktree with `--sandbox read-only`. Context: this skill, AGENTS.md, the task file, the frozen contracts. Reasoning effort is `medium`, or `high` when the task is `risk: high`.

Procedure:
1. `git diff --stat main...agent/TASK-ID` — confirm every path is in `OWNED_FILES` and the diff is the size the task implies. Unexpected files or a very large diff are findings.
2. `git diff main...agent/TASK-ID` — read the full diff once. Check, in order:
   - **Contract adherence.** Exported names, signatures, return and error types match the frozen contract exactly. Behavior described in contract comments is implemented, not approximated.
   - **Test honesty.** The task's own tests exercise the real code path. Red flags: tests asserting on mocks of the unit under test, tautologies (`expect(x).toBe(x)`), loosened assertions, deleted cases, snapshot-everything, catching and swallowing errors. Frozen acceptance tests must be untouched (the tripwire checks hashes; you check intent).
   - **Correctness.** Boundary conditions, error paths, concurrency where relevant, resource cleanup.
   - **Standards.** Files ≤300 lines, no suppression comments, no `any`, no stubs, no dead code, no secrets.
3. Decide. `APPROVE` requires `contract_adherence: FULL` and `test_adherence: HONEST` with at most minor notes. Anything blocker or major is `REJECT`.

Output: your final message is exactly one JSON object validating against `.agents/schemas/review.json`:
```json
{"task_id": "TASK-001-003", "verdict": "REJECT",
 "reasons": [{"severity": "major", "location": "src/adapters/user-repo.ts:88", "reason": "findById returns undefined on a missing row; the contract requires a NotFoundError."}],
 "contract_adherence": "PARTIAL", "test_adherence": "HONEST"}
```
At most 5 reasons, one or two sentences each, actionable for a coder who will fix them without seeing your reasoning. `orchestrate.sh` posts the verdict to the PR as a comment and re-dispatches the coder once on REJECT; a second REJECT escalates to Surgery, so a REJECT must be worth that cost.

## Mode B — Tier 2 layer audit (Phase B, Claude Opus)
You run in the root repo after every task of layer N is merged. Context: SYSTEM_SPEC.md, the ledger view of the layer's tasks, and the deterministic pre-audit summary (knip/vulture, optional mutation sample) provided as attempt context. Treat the summary as evidence to confirm, not as orders.

Procedure:
1. `git diff --stat layer-N-base...main`. Map each file to a task and a spec section. Files that belong to no task or no spec section are findings.
2. Open full hunks (`git diff layer-N-base...main -- <file>`) only for files that look inconsistent with SYSTEM_SPEC or a frozen contract: wrong layer boundary, contract implemented twice, missing error path, suspicious test changes. Do not read the whole diff; the per-task reviews already did.
3. Check layer exit criteria from SYSTEM_SPEC §6 and the design requirements the layer claims to satisfy.
4. Write `.agents/reviews/LAYER-N-signoff.md`:
   ```markdown
   ---
   title: LAYER-N-signoff
   type: signoff
   layer: N
   verdict: SIGNED_OFF | REWORK
   tags: [signoff, layer-N]
   ---
   # Layer N sign-off
   ## Verdict and summary (≤5 sentences)
   ## Design requirements covered (DR-x → [[TASK-...]])
   ## Findings (file:line → finding → spec section)
   ## Rework tasks (if any; [[TASK-...]] links)
   ```
5. If `REWORK`: write new task files with [[02-task-slicing]] rules (`kind: rework`, next free NNN, a new wave, `depends_on` the tasks being corrected). Keep rework small and specific; a REWORK that re-implements the layer is a spec failure, not a rework.
6. Return the verdict as structured output validating against `.agents/schemas/layer-verdict.json` (`layer`, `verdict`, `summary`, `spec_drift`, `rework_tasks`, `audit_file`). If structured output is unavailable, write the same JSON to `.agents/reviews/LAYER-N-verdict.json`.

Never commit, push, edit `.agents/ledger.json`, or use `Task`/`Agent`. Exit when the files are written.
