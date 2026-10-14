---
project: toyfleet
type: idea
stack:
  language: none
  package_manager: none
repo:
  layout: flat
  symlink_root_deps: false
quota:
  soft_ceiling_pct: 80
  max_sleep_hours: 6
  max_parallel_workers: 1
timeouts:
  tier1_min: 5
  phase_a_min: 5
  phase_b_min: 5
  surgery_min: 5
  coder_min: 5
  reviewer_min: 5
  closeout_min: 5
  gate_min: 2
pr:
  base: main
  wait_for_checks: false
ntfy:
  topic: ""
  server: https://ntfy.sh
quality:
  mutation_sampling: false
max_turns:
  phase_a: 10
  phase_b: 10
  surgery: 10
tags: [idea, dryrun]
---

# Toy fleet project (dry run)

## Vision
A bash script `src/greet.sh <name>` that prints `hello <name>`. Exists only to exercise `orchestrate.sh` with every model pass stubbed.

## MVP / non-goals
MVP: the script and one acceptance test. Non-goals: everything else.

## `just check`
```just
check:
    bash tests/run.sh
```
