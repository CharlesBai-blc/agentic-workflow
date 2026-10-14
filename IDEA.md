---
# ============================================================================
# IDEA.md — project intake. This is the ONLY file a human writes.
# Frontmatter: machine-read by orchestrate.sh (keep every key; change values).
# Body: read by Tier 1 (spec + layer plan) and injected into every Phase A
# prompt, so keep the whole file under 600 lines / ~25K tokens.
# Fill it with an agent using IDEATE.md, then run scripts/idea-check.sh.
# ============================================================================
project: my-project # kebab-case; used in reports, PR titles, ntfy
type: idea
ready: false # idea-check.sh flips this to true when every check passes
tags: [idea, intake]
stack:
  language: ts # ts | python | none
  package_manager: pnpm # pnpm | uv | none
  runtime: node22 # free text, copied into the spec
  test_runner: vitest # free text; acceptance tests must run under it
repo:
  layout: flat # flat | workspace (pnpm workspaces / uv workspace / editable installs)
  symlink_root_deps: false # true ONLY for flat single-package repos with no editable installs
deps:
  pre_approved: [] # packages Tier 2 may grant to any task without asking, e.g. [zod, pino]
quota: # subscription guardrails (ChatGPT Plus + Claude Pro, no API keys)
  soft_ceiling_pct: 80 # pause when either CLI's 5h or weekly window reaches this
  max_sleep_hours: 6 # halt instead of sleeping if the reset is further away
  max_parallel_workers: 1 # coder passes per wave; raise to 2–3 after the first clean layer
timeouts: # minutes per pass; a timeout counts as a strike
  tier1_min: 45
  phase_a_min: 40
  phase_b_min: 30
  surgery_min: 40
  coder_min: 50
  reviewer_min: 15
  closeout_min: 25
  gate_min: 20
max_turns: # --max-turns for Claude Opus passes
  phase_a: 60
  phase_b: 40
  surgery: 50
effort:
  coder: medium # Codex reasoning effort for coders (reviewers: medium, high when risk: high)
pr:
  base: main
  wait_for_checks: true # wait for GitHub checks (if any) before merging
ntfy:
  topic: "" # unguessable, e.g. my-project-fleet-8f3a; empty disables pushes
  server: https://ntfy.sh
quality:
  mutation_sampling: false # Stryker / mutmut sample during the Phase B pre-audit
---

# <Project name>

> **How to read this file.** Each section states *why the fleet needs it* and a *ready when* test.
> Tier 1 turns §1–§12 into `SYSTEM_SPEC.md` and the layer plan; Tier 2 reads §4–§9 when freezing
> contracts and granting dependencies. No human answers questions during a run, so anything left
> vague here becomes a guess at 3 a.m. Links: [[SYSTEM_SPEC]] · [[PROGRESS]] · [[STATE]].

## 0. One-liner
*Why:* the first sentence of the spec and of every report.
*Ready when:* one sentence, under 30 words, names the user and the outcome.

> <who> can <do what> so that <outcome>.

## 1. Vision and success
*Why:* Tier 1 resolves every ambiguity toward this.
*Ready when:* a reader could reject a feature request using only this section.

- **Problem today:** …
- **What changes when this ships:** …
- **Definition of done for the whole project (observable, 3–5 bullets):**
  1. …
- **Explicitly out of the first release but expected later:** …

## 2. Users and jobs
*Why:* acceptance tests are written from the user's point of view.
*Ready when:* every MVP capability in §3 maps to a persona and a job here.

| Persona | Context | Job to be done | Success looks like |
|---|---|---|---|
| … | … | … | … |

## 3. MVP scope
*Why:* this becomes the feature list Tier 1 slices into layers; nothing outside it gets built.
*Ready when:* each line is demonstrable in one sentence and has an acceptance signal.

| # | Capability ("a PERSONA can …") | Acceptance signal (what a test observes) | Priority |
|---|---|---|---|
| C1 | … | … | must |
| C2 | … | … | must |
| C3 | … | … | should |

## 4. Non-goals
*Why:* copied verbatim into the spec as hard boundaries; the reviewer rejects work that crosses them.
*Ready when:* at least five items, each something a reasonable engineer might otherwise add.

1. No …
2. No …

## 5. Domain model
*Why:* Tier 2 freezes contracts from these names; consistent naming prevents duplicate concepts.
*Ready when:* every noun in §3 appears here with its fields, identity and lifecycle.

| Entity | Identity | Key fields (name: type) | Lifecycle / states | Invariants |
|---|---|---|---|---|
| … | … | … | … | … |

Relationships (one line each): `A 1..n B`, `B references C by id`, …

Glossary (terms with a precise meaning in this project): …

