#!/usr/bin/env bash
# scripts/lib/dryrun.sh — zero-token stand-ins for codex/claude passes when FLEET_DRY_RUN=1.
# Used by scripts/doctor.sh --dry-run against the toy IDEA.md so the whole bash loop can be
# exercised with gh and git push stubbed and no model invoked.
[[ -n "${__FLEET_DRYRUN_LOADED:-}" ]] && return 0
__FLEET_DRYRUN_LOADED=1
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_dr_html() { printf '<!doctype html><html><head><meta charset="utf-8"><title>%s</title></head><body><h1>%s</h1><p>SRC: src/greet.sh</p></body></html>\n' "$1" "$1" > "$2"; }

dryrun_codex() {  # dryrun_codex <kind> <id> <cwd> <outfile>
  local kind="$1" id="$2" cwd="$3" out="$4"
  log "[dry-run] codex $kind $id"
  case "$kind" in
    tier1)
      mkdir -p "$ROOT/.agents/architecture" "$ROOT/docs/architecture"
      cat > "$SPEC_FILE" <<'SPEC'
---
title: SYSTEM_SPEC
type: spec
status: active
tags: [spec, dryrun]
---
# Toy greeter

One layer. `src/greet.sh <name>` prints `hello <name>`. See [[IDEA]] and [[PROGRESS]].
SPEC
      printf 'layers:\n  - layer: 0\n    title: Greeter core\n' > "$LAYERS_FILE"
      _dr_html "Target architecture" "$ROOT/docs/architecture/00-target-architecture.html" ;;
    coder)
      mkdir -p "$cwd/src"; printf '#!/usr/bin/env bash\nprintf "hello %%s\\n" "${1:-world}"\n' > "$cwd/src/greet.sh"; chmod +x "$cwd/src/greet.sh"
      [[ -n "$out" ]] && jq -n --arg t "$id" '{task_id:$t, status:"DONE", attempt:1, files_changed:["src/greet.sh"],
        test_summary:{passed:1, failed:0, skipped:0, command:"just check", summary_line:"1 passed"}, defect_location:null, root_cause:null}' > "$out" ;;
    reviewer)
      [[ -n "$out" ]] && jq -n --arg t "$id" '{task_id:$t, verdict:"APPROVE", reasons:[], contract_adherence:"FULL", test_adherence:"HONEST"}' > "$out" ;;
    closeout)
      _dr_html "Layer $id actual" "$ROOT/docs/architecture/layer-$id-actual.html" ;;
    narrative)
      local rep="$DOCS_DIR/reports/LAYER-$id.md"
      [[ -f "$rep" ]] && sed -i.bak 's|<!-- narrative:start -->|<!-- narrative:start -->\nDry-run narrative: layer signed off; see [[LAYER-'"$id"'-signoff]].|' "$rep" && rm -f "$rep.bak" ;;
  esac
  return 0
}

dryrun_claude() {  # dryrun_claude <phase> <layer> <outfile>
  local phase="$1" layer="$2" out="$3"
  log "[dry-run] claude $phase layer $layer"
  case "$phase" in
    phase_a)
      mkdir -p "$ROOT/contracts" "$ROOT/tests"
      printf '# CONTRACT: src/greet.sh <name> prints "hello <name>" and exits 0.\n' > "$ROOT/contracts/greet.contract.md"
      cat > "$ROOT/tests/greet.test.sh" <<'T'
#!/usr/bin/env bash
set -e
out="$(bash src/greet.sh fleet)"
[[ "$out" == "hello fleet" ]] || { echo "expected 'hello fleet', got '$out'"; exit 1; }
echo "1 passed"
T
      printf 'contracts/greet.contract.md\ntests/greet.test.sh\n' > "$AGENTS_DIR/frozen.list"
      cat > "$TASKS_DIR/TASK-000-001.md" <<'TASK'
---
id: TASK-000-001
type: task
title: Implement greet.sh
layer: 0
wave: 0
status: PENDING
risk: low
kind: feature
owned_files: [src/greet.sh]
readonly_files: [contracts/greet.contract.md, tests/greet.test.sh]
approved_deps: []
acceptance_tests: [tests/greet.test.sh]
depends_on: []
tags: [task, layer-0]
---
# TASK-000-001 — Implement greet.sh

Implements [[greet.contract]] so [[greet.test]] passes. Part of [[SYSTEM_SPEC]].
TASK
      ;;
    phase_b)
      mkdir -p "$REVIEW_DIR"
      printf -- '---\ntitle: LAYER-%s-signoff\ntype: signoff\nlayer: %s\nverdict: SIGNED_OFF\n---\n# Layer %s sign-off\n\nDry run: all tasks merged. See [[LAYER-%s]].\n' "$layer" "$layer" "$layer" "$layer" > "$REVIEW_DIR/LAYER-$layer-signoff.md"
      [[ -n "$out" ]] && jq -n --argjson l "$layer" --arg f ".agents/reviews/LAYER-$layer-signoff.md" \
        '{layer:$l, verdict:"SIGNED_OFF", summary:"Dry run: implementation matches the toy spec.", spec_drift:[], rework_tasks:[], audit_file:$f}' > "$out" ;;
    surgery) : ;;
  esac
  return 0
}
