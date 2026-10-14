---
title: Fleet Tooling Blueprint
type: blueprint
tags: [fleet, setup, obsidian]
status: active
updated: 2026-10-14
---

# Fleet Tooling Blueprint

Drop-in bootstrap for the bash-driven multi-agent fleet. Every command here runs on the operator's own
macOS user account. Nothing in this document spends model tokens. See [[AGENTS]] for the rules the
fleet obeys and [[IDEA]] for the project intake.

## 0. Host prerequisites (macOS)

```bash
# Homebrew packages: coreutils gives gtimeout/gdate; jq + yq parse ledger/frontmatter.
brew install coreutils jq yq git gh uv node pnpm just ast-grep gitleaks ripgrep ntfy
# ntfy is only the CLI publisher; the operator subscribes on their phone to the topic in IDEA.md.

# Python-side deterministic tooling (installed as isolated uv tools, zero project pollution).
uv tool install check-jsonschema
uv tool install import-linter
uv tool install vulture
uv tool install mutmut          # optional: mutation sampling for Python repos

# Node-side deterministic tooling (global so worktrees reuse one install).
pnpm add -g repomix dependency-cruiser knip ccusage
pnpm add -g @stryker-mutator/core   # optional: mutation sampling for TS repos
```

## 1. Subscription CLIs (no API keys, ever)

```bash
# Codex CLI (ChatGPT Plus). Log in with the browser flow, NOT an API key.
npm install -g @openai/codex
codex login                     # choose "Sign in with ChatGPT"
codex login status

# Claude Code CLI (Claude Pro). Same rule: subscription login only.
npm install -g @anthropic-ai/claude-code
claude                          # first run opens the browser login; pick "Claude account with subscription"
claude auth status

# Make sure no API key can ever leak into a pass. orchestrate.sh also unsets both at runtime.
unset OPENAI_API_KEY ANTHROPIC_API_KEY
grep -nE 'OPENAI_API_KEY|ANTHROPIC_API_KEY' ~/.zshrc ~/.zprofile ~/.bashrc 2>/dev/null && echo "REMOVE THESE LINES"
```

## 2. GitHub CLI and remote

```bash
gh auth login                   # GitHub.com, HTTPS, authenticate Git with your GitHub credentials: yes
gh auth status
git remote -v                   # origin must be the GitHub repo; the fleet pushes to it.
gh repo view --json nameWithOwner,defaultBranchRef
git remote get-url origin | grep -q 'github.com' || echo "origin is not a GitHub remote"
```

Pushes stay enabled. `orchestrate.sh` is the only component that pushes or calls `gh`, through
`scripts/lib/pr.sh`. The fleet runs under the operator's own macOS user and GitHub login; there is no
dedicated user, devcontainer or VM.

## 3. Graphify (zero-token AST graph)

```bash
uv tool install graphifyy
graphify --version
graphify claude install --project     # registers the graphify skill for Claude Code in this repo
graphify codex install --project      # registers the graphify skill for Codex in this repo
# Do NOT run `graphify hook install`. Rebuilds happen only on main, driven by orchestrate.sh.
graphify update .                     # first build -> graphify-out/graph.json + GRAPH_REPORT.md
```

`.graphifyignore` (repo root) excludes every markdown, doc, agent-state, data and config file, so
Graphify only ever runs its local `tree-sitter` code mode. Verify after the first build:

```bash
graphify stats . | head -20
test -f graphify-out/graph.json && test -f graphify-out/GRAPH_REPORT.md && echo "graph ok"
```

## 4. Archify (interactive HTML architecture diagrams)

```bash
npx skills add tt-a1i/archify --skill archify
ls .agents/skills/archify/SKILL.md     # installed into the shared skills dir (see §6)
```

The `07-archify-diagramming` skill wraps Archify for `gpt-6.1-sol`. Diagram outputs live in
`docs/architecture/*.html` and are committed.

## 5. Codex MCP bridge (Surgery passes only)

No global registration is needed. `.claude/surgery-mcp.json` defines the `codex` server as
`codex mcp-server` over stdio, and Surgery passes load it with:

```bash
claude -p --dangerously-skip-permissions \
  --mcp-config .claude/surgery-mcp.json --strict-mcp-config \
  --disallowedTools "Task,Agent" ...
```

Every other Claude pass is launched without `--mcp-config`, so no MCP server is loaded. Verify the
bridge once by hand:

```bash
claude -p --mcp-config .claude/surgery-mcp.json --strict-mcp-config --max-turns 1 \
  "List your MCP tools by name only." | grep -q 'mcp__codex__codex' && echo "bridge ok"
```

## 6. Shared skills directory

Both CLIs discover the same skills through one symlink:

