#!/usr/bin/env bash
# scripts/doctor.sh — preflight for the fleet. Must print "PREFLIGHT: PASS" before any run.
#   scripts/doctor.sh            full preflight against this repository
#   scripts/doctor.sh --dry-run  build a toy repo from scripts/dryrun/, stub every model pass, gh and
#                                git push (FLEET_DRY_RUN=1), run orchestrate.sh end to end, verify results
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

FAILS=0; WARNS=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
wrn() { printf '  warn  %s\n' "$*"; WARNS=$((WARNS+1)); }
need() { if have "$1"; then ok "$1 $(${2:-true} 2>/dev/null | head -n 1)"; else bad "$1 missing${3:+ — $3}"; fi; }
want() { if have "$1"; then ok "$1"; else wrn "$1 missing${2:+ — $2}"; fi; }

check_tools() {
  echo "== tools"
  [[ "${BASH_VERSINFO[0]}" -ge 4 ]] && ok "bash $BASH_VERSION" || bad "bash $BASH_VERSION is too old; brew install bash (Homebrew's bash must precede /bin/bash on PATH)"
  need git "git --version"; need jq "jq --version"; need yq "yq --version" "brew install yq"
  yq --version 2>/dev/null | grep -q 'mikefarah' && ok "yq is mikefarah/yq v4" || bad "yq must be mikefarah/yq v4 (brew install yq); the Python yq wrapper is not supported"
  need gh "gh --version"; need codex "codex --version" "npm i -g @openai/codex"; need claude "claude --version" "npm i -g @anthropic-ai/claude-code"
  need graphify "graphify --version" "uv tool install graphifyy"; need just "just --version"; need ast-grep "ast-grep --version"
  need gitleaks "gitleaks version"; need repomix "repomix --version"; need check-jsonschema "check-jsonschema --version" "uv tool install check-jsonschema"
  need curl "curl --version"; need shasum
  if [[ "$(uname)" == Darwin ]]; then need gtimeout "gtimeout --version" "brew install coreutils"; need gdate; need caffeinate; else want timeout; fi
  case "$(stack)" in
    ts) need pnpm "pnpm --version"; need node "node --version"; need depcruise "depcruise --version" "pnpm add -g dependency-cruiser"; need knip "knip --version" ;;
    python) need uv "uv --version"; need lint-imports "" "uv tool install import-linter"; need vulture "vulture --version" ;;
  esac
  want ccusage "secondary quota proxy"; want ntfy "CLI optional; curl is used for pushes"
}
check_auth() {
  echo "== subscription auth (no API keys)"
  for k in OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do [[ -n "${!k:-}" ]] && wrn "$k is set in this shell; runs unset it, but remove it from your shell rc"; done
  grep -lsE 'OPENAI_API_KEY|ANTHROPIC_API_KEY' ~/.zshrc ~/.zprofile ~/.bashrc ~/.bash_profile 2>/dev/null | while read -r f; do wrn "API key referenced in $f"; done
  if have codex; then
    if codex login status 2>&1 | grep -qiE 'logged in|chatgpt'; then ok "codex: logged in with ChatGPT"; else bad "codex not logged in — run: codex login (Sign in with ChatGPT)"; fi
  fi
  if have claude; then
    if claude auth status >/dev/null 2>&1; then ok "claude: authenticated"
    elif [[ "$(uname)" == Darwin ]] && security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then ok "claude: keychain credentials present"
    elif [[ -s "$HOME/.claude/.credentials.json" ]]; then ok "claude: credentials file present"
    else bad "claude not logged in — run: claude (choose the Claude subscription login)"; fi
  fi
  if have gh; then if gh auth status >/dev/null 2>&1; then ok "gh: authenticated"; else bad "gh not authenticated — run: gh auth login"; fi; fi
}
check_remote() {
  echo "== remote"
  local url; url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"
  if [[ "$url" == *github.com* ]]; then ok "origin -> $url"; else bad "origin is not a GitHub remote (got '${url:-none}')"; fi
  if have gh && gh auth status >/dev/null 2>&1; then
    gh repo view --json nameWithOwner -q .nameWithOwner >/dev/null 2>&1 && ok "gh repo view ok" || bad "gh cannot view the origin repository"
  fi
  git -C "$ROOT" ls-remote --exit-code origin "refs/heads/$(base_branch)" >/dev/null 2>&1 && ok "remote $(base_branch) reachable" || bad "cannot reach origin/$(base_branch)"
}
check_files() {
  echo "== repository files"
  [[ -f "$IDEA_FILE" ]] && ok "IDEA.md" || bad "IDEA.md missing"
  if [[ -f "$IDEA_FILE" ]]; then "$HERE/idea-check.sh" "$IDEA_FILE" >"$LOG_DIR/idea-check.log" 2>&1 && ok "idea-check.sh passes (ready: true)" || bad "idea-check.sh fails — run scripts/idea-check.sh for the list"; fi
  for f in AGENTS.md CLAUDE.md orchestrate.sh .graphifyignore .gitignore .claude/settings.json .claude/surgery-mcp.json; do [[ -e "$ROOT/$f" ]] && ok "$f" || bad "$f missing"; done
  jq -e . "$ROOT/.claude/settings.json" >/dev/null 2>&1 && ok "settings.json valid JSON" || bad "settings.json invalid"
  for h in search-guard.sh surgery-integrity.sh; do [[ -x "$ROOT/.claude/hooks/$h" ]] && ok "hook $h executable" || bad "hook $h missing or not executable"; done
  [[ "$(readlink "$ROOT/.claude/skills")" == "../.agents/skills" ]] && ok ".claude/skills -> ../.agents/skills" || bad ".claude/skills symlink missing"
  for s in 01-spec-writing 02-task-slicing 04-code-execution 05-code-review 07-archify-diagramming 08-progress-narrative 09-acceptance-tests 10-failure-triage; do
    [[ -f "$SKILL_DIR/$s/SKILL.md" ]] && ok "skill $s" || bad "skill $s missing"; done
  [[ -f "$SKILL_DIR/archify/SKILL.md" ]] && ok "archify skill installed" || wrn "archify skill missing — npx skills add tt-a1i/archify --skill archify"
  for s in receipt review layer-verdict ledger; do check-jsonschema --check-metaschema "$SCHEMA_DIR/$s.json" >/dev/null 2>&1 && ok "schema $s" || bad "schema $s invalid"; done
  [[ -f "$LEDGER" ]] && check-jsonschema --schemafile "$SCHEMA_DIR/ledger.json" "$LEDGER" >/dev/null 2>&1 && ok "ledger.json valid" || bad "ledger.json missing or invalid"
  (cd "$ROOT" && just --list 2>/dev/null | grep -qw check) && ok "just check recipe" || bad "justfile has no 'check' recipe"
  for d in "$WT_ROOT" "$BUNDLE_ROOT"; do mkdir -p "$d" 2>/dev/null && ok "dir $d" || bad "cannot create $d"; done
  [[ -f "$ROOT/graphify-out/graph.json" ]] && ok "graphify-out present" || wrn "graphify-out missing — run: graphify update ."
  if [[ "$(uname)" == Darwin ]]; then pmset -g batt 2>/dev/null | grep -q "AC Power" && ok "on AC power" || wrn "not on AC power (caffeinate -s needs AC)"; fi
}

