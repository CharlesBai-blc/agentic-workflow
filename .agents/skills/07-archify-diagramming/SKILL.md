---
name: 07-archify-diagramming
description: Wrapper for the archify skill (tt-a1i/archify). Tier 1 produces docs/architecture/00-target-architecture.html; Tier 3 closeout produces docs/architecture/layer-N-actual.html. Self-contained interactive HTML with SRC evidence, validated, compared against the previous snapshot, repaired on validation failure.
tier: 3
model: gpt-6.1-sol
tags: [skill, tier-1, tier-3, diagrams]
---

# 07 — Archify diagramming (Tier 1 target, Tier 3 closeout)

## What archify is
`archify` (installed with `npx skills add tt-a1i/archify --skill archify`, skill file `.agents/skills/archify/SKILL.md`) compiles interactive, self-contained HTML diagrams: architecture, workflow, sequence and data-flow views, each node carrying `SRC` evidence (file paths or spec sections) and a validator that rejects nodes without evidence or edges without a source. It also compares two snapshots and reports added, removed and changed components. Read its SKILL.md once at the start of the pass and follow its invocation syntax exactly; this wrapper tells you what to produce and how to behave inside the fleet.

## Outputs
| Caller | File | Content |
|---|---|---|
| Tier 1 (01-spec-writing) | `docs/architecture/00-target-architecture.html` | Target architecture + core data flow from SYSTEM_SPEC; `SRC` points at spec sections and planned paths |
| Tier 3 closeout, layer N | `docs/architecture/layer-N-actual.html` | Architecture as actually implemented after layer N; `SRC` points at real files; snapshot comparison against `layer-(N-1)-actual.html` (or the target for layer 0) embedded |

Write only these files. Nothing else in `docs/` or `.agents/`.

## Procedure
1. **Collect evidence without reading the whole tree.**
   - Tier 1: SYSTEM_SPEC §3–§6 and the boundaries block.
   - Closeout: `git diff --stat layer-N-base...main` for the files that changed in this layer, `graphify-out/GRAPH_REPORT.md` (if present) for communities, and SYSTEM_SPEC §3 for intended components. Open a source file only to confirm a component boundary; never paste code into the diagram.
2. **Model the system** as components (services, modules, adapters, stores), their interfaces (the frozen contracts), and flows (request path, event path, data path). One diagram per view inside the single HTML: architecture, data flow, and one sequence diagram for the layer's primary use case. Keep each view under ~25 nodes; group by the boundaries layers.
3. **Attach SRC evidence** to every node and edge: `src/adapters/user-repo.ts`, `contracts/user-repo.d.ts`, or `SYSTEM_SPEC.md#3-architecture`. A node without evidence does not exist; drop it.
4. **Compile** with archify to a self-contained HTML file (inline CSS/JS, no CDN). Title: `<Project> — Layer N actual` or `<Project> — Target architecture`.
5. **Validate** with archify's validator. On failure, read only the validator's findings, fix the model (missing SRC, dangling edge, duplicate id), recompile, revalidate. At most 3 repair loops; if still failing, remove the offending nodes rather than the evidence rule, note the removal in the HTML's notes panel, and finish.
6. **Compare** (closeout only): run archify's snapshot comparison between the previous snapshot and the new one and keep the result in the HTML so the human sees drift at a glance.
7. **Exit.** Do not commit, push, or edit reports; `orchestrate.sh` commits the file and `progress-report.sh` links it.

## Evidence over aesthetics
A sparse diagram where every node is backed by a real file beats a complete one with invented components. If the implemented architecture drifted from the target, show the drift; the Phase B audit and the human want to see it.

## Repair receipts
If archify emits a repair receipt (its own JSON describing what it fixed), keep it in the HTML notes panel verbatim; do not relay it in your final message. Your final message is one line: the path written and `validated: yes|partial`.
