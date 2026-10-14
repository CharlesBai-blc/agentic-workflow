---
name: 10-failure-triage
description: Tier 3 (gpt-6.1-sol). Mandatory after the second consecutive verification failure, before the third and final attempt. Produce a one-paragraph root-cause hypothesis from the failing assertion, the contract and the diff, then make exactly one targeted change. Also loaded by Tier 2 Surgery for context.
tier: 3
model: gpt-6.1-sol
tags: [skill, tier-3, triage]
---

# 10 — Failure triage (strike 2, before the last attempt)

## Why this exists
Two failed verifications in a row mean the mental model is wrong, not the typing. A third blind edit almost always fails and burns the task into `ESCALATE_STRIKE_3`. Ten minutes of triage usually saves the task, and when it cannot, it produces the `root_cause` the Surgery pass needs.

## Procedure (do not write code until step 5)
1. **Quote the failure precisely.** From the last `just check`, take the first failing test name and its first assertion message (one line each). Ignore everything after the first failure; cascades lie.
2. **Re-read the contract clause** that the failing test exercises. Write down, in one sentence, what the contract promises for that input.
3. **Trace your code path** for that exact input, by reading your own `OWNED_FILES` (not by running more tests). Write down, in one sentence, what the code actually does.
4. **Form the hypothesis.** One paragraph, three parts: *expected* (step 2), *actual* (step 3), *the single most likely cause*. Classify it:
   - **Logic**: wrong branch, off-by-one, wrong operator → fixable now.
   - **Shape**: wrong return/error type vs. the contract → fixable now; check every other method for the same mistake.
   - **Environment**: missing dependency from `APPROVED_DEPS`, wrong import path inside the allowlist, test runner configuration → fixable now only if the fix stays inside `OWNED_FILES` and `APPROVED_DEPS`; otherwise it is a task defect, escalate.
   - **Contract**: the test asserts something the contract makes impossible, or the contract/test does not parse → do not attempt 3; return `CONTRACT_DEFECT` with `defect_location`.
   - **Unknown**: you cannot connect expected and actual after steps 1–3 → make attempt 3 only if you can state one concrete change to try; otherwise return `ESCALATE_STRIKE_3` now with the hypothesis as `root_cause`, saving the quota.
5. **Make one change** that addresses the hypothesis, nothing else. No refactors, no "while I'm here" fixes.
6. **Verify once.** Pass → `DONE` receipt with `attempt: 3` and `triage_hypothesis` filled. Fail → stop; `ESCALATE_STRIKE_3` with `root_cause` (≤3 sentences, derived from the hypothesis and what the third attempt disproved) and `triage_hypothesis`.

## What good triage output looks like
> Expected: `findById("missing")` rejects with an error whose `code` is `NOT_FOUND` (contract §findById). Actual: the memory driver's `get` returns `undefined` and `findById` resolves with it. Cause: the adapter never maps the driver's absence signal to the contract's `NotFoundError`; the same gap likely exists in `delete`.

## Anti-patterns that waste the last attempt
- Editing the test (frozen; tripwire quarantines the task).
- Adding `try/catch` that swallows the error to make the assertion pass.
- Changing several files at once so the result cannot be attributed.
- Re-running `just check` repeatedly hoping for a different result; it is deterministic by construction.
- Reading files outside the allowlist "to understand the system"; the contract is the system.

## For Surgery passes (Tier 2)
When Opus reads this skill during Surgery, it applies the same classification to the `.fail.md`, receipt and review context: Logic/Shape → re-dispatch via a Codex MCP fix with the hypothesis embedded; Environment → rewrite the task (allowlist, `APPROVED_DEPS`); Contract → patch the contract or acceptance test; Unknown twice → leave it for the human, the breaker will halt.
