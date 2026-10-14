---
name: 04-code-execution
description: Tier 3 coder (gpt-6.1-sol). Implement one task inside its own git worktree against frozen contracts and acceptance tests, verify with `just check`, obey the 3-strike breaker and the contract-defect escape hatch, and return only the JSON receipt.
tier: 3
model: gpt-6.1-sol
tags: [skill, tier-3, coding]
---

# 04 — Code execution (Tier 3 coder)

## Ground rules
- You are inside `../<repo>.wt/TASK-ID` on branch `agent/TASK-ID`. It is the only place you may write. Writing anywhere else, including the root repository, trips a tripwire and quarantines the task.
- You may modify only the task's `OWNED_FILES`. Creating a file not in `OWNED_FILES` is an ownership failure.
- You never run `git commit`, `git push`, `git rebase`, `gh`, or change `main`. `orchestrate.sh` commits after its gate passes.
- You read only what the prompt contains (AGENTS.md, this skill, the frozen contracts and acceptance tests, the task file, the allowlist pack) plus your own `OWNED_FILES`. Do not open other files or run searches over the tree; the allowlist is complete by construction. If you believe a file is missing from it, that is a task defect: implement what you can against the contract and say so in `root_cause` only if you must escalate.
- You may install packages only if they are listed in `APPROVED_DEPS` (with the project's package manager, inside the worktree). Any other manifest change quarantines the task.
- Frozen contracts and acceptance tests are read-only. Never edit, skip, weaken, or mock them.

## Procedure
1. **Read the contract and the acceptance test first.** List the behaviors the test asserts. Those are the definition of done; the task body is commentary.
2. **Check the contract is satisfiable.** If a frozen contract or acceptance test has a syntax error, references a type or symbol that cannot exist, or demands two contradictory behaviors, stop now (see Contract defect below). Do not spend attempts working around it.
3. **Implement** in `OWNED_FILES`, smallest complete change first. Standards: files under 300 lines (split by responsibility if needed, within `OWNED_FILES`); no `any`, `@ts-ignore`, `eslint-disable`, `# type: ignore`, `# noqa`, `.skip`, `.only`, `TODO`, `NotImplementedError`, or placeholder bodies; the gate rejects these on added lines. Real error handling at boundaries, typed everywhere else.
4. **Verify** with `just check` in the worktree. Read only the summary and the first failing assertion; do not paste logs anywhere.
5. **Fix and re-verify.** Each `just check` failure after an attempted fix is one strike.

## 3-strike breaker
- Strike 1: fix the obvious cause, re-run.
- Strike 2: stop coding. Invoke [[10-failure-triage]] and write a one-paragraph root-cause hypothesis (what the test asserts, what the code does instead, the single most likely reason). Only then make attempt 3, which must address that hypothesis.
- Strike 3: stop immediately. Return `status: ESCALATE_STRIKE_3` with `root_cause` (≤3 sentences) and `triage_hypothesis`. Do not try a fourth time.
Gate failures and timeouts counted by `orchestrate.sh` share the same budget, so a pass that returns `DONE` with a gate-breaking change costs a strike too. Run the same checks the gate runs before returning.

## Contract defect escape hatch
If the frozen contract or acceptance test itself is broken (unparseable, impossible type constraint, self-contradictory assertions, imports a module that no task creates), return at once on strike 1:
```json
{"status": "CONTRACT_DEFECT", "defect_location": "contracts/user-repo.d.ts:42", "root_cause": "…"}
```
`defect_location` is the exact `file:line`. A Surgery pass will patch the contract and re-dispatch you. Guessing around a broken contract wastes the quota budget; escalating costs nothing.

## The receipt (your final message)
Your last message is exactly one JSON object that validates against `.agents/schemas/receipt.json`, with no prose, code, or logs around it:
```json
{
  "task_id": "TASK-001-003",
  "status": "DONE",
  "attempt": 1,
  "files_changed": ["src/adapters/user-repo.ts", "src/adapters/user-repo.test.ts"],
  "test_summary": {"passed": 14, "failed": 0, "skipped": 0, "command": "just check", "summary_line": "Tests 14 passed (14)"},
  "defect_location": null,
  "root_cause": null,
  "triage_hypothesis": null,
  "deps_added": []
}
```
`status` is `DONE` only when `just check` passed with zero failures. `attempt` is the attempt on which you stopped (1–3). `files_changed` must be a subset of `OWNED_FILES`. `summary_line` is the runner's single final line, never a log excerpt.

## What never goes in the receipt or the conversation
Diffs, file contents, stack traces, test logs, or commentary. The orchestrator captures the full event stream to `.agents/logs/` itself.
