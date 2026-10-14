---
# ============================================================================
# IDEA.md — project intake. The frontmatter is machine-read by orchestrate.sh
# (scripts/lib/common.sh idea_get). The body is read by Tier 1 (01-spec-writing).
# Fill every key; keep the key names exactly as they are.
# ============================================================================
project: my-project                 # short name; used in reports, PR titles, ntfy
type: idea
tags: [idea, intake]

stack:
  language: ts                      # ts | python | none
  package_manager: pnpm             # pnpm | uv | none
  runtime: node22                   # free text, for the spec
  test_runner: vitest               # free text, for the spec and acceptance tests

repo:
  layout: flat                      # flat | workspace   (workspace = pnpm workspaces / uv workspace / editable installs)
  symlink_root_deps: false          # true ONLY for flat single-package repos with no editable installs;
                                    # worktrees then symlink root node_modules/.venv instead of installing

quota:                              # Section 1.8 — subscription guardrails (ChatGPT Plus + Claude Pro only)
  soft_ceiling_pct: 80              # pause when either CLI's 5h or weekly window is at/above this
  max_sleep_hours: 6                # if the reported reset is further away than this, halt instead of sleeping
  max_parallel_workers: 2           # coder passes launched concurrently per wave (disjoint OWNED_FILES)

timeouts:                           # hard wall-clock limits per pass, minutes (gtimeout); timeout = strike
  tier1_min: 45
  phase_a_min: 40
  phase_b_min: 30
  surgery_min: 40
  coder_min: 50
  reviewer_min: 15
  closeout_min: 25
  gate_min: 20                      # `just check` inside the gate and the post-merge gate

max_turns:                          # --max-turns for Claude Opus passes
  phase_a: 60
  phase_b: 40
  surgery: 50

effort:
  coder: medium                     # Codex model_reasoning_effort for coders (reviewers: medium, or high when risk: high)

pr:
  base: main                        # branch PRs target; tags layer-N-base are cut from it
  wait_for_checks: true             # wait for GitHub checks (if any) before `gh pr merge`

ntfy:
  topic: ""                         # e.g. my-project-fleet-8f3a (keep it unguessable); empty disables pushes
  server: https://ntfy.sh

quality:
  mutation_sampling: false          # Stryker (ts) / mutmut (python) sample in the Phase B pre-audit
---

# <Project name>

> Fill in every section. Tier 1 turns this into `SYSTEM_SPEC.md` and the layer plan; nothing here is
> read by Tier 3 coders, so write for an architect, not for a coder. Link vault notes with
> `[[Wikilinks]]`: [[SYSTEM_SPEC]], [[PROGRESS]], [[STATE]].

## 1. Vision
One paragraph: who uses this, what it does for them, why it exists. One sentence on what "done" means
for the whole project.

## 2. MVP scope
Numbered list of user-visible capabilities the MVP must have. Each item should be demonstrable in a
sentence ("a user can …"). Keep it to the smallest set that is useful; the fleet will build exactly
this and nothing more.

1. …
2. …

## 3. Explicit non-goals
Numbered list of things the fleet must NOT build, even if tempting (admin UIs, auth providers,
multi-tenancy, i18n, mobile, analytics, …). Tier 1 copies these into the spec as hard boundaries.

1. …

## 4. Locked tech stack
The stack is fixed for the whole run; agents may not add frameworks or swap libraries.

| Concern | Choice | Notes |
|---|---|---|
| Language / runtime | TypeScript 5.x on Node 22 | strict mode |
| Framework | … | |
| Persistence | … | in-memory adapter required for acceptance tests |
| Test runner | vitest | acceptance tests under `tests/acceptance/` |
| Lint / format | eslint + prettier | zero warnings |
| Build | … | |

Allowed dependency policy: tasks may add only packages listed in their `APPROVED_DEPS`; Tier 2 grants
them per task. List any packages you pre-approve for the whole project here:

- …

## 5. Design standards
- Files under 300 lines; split by responsibility.
- Contracts first: every module boundary has a frozen `.d.ts` / schema before implementation.
- Errors are typed values at boundaries (`{ code: "NOT_FOUND" }`-style), exceptions only for bugs.
- No `any`, no suppression comments, no stubs, no `TODO` in committed code.
- Module layering (Tier 1 encodes this as the `yaml boundaries` block in the spec):
  `domain` → may import nothing; `application` → `domain`; `adapters` → `domain`, `application`;
  `entrypoints` → everything.
- Logging and configuration conventions: …
- Anything else a reviewer should enforce: …

## 6. `just check`
The single deterministic quality entry point. Copy this recipe into the repo's `justfile` before the
first run (`doctor.sh` verifies the `check` recipe exists). It must exit non-zero on any failure and
print one summary line per tool.

```just
set shell := ["bash", "-euo", "pipefail", "-c"]

check: typecheck lint test

typecheck:
    pnpm exec tsc --noEmit

lint:
    pnpm exec eslint . --max-warnings 0

test:
    pnpm exec vitest run --reporter=dot
```

Python equivalent:

```just
check:
    uv run mypy src
    uv run ruff check .
    uv run pytest -q
```

## 7. Repo layout
Describe the directory layout Tier 1 should assume (`src/domain`, `src/app`, `src/adapters`,
`contracts/`, `tests/acceptance/`, …). State whether the repo is a flat single package or a
workspace; this decides how worktrees install dependencies (see `repo.symlink_root_deps` above).

## 8. Operational notes for the fleet
- Expected number of layers (3–7 is typical) and any ordering constraints Tier 1 must respect.
- Known risky areas that should be `risk: high` (auth, payments, migrations, concurrency).
- External services the acceptance tests must fake (the contract must expose a fake adapter).
- Anything the operator wants in every `docs/reports/LAYER-N.md` narrative.
