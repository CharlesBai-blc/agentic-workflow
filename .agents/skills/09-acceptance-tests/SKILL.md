---
name: 09-acceptance-tests
description: Tier 2 Phase A (claude-opus-5-5). Write one frozen acceptance test file per task, derived only from the frozen contracts and SYSTEM_SPEC, before any implementation exists. Tests are black-box, deterministic, runnable by `just check`, and listed in .agents/frozen.list.
tier: 2
model: claude-opus-5-5
tags: [skill, tier-2, tests]
---

# 09 — Frozen acceptance tests (Tier 2 Phase A)

## Purpose
Acceptance tests are the definition of done for a task and the anchor that stops a coder from gaming its own unit tests. They are written before the implementation, from the contract and the spec, and frozen: after this pass only a Surgery pass may edit them, and their SHA-256 is checked by the tripwires after every Tier 3 pass.

## Where and how
- One file per task, named after the task's subject, under the project's test root in a dedicated folder: `tests/acceptance/<subject>.acc.test.ts` (Vitest/Jest) or `tests/acceptance/test_<subject>_acc.py` (pytest). Pick the convention `just check` already runs; if `just check` does not run that folder, make the recipe in IDEA.md the source of truth and place the files where it will find them.
- Import only from the frozen contract paths and the public entry points the contract names. Never import implementation internals; the file the coder will write may not exist yet.
- Add the path to `.agents/frozen.list` and to the task's `acceptance_tests` and `readonly_files`.

## What a frozen acceptance test contains
1. **Contract conformance.** Every exported function or method in the contract is called at least once with a valid input and its result shape asserted against the contract type (runtime shape checks for dynamic languages).
2. **Specified behaviors.** One test per behavior the contract documents: happy path, each documented error (asserted by error type or code, not message text), boundary values the spec names.
3. **Invariants from SYSTEM_SPEC.** Design requirements the task is responsible for, stated as assertions (idempotency, ordering, limits).
4. **Nothing else.** No performance timing, no snapshot of large structures, no network, no clock dependence (inject time via the contract or fake timers), no filesystem outside a temp dir.

## Rules that keep the fleet honest
- Deterministic: same result on every run, in parallel, on a cold machine with `pnpm install --offline` / `uv sync --frozen`. No sleeps, no real services. If the contract needs a store, the contract must expose an in-memory or fake adapter; if it does not, fix the contract now, in Part 1 of [[02-task-slicing]].
- Black-box: the test must be satisfiable by any correct implementation of the contract, and unsatisfiable by a stub (`NotImplementedError`, `throw new Error("not implemented")`, hardcoded returns). Include at least two inputs per behavior so a constant return fails.
- Self-checking against the escape hatch: the file must parse and type-check against the contract as written, with no implementation present, so a `CONTRACT_DEFECT` receipt is always the coder's honest signal and never a test typo. Run the type checker or `python -m py_compile` on each file before freezing.
- Size: under 200 lines per file. Prefer table-driven cases.
- Names read as requirements: `it("returns NotFoundError for an unknown id")`, not `it("works")`.

## Template (TypeScript, Vitest)
```ts
import { describe, it, expect } from "vitest";
import type { UserRepository } from "../../contracts/user-repo";   // frozen contract
import { createUserRepository } from "../../src/adapters/user-repo"; // public entry point named by the contract

const cases = [["a1", "Ada"], ["b2", "Brian"]] as const;

describe("UserRepository (acceptance)", () => {
  const repo: UserRepository = createUserRepository({ driver: "memory" });
  it.each(cases)("stores and finds %s", async (id, name) => {
    await repo.save({ id, name });
    expect(await repo.findById(id)).toEqual({ id, name });
  });
  it("throws NotFoundError for an unknown id", async () => {
    await expect(repo.findById("missing")).rejects.toMatchObject({ code: "NOT_FOUND" });
  });
});
```

## Exit checklist
Every task has exactly one acceptance file; each file type-checks against its contract; each path is in `.agents/frozen.list`; no `.skip`, `.only`, `.todo`, `xit`, or `pytest.mark.skip` anywhere (the gate would reject the coder for touching them, and the file is frozen for you too).
