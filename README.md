---
title: README
type: guide
tags: [setup, fleet]
---

# Agentic workflow — setup guide

A drop-in template that builds a software project overnight from one file, `IDEA.md`, using your
ChatGPT Plus (Codex CLI) and Claude Pro (Claude Code) subscriptions. No API keys, no servers. This page
is the human walkthrough: what to install once, how to start each new project, what to do each morning.
Details live in `docs/BLUEPRINT.md` (tooling), `AGENTS.md` (the rules the agents obey) and
`TIMELINE-BUDDY.md` (the stage-by-stage timeline).

## How it works, in one paragraph

You describe the project in `IDEA.md`. `orchestrate.sh` then runs a loop: Codex (Tier 1) writes the
spec and layer plan; for each layer, Claude Opus (Tier 2) freezes interface contracts and acceptance
tests and slices tasks; Codex coders (Tier 3) implement one task each in isolated git worktrees;
deterministic bash gates check every change; a read-only Codex reviewer approves; bash merges the PR;
Opus signs the layer off. Every model call is a short standalone pass. Everything is on disk, so you
can stop and resume at any time, and Obsidian can open the repo as a vault.

## Part A — one-time machine setup (macOS)

Do this once per Mac.

```bash
# 1. Homebrew and tools
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash coreutils jq yq git gh uv node pnpm just ast-grep gitleaks ripgrep
echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc && exec zsh
bash --version        # must be 5.x (the stock 3.2 cannot run the scripts)
yq --version          # must say mikefarah

# 2. Node and Python tooling
pnpm setup && source ~/.zshrc
pnpm add -g repomix dependency-cruiser knip ccusage @openai/codex @anthropic-ai/claude-code
uv tool install check-jsonschema
uv tool install graphifyy
uv tool install import-linter && uv tool install vulture    # Python projects

# 3. Logins (browser opens for each; never use API keys)
codex login            # Sign in with ChatGPT
claude                 # pick the Claude subscription login, then /exit
gh auth login          # GitHub.com, HTTPS, yes to git credentials
unset OPENAI_API_KEY ANTHROPIC_API_KEY

# 4. Phone
# Install the ntfy app (iOS/Android). You will subscribe to one topic per project later.
```

## Part B — starting a new project

Repeat this for every new idea. About an hour of your time, then the fleet runs alone.

### B1. Create the repo from this template

```bash
# on GitHub: create an empty repo, e.g. you/my-new-thing (no README), then:
git clone https://github.com/CharlesBai-blc/agentic-workflow.git my-new-thing
cd my-new-thing
git remote set-url origin https://github.com/you/my-new-thing.git
rm -rf .git && git init -b main && git add -A && git commit -m "Fleet template"
git push -u origin main
```

Alternatively click "Use this template" on GitHub if the workflow repo is marked as a template.

### B2. Install the repo-level tools

```bash
graphify claude install --project
graphify codex install --project        # never run `graphify hook install`
graphify update .
npx skills add tt-a1i/archify --skill archify
mkdir -p ../my-new-thing.wt ../my-new-thing.bundles
scripts/doctor.sh --dry-run             # must end with PREFLIGHT: PASS; exercises the loop with no tokens
```

### B3. Ideate: fill IDEA.md with an agent

1. Open Claude (Opus) or ChatGPT (thinking on) in a chat window.
2. Paste the contents of `IDEATE.md`, then the contents of `IDEA.md`.
3. Answer its questions for 30–60 minutes. It will push back on scope; let it.
4. Save its final output over `IDEA.md`.
5. Pick a notification topic and subscribe to it on your phone:

```bash
TOPIC="my-new-thing-fleet-$(openssl rand -hex 4)"
yq --front-matter=process -i ".ntfy.topic = \"$TOPIC\"" IDEA.md && echo "$TOPIC"
curl -d "fleet test" "https://ntfy.sh/$TOPIC"      # phone should buzz
scripts/idea-check.sh                                # must print IDEA CHECK: PASS
```