dry_run() {
  echo "== dry run (FLEET_DRY_RUN=1; models, gh and git push stubbed)"
  local tmp repo rc=0; tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-dry.XXXXXX")"; repo="$tmp/toyfleet"; mkdir -p "$repo"
  for p in orchestrate.sh scripts .agents/schemas .agents/skills .agents/rules .claude .graphifyignore .gitignore AGENTS.md CLAUDE.md; do
    [[ -e "$ROOT/$p" ]] && { mkdir -p "$repo/$(dirname "$p")"; cp -R "$ROOT/$p" "$repo/$p"; }; done
  cp "$HERE/dryrun/IDEA.toy.md" "$repo/IDEA.md"; cp "$HERE/dryrun/justfile" "$repo/justfile"; mkdir -p "$repo/tests"; cp "$HERE/dryrun/tests/run.sh" "$repo/tests/run.sh"
  mkdir -p "$repo/.agents/receipts" "$repo/.agents/logs" "$repo/.agents/tasks" "$repo/.agents/reviews" "$repo/.agents/architecture" "$repo/docs/reports" "$repo/docs/architecture"
  cp "$ROOT/.agents/ledger.json" "$repo/.agents/ledger.json" 2>/dev/null || jq -n '{version:1,project:"unset",created_at:"1970-01-01T00:00:00Z",updated_at:"1970-01-01T00:00:00Z",current_layer:0,run_state:"IDLE",halt_reason:null,layers:[],tasks:{},quota:{codex:{five_hour_pct:null,weekly_pct:null,resets_at:null,checked_at:null,source:"none",state:"UNKNOWN"},claude:{five_hour_pct:null,weekly_pct:null,resets_at:null,checked_at:null,source:"none",state:"UNKNOWN"}},incidents:[]}' > "$repo/.agents/ledger.json"
  ( cd "$repo" && git init -q -b main && git -c user.name=doctor -c user.email=doctor@localhost add -A && git -c user.name=doctor -c user.email=doctor@localhost commit -qm "toy fleet" ) || { bad "toy repo init failed"; return 1; }
  ( cd "$repo" && FLEET_DRY_RUN=1 FLEET_ROOT="$repo" bash ./orchestrate.sh --max-layers 1 ) >"$tmp/orchestrate.out" 2>&1 || rc=$?
  tail -n 15 "$tmp/orchestrate.out" | sed 's/^/    | /'
  [[ $rc -eq 0 ]] && ok "orchestrate.sh exited 0" || bad "orchestrate.sh exited $rc (full log: $tmp/orchestrate.out)"
  [[ "$(jq -r '.tasks["TASK-000-001"].status // ""' "$repo/.agents/ledger.json")" == MERGED ]] && ok "TASK-000-001 MERGED" || bad "TASK-000-001 not MERGED"
  [[ "$(jq -r '.layers[0].status // ""' "$repo/.agents/ledger.json")" == CLOSED ]] && ok "layer 0 CLOSED" || bad "layer 0 not CLOSED"
  [[ -f "$repo/docs/reports/LAYER-0.md" && -f "$repo/docs/PROGRESS.md" && -f "$repo/.agents/STATE.md" ]] && ok "reports + STATE.md written" || bad "reports missing"
  [[ -f "$repo/docs/architecture/layer-0-actual.html" ]] && ok "closeout diagram written" || bad "closeout diagram missing"
  git -C "$repo" log --merges --oneline | grep -q "agent/TASK-000-001" && ok "merge commit on main" || bad "no merge commit"
  (cd "$repo" && just check >/dev/null 2>&1) && ok "just check passes on toy main" || bad "just check fails on toy main"
  [[ -z "$(ls -A "$tmp/toyfleet.wt" 2>/dev/null)" ]] && ok "worktree removed after merge" || wrn "worktree left behind: $tmp/toyfleet.wt"
  echo "  toy repo kept at $repo"
}

main() {
  if [[ "${1:-}" == "--dry-run" ]]; then
    echo "== tools (dry run needs: bash>=4 git jq yq just check-jsonschema)"; [[ "${BASH_VERSINFO[0]}" -ge 4 ]] && ok "bash $BASH_VERSION" || bad "bash $BASH_VERSION too old: brew install bash"; for t in git jq yq just check-jsonschema; do need "$t"; done
    [[ $FAILS -eq 0 ]] && dry_run
  else
    check_tools; check_auth; check_remote; check_files
  fi
  echo; if [[ $FAILS -eq 0 ]]; then echo "PREFLIGHT: PASS ($WARNS warning(s))"; exit 0; else echo "PREFLIGHT: FAIL ($FAILS failure(s), $WARNS warning(s))"; exit 1; fi
}
main "$@"