```bash
mkdir -p .agents/skills
ln -sfn ../.agents/skills .claude/skills
readlink .claude/skills            # -> ../.agents/skills
```

Codex reads `AGENTS.md`, which names each skill path explicitly, so it needs no symlink.

## 7. Sibling directories

```bash
repo="$(basename "$(git rev-parse --show-toplevel)")"
mkdir -p "../${repo}.wt" "../${repo}.bundles"
```

- `../<repo>.wt/task-ID` holds one worktree per task on branch `agent/task-ID`.
- `../<repo>.bundles/` receives a `git bundle create` snapshot before every run.

Both live outside the repo so root tooling globs never pick them up.

## 8. Folder tree

```text
<repo>/
├── IDEA.md                         # project intake (human-written)
├── AGENTS.md                       # universal fleet rules (Codex + Claude)
├── CLAUDE.md                       # @AGENTS.md + Claude-only rules
├── orchestrate.sh                  # the loop (bash)
├── justfile                        # `just check` from IDEA.md
├── .graphifyignore                 # AST-only lockdown
├── .gitignore
├── .claude/
│   ├── settings.json               # deny rules + hooks
│   ├── surgery-mcp.json            # codex MCP server, Surgery only
│   ├── hooks/
│   │   ├── search-guard.sh         # PreToolUse: block Glob/Grep on source code
│   │   └── surgery-integrity.sh    # PostToolUse on mcp__codex__codex
│   └── skills -> ../.agents/skills
├── .agents/
│   ├── STATE.md                    # machine state + resume prompt (checkpoint.sh)
│   ├── ledger.json                 # task DAG, statuses, quota, incidents
│   ├── frozen.sha256               # hashes of frozen contracts + acceptance tests
│   ├── architecture/SYSTEM_SPEC.md
│   ├── tasks/TASK-LLL-NNN.md       # one task file per task (+ .fail.md on strike 3)
│   ├── reviews/                    # TASK-*.json, LAYER-N-signoff.md, LAYER-N-verdict.json
│   ├── receipts/   (gitignored)    # TASK-*.json receipts
│   ├── logs/       (gitignored)    # full event streams per pass
│   ├── schemas/                    # receipt.json, review.json, layer-verdict.json, ledger.json
│   └── skills/
│       ├── 01-spec-writing/SKILL.md
│       ├── 02-task-slicing/SKILL.md
│       ├── 04-code-execution/SKILL.md
│       ├── 05-code-review/SKILL.md
│       ├── 07-archify-diagramming/SKILL.md
│       ├── 08-progress-narrative/SKILL.md
│       ├── 09-acceptance-tests/SKILL.md
│       ├── 10-failure-triage/SKILL.md
│       └── archify/                # installed by `npx skills add`
├── docs/
│   ├── BLUEPRINT.md                # this file
│   ├── PROGRESS.md                 # Obsidian dashboard (progress-report.sh)
│   ├── architecture/
│   │   ├── 00-target-architecture.html
│   │   └── layer-N-actual.html
│   └── reports/LAYER-N.md
├── scripts/
│   ├── doctor.sh                   # preflight (+ --dry-run)
│   └── lib/
│       ├── common.sh               # paths, logging, timeouts, ntfy, IDEA.md reader
│       ├── ledger.sh               # set_status + ledger helpers
│       ├── compile-prompt.sh
│       ├── checkpoint.sh
│       ├── progress-report.sh
│       ├── pr.sh
│       ├── gate.sh
│       ├── tripwire.sh
│       ├── quota.sh
│       ├── worktree.sh
│       └── passes.sh               # codex exec / claude -p wrappers
├── graphify-out/   (gitignored)    # graph.json, GRAPH_REPORT.md
│
../<repo>.wt/task-ID/               # sibling worktrees
../<repo>.bundles/<ts>.bundle       # pre-run snapshots
```

## 9. Obsidian vault

Open the repo root as a vault. Every markdown file under `.agents/` and `docs/` carries YAML
frontmatter with `type`, `status`, `layer`, `tags` and `[[Wikilinks]]`, so Graph View and Dataview
work with zero configuration. Install the Dataview community plugin; `docs/PROGRESS.md` ships with
its queries. Obsidian hides dot-folders by default: enable **Settings → Files and links → Show all
file extensions** and add `.agents` via **Files → Excluded files** inverse, or simply open
`.agents/` with the "Show hidden files" toggle of your file explorer plugin.

## 10. First run

```bash
scripts/doctor.sh                  # must print PREFLIGHT: PASS
scripts/doctor.sh --dry-run        # toy IDEA.md with gh and git push stubbed
caffeinate -s ./orchestrate.sh     # AC power required
```