## 6. Interfaces
*Why:* each interface becomes a frozen contract file; its shape decides the acceptance tests.
*Ready when:* every entry has a style, a listing of operations, and an error model.

### 6.1 User-facing surface
- **Kind:** CLI | HTTP API | web UI | library | job/worker | other
- **Operations / routes / commands** (name → input → output → errors):
  - …
- **Error model:** typed values at boundaries (`{ code: "NOT_FOUND", … }`); list the codes: …

### 6.2 Internal module boundaries (becomes the spec's `yaml boundaries` block)
| Layer name | Path (TS) / module (Py) | May import | Responsibility |
|---|---|---|---|
| domain | src/domain | — | entities, invariants, pure logic |
| application | src/app | domain | use cases, orchestration |
| adapters | src/adapters | domain, application | persistence, external services |
| entrypoints | src/entry | all | CLI / HTTP / UI wiring |

### 6.3 External integrations
| Service | Purpose | Protocol / SDK | Fake for tests | Failure behavior |
|---|---|---|---|---|
| … | … | … | in-memory adapter in contract | … |

## 7. Data and persistence
*Why:* storage decisions are nearly impossible to change after layer 1.
*Ready when:* store, schema ownership, migrations and test strategy are all named.

- **Store(s):** …
- **Schema / migration tool and location:** …
- **Data that must survive restarts vs. may be rebuilt:** …
- **Retention, size expectations, PII present (yes/no, which fields):** …
- **Test strategy:** acceptance tests use an in-memory/fake adapter exposed by the contract; integration against the real store happens … (where / when).

## 8. Locked tech stack
*Why:* agents may not add frameworks or swap libraries; this table is the allowlist.
*Ready when:* every row has an exact version or range and the `deps.pre_approved` list above is final.

| Concern | Choice (version) | Notes |
|---|---|---|
| Language / runtime | … | strict mode on |
| Framework | … | |
| Persistence driver | … | |
| Validation / schemas | … | |
| Test runner | … | acceptance tests under `tests/acceptance/` |
| Lint / format | … | zero warnings |
| Build / packaging | … | |
| Logging | … | |

Forbidden (common temptations that are out): …

## 9. Quality bar and design standards
*Why:* these become reviewer criteria and gate rules.
*Ready when:* each bullet is checkable by reading a diff.

- Files under 300 lines; one responsibility per file.
- Contracts first: every §6 interface has a frozen `.d.ts` / Protocol / schema before implementation.
- Errors are typed values at boundaries; exceptions only for programmer errors.
- No `any`, no suppression comments, no stubs, no placeholder comments.
- Logging: structured, one logger module, no `console.log` outside entrypoints.
- Configuration: all runtime config read in one module from env vars listed in §11; no literals elsewhere.
- Concurrency / idempotency rules: …
- Accessibility / i18n / localization stance: …
- Anything else a reviewer must enforce: …

## 10. `just check`
*Why:* the single deterministic gate; every task must pass it in its worktree and on `main`.
*Ready when:* the recipe below exists as the repo's `justfile` and passes on the empty scaffold.

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

Python variant: `uv run mypy src`, `uv run ruff check .`, `uv run pytest -q`.

## 11. Runtime, configuration and security
*Why:* without this, agents invent env vars, log secrets, or skip auth.
*Ready when:* every env var is listed and the auth model is one paragraph.

- **Deployment target / how it runs:** (local CLI, container, serverless, desktop …) …
- **Environment variables** (name, purpose, required?, example value — never a real secret):
  | Var | Purpose | Required | Example |
  |---|---|---|---|
  | … | … | yes | … |
- **Secrets handling:** …
- **Authentication / authorization model:** …
- **Threat notes** (inputs to validate, rate limits, abuse cases): …
- **Observability:** logs / metrics / health endpoint expectations: …
- **Performance targets** (only ones a test can assert): …

## 12. Layer plan hints and risk map
*Why:* Tier 1 orders layers from this; Tier 2 marks tasks `risk: high` from this.
*Ready when:* layer 0 is described and every high-risk area is named.

- **Expected layers (3–7), in order, one line each:**
  0. Foundations: scaffold, contracts, in-memory adapters, `just check` green.
  1. …
- **Hard ordering constraints:** …
- **High-risk areas** (auth, payments, migrations, concurrency, public API): …
- **Known unknowns and the default decision for each** (the fleet will take the default): …

## 13. Operator notes
*Why:* the only channel from you to the overnight run.
*Ready when:* you would be comfortable not being reachable until morning.

- Things every `docs/reports/LAYER-N.md` narrative should mention: …
- What to do first the morning after (what you will check): …
- Anything the fleet must never touch in this repo (paths): …
