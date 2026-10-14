#!/usr/bin/env bash
# PreToolUse guard for Glob / Grep (Claude Code).
#
# Policy (AGENTS.md §Graphify-first): Opus must map code structure with
# `graphify query` / `graphify path` (zero tokens, local AST graph). Glob/Grep
# are permitted ONLY for files that the AST graph cannot contain — contracts,
# schemas, config, and the markdown under .agents/ and docs/ (all excluded by
# .graphifyignore). Anything else is blocked with exit 2, and the stderr text
# below is fed back to the model as the tool error.
#
# Fallback: if no graph has been built yet (graphify-out/graph.json missing)
# there is nothing to query, so the search is allowed.
set -euo pipefail

input="$(cat)"
root="${CLAUDE_PROJECT_DIR:-$PWD}"

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
pattern="$(printf '%s' "$input" | jq -r '.tool_input.pattern // ""')"
path="$(printf '%s' "$input" | jq -r '.tool_input.path // ""')"
glob="$(printf '%s' "$input" | jq -r '.tool_input.glob // ""')"

[[ -f "$root/graphify-out/graph.json" ]] || exit 0

# Paths/globs the AST graph can never answer for. Keep in sync with AGENTS.md.
ALLOW_RE='(\.d\.ts$|(^|/)contracts?(/|$)|(^|/)schemas?(/|$)|\.schema\.json$|openapi|swagger|\.(ya?ml|toml|ini|cfg|proto|graphql|gql|avsc|prisma)$|(^|/)(package\.json|tsconfig[^/]*\.json|pyproject\.toml|justfile|Justfile|\.dependency-cruiser\.(c?js|json)|\.importlinter|setup\.cfg|\.eslintrc[^/]*|eslint\.config\.[cm]?js|vitest\.config\.[cm]?[jt]s|jest\.config\.[cm]?[jt]s|\.graphifyignore|\.gitignore|\.env\.example)$|(^|/)(\.agents|docs)(/|$)|(^|/)IDEA\.md$|(^|/)AGENTS\.md$|(^|/)CLAUDE\.md$)'

rel() {  # make a path relative to the project root, strip leading ./
  local p="$1"
  p="${p#"$root"/}"; p="${p#"$root"}"; p="${p#./}"
  printf '%s' "$p"
}

targets=()
case "$tool" in
  Glob)
    # The glob pattern itself is the file target; join it with the base path.
    base="$(rel "$path")"
    [[ -n "$base" ]] && targets+=("${base%/}/${pattern}") || targets+=("$pattern")
    ;;
  Grep)
    [[ -n "$path" ]] && targets+=("$(rel "$path")")
    [[ -n "$glob" ]] && targets+=("$glob")
    ;;
  *) exit 0 ;;
esac

# A Grep with no path and no glob is a whole-repo search: always blocked.
if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "BLOCKED: whole-repository $tool is not allowed. Run \`graphify query \"<question>\"\` or \`graphify path <A> <B>\` via Bash (see graphify-out/GRAPH_REPORT.md). Grep/Glob may only target contracts, schemas, config, .agents/ or docs/ — pass an explicit path or glob for those." >&2
  exit 2
fi

for t in "${targets[@]}"; do
  if printf '%s' "$t" | grep -Eq "$ALLOW_RE"; then
    exit 0
  fi
done

echo "BLOCKED: $tool target '${targets[*]}' is source code that is already in the AST graph. Use \`graphify query \"<question>\"\` / \`graphify path <A> <B>\` via Bash to find dependencies and compute READONLY_FILES. Glob/Grep is permitted only for contracts (*.d.ts, contracts/, schemas/, *.schema.json, OpenAPI), config (*.yaml, *.toml, package.json, pyproject.toml, justfile), and markdown under .agents/ or docs/." >&2
exit 2
