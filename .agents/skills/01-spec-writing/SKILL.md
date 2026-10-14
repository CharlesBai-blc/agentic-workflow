---
name: 01-spec-writing
description: Tier 1 (gpt-6.1-sol). Turn IDEA.md into .agents/architecture/SYSTEM_SPEC.md, a sequential layer plan in .agents/layers.yaml, and the initial Obsidian dashboard. Use once per project, or on resume when STATE.md says the plan must be re-validated.
tier: 1
model: gpt-6.1-sol
tags: [skill, tier-1, spec]
---

# 01 — Spec writing (Tier 1)

## When this runs
Once, at the start of a project, as a standalone `codex exec` pass launched by `orchestrate.sh`. Inputs: `IDEA.md` (or `.agents/STATE.md` on resume) and `graphify-out/GRAPH_REPORT.md` if the repo already has code. Output: files on disk. Then exit. You never commit, push, create tasks, or write `.agents/ledger.json`.

## Outputs (exact paths)
1. `.agents/architecture/SYSTEM_SPEC.md`
2. `.agents/layers.yaml`
3. `docs/architecture/00-target-architecture.html` (via [[07-archify-diagramming]])
4. `docs/PROGRESS.md` (initial dashboard; `orchestrate.sh` regenerates it later)

## Procedure
1. **Read IDEA.md fully.** Extract: vision, MVP, explicit non-goals, locked stack, design standards, repo layout, `just check` recipe. Treat the stack and non-goals as immovable.
2. **If code exists**, read `graphify-out/GRAPH_REPORT.md` for the current module communities before designing. Never grep the source tree for structure; the graph report is the map.
3. **Write SYSTEM_SPEC.md** with this skeleton:
   ```markdown
   ---
   title: SYSTEM_SPEC
   type: spec
   project: <name>
   status: active
   layers: <N>
   tags: [spec, architecture]
   ---
   # <Project> — System Specification
   ## 1. Vision and scope          (MVP in, non-goals out; link [[IDEA]])
   ## 2. Design requirements       (numbered DR-1..DR-n; each testable in one sentence)
   ## 3. Architecture              (components, responsibilities, data flow; link [[00-target-architecture]])
   ## 4. Module layering           (the ```yaml boundaries``` block, see below)
   ## 5. Contracts to freeze       (one bullet per interface the layers will freeze; file paths)
   ## 6. Layer plan                (table: layer, title, goal, depends on, exit criteria; link [[LAYER-N]])
   ## 7. Quality bar               (300-line rule, zero stubs, `just check`, boundary rules)
   ## 8. Risks and open questions
   ```
4. **Boundaries block.** When the stack has internal layers, include exactly one fenced block so the gate can compile dependency-cruiser / import-linter rules:
   ````markdown
   ```yaml boundaries
   layers:
     - name: domain
       path: src/domain          # TS: directory prefix
       module: app.domain        # Python: dotted module
       may_import: []
     - name: application
       path: src/app
       module: app.application
       may_import: [domain]
     - name: adapters
       path: src/adapters
       module: app.adapters
       may_import: [domain, application]
   ```
   ````
   Every layer lists only the layers it may import. Omit the block for a single-module project.
5. **Layer plan → `.agents/layers.yaml`.** Layers are sequential dependency slices, Layer 0 first (foundations: contracts, schema, scaffolding), each buildable and testable on top of the previous one. 3–7 layers is typical. Format:
   ```yaml
   layers:
     - layer: 0
       title: Foundations and shared contracts
     - layer: 1
       title: Core domain
   ```
   Titles are short; the full description lives in SYSTEM_SPEC §6.
6. **Diagram.** Invoke [[07-archify-diagramming]] to produce `docs/architecture/00-target-architecture.html` with the target architecture and the core data flow. SRC evidence points at the spec sections and planned paths.
7. **Dashboard seed.** Write `docs/PROGRESS.md` with frontmatter `title: PROGRESS`, `type: dashboard`, `project`, `run_state: RUNNING`, `current_layer: 0`, a one-paragraph summary, and links `[[SYSTEM_SPEC]]`, `[[STATE]]`, `[00-target-architecture](architecture/00-target-architecture.html)`.

## Obsidian rules
Every file you write under `.agents/` or `docs/` has YAML frontmatter with `title`, `type`, `tags`, and uses `[[Wikilinks]]` for cross-references to other vault notes (spec, layers, tasks). Relative markdown links are for HTML files only.

## Size discipline
SYSTEM_SPEC.md under 400 lines. Design requirements are sentences, not essays. If IDEA.md is ambiguous, pick the simplest interpretation that satisfies the MVP and record it in §8; do not ask questions, there is no human in the loop.

## Resume mode
If `.agents/STATE.md` exists, follow its resume prompt: validate the spec and layers for layers at or after the current one, change only `SYSTEM_SPEC.md` and `.agents/layers.yaml` if needed, explain in `.agents/architecture/RESUME-NOTES.md`, otherwise write `OK` to `.agents/resume.ok`. Never re-plan SIGNED_OFF or CLOSED layers.