If it fails, paste the output back to the ideation agent, or fix the lines it names.

### B4. Scaffold so `just check` is green

Create `justfile` from IDEA.md §10 and the smallest project where the gate passes. The exact commands
depend on the stack; the pattern is:

```bash
awk '/^```just/{p=1;next} p&&/^```$/{exit} p' IDEA.md > justfile
# Python:  uv init --lib --python 3.12 . ; uv add --dev mypy ruff pytest import-linter ; config in pyproject.toml
# TS:      pnpm init ; pnpm add -D typescript vitest eslint ; tsconfig.json (strict) ; eslint.config.js
# create the layer folders from IDEA.md §6.2 (domain, app, adapters, entry) and one trivial passing test
just check                              # until it exits 0
git add -A && git commit -m "Project intake and scaffold" && git push origin main
```

### B5. Optional: the Cursor buddy

In Cursor: "Read TIMELINE-BUDDY.md and IDEA.md. Produce CURSOR.md as the header instructs and save it
also as .cursor/rules/buddy.mdc with alwaysApply: true." Commit it. From then on, ask Cursor "status",
"why did TASK-001-003 fail", "what merged last night". It only reads; it never builds.

### B6. Preflight and first run

```bash
scripts/doctor.sh                       # every line ok; warnings are fine
git status                              # must be clean
caffeinate -s ./orchestrate.sh --max-layers 1      # plugged into AC power
```

Watch the first ten minutes. If Tier 1 dies at once, `tail -30 .agents/logs/tier1.log`. Otherwise go
to bed. Do not edit, save or commit anything in the repo while it runs; the tripwires compare the
working tree before and after every pass.

## Part C — every morning

1. Phone: scan the ntfy pushes (sliced, signed off, surgery, quarantined, pause, halt).
2. Read `.agents/STATE.md` (state and resume prompt), `docs/PROGRESS.md`, `docs/reports/LAYER-N.md`.
3. Open `docs/architecture/layer-N-actual.html` in a browser; compare with `00-target-architecture.html`.
4. Spot-check two merged PRs on GitHub and run `just check` yourself.
5. Decide:
   - **Happy:** `caffeinate -s ./orchestrate.sh` (no flag) resumes and runs the remaining layers.
   - **Halted:** read `docs/reports/INCIDENT-*.md` and the `.agents/tasks/TASK-*.fail.md`. Fix the contract or task by hand, or change scope in `IDEA.md`, commit, then re-run. Preserved worktrees are in `../my-new-thing.wt/`.
   - **Paused for quota:** nothing; it resumes itself at the reset time.
   - **Wrong plan after Tier 1:** edit `IDEA.md`, delete `.agents/architecture/SYSTEM_SPEC.md` and `.agents/layers.yaml`, reset `.agents/ledger.json` to the template's seed, re-run.

## Part D — after the last layer

`run_state: COMPLETE`. Check IDEA.md §1 definition of done against the product, tag a release, and
start the next increment by writing a new `IDEA.md` (layers keep numbering upward).

## Where things are

| Path | What |
|---|---|
| `IDEA.md`, `IDEATE.md` | the intake and the interview prompt |
| `AGENTS.md`, `CLAUDE.md` | rules for the model tiers (not for you) |
| `orchestrate.sh`, `scripts/` | the loop and its libraries; `scripts/doctor.sh` is preflight |
| `.agents/` | ledger, STATE.md, tasks, reviews, receipts, logs, prompts, skills, schemas |
| `docs/` | PROGRESS.md dashboard, LAYER-N reports, Archify HTML, BLUEPRINT.md |
| `../<repo>.wt/`, `../<repo>.bundles/` | task worktrees and pre-run git bundles |
| `TIMELINE-BUDDY.md` | template for the Cursor buddy |

## Safety notes

The fleet runs with full permissions under your own user and pushes to your GitHub repo. Safeguards are
deny rules, hooks and bash tripwires, plus a `git bundle` snapshot in `../<repo>.bundles/` before each
run. Run it only in a repo you are prepared to restore from that bundle.
