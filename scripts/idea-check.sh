#!/usr/bin/env bash
# scripts/idea-check.sh — zero-token validator for IDEA.md. Exit 0 and set `ready: true` when
# every check passes; otherwise list the failures and leave `ready: false`.
# Usage: scripts/idea-check.sh [path/to/IDEA.md]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
F="${1:-$IDEA_FILE}"; FAILS=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
fm()  { yq --front-matter=extract -r "$1 // \"\"" "$F" 2>/dev/null; }
[[ -f "$F" ]] || { echo "IDEA.md not found at $F"; exit 1; }

echo "== frontmatter"
yq --front-matter=extract '.' "$F" >/dev/null 2>&1 && ok "frontmatter parses" || bad "frontmatter does not parse as YAML"
for k in project stack.language stack.package_manager repo.layout repo.symlink_root_deps deps.pre_approved quota.soft_ceiling_pct quota.max_sleep_hours quota.max_parallel_workers \
         timeouts.tier1_min timeouts.phase_a_min timeouts.phase_b_min timeouts.surgery_min timeouts.coder_min timeouts.reviewer_min timeouts.closeout_min timeouts.gate_min \
         max_turns.phase_a max_turns.phase_b max_turns.surgery effort.coder pr.base pr.wait_for_checks ntfy.topic ntfy.server quality.mutation_sampling; do
  v="$(yq --front-matter=extract ".$k" "$F" 2>/dev/null)"
  [[ -n "$v" && "$v" != null ]] && ok "$k" || bad "missing key: $k"
done
p="$(fm .project)"; [[ "$p" =~ ^[a-z0-9][a-z0-9-]*$ && "$p" != my-project ]] && ok "project name '$p'" || bad "project must be kebab-case and not the placeholder 'my-project'"
case "$(fm .stack.language)" in ts|python|none) ok "stack.language" ;; *) bad "stack.language must be ts | python | none" ;; esac
case "$(fm .repo.layout)" in flat|workspace) ok "repo.layout" ;; *) bad "repo.layout must be flat | workspace" ;; esac
[[ "$(fm .ntfy.topic)" != "" ]] && ok "ntfy.topic set" || bad "ntfy.topic is empty (you will get no pause/halt pushes)"

echo "== body"
body="$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; next} n>=2{print}' "$F")"
lines="$(wc -l < "$F" | tr -d ' ')"; [[ "$lines" -le 600 ]] && ok "length $lines lines" || bad "file is $lines lines (> 600; it is injected into every Phase A prompt)"
for s in "## 0. One-liner" "## 1. Vision and success" "## 2. Users and jobs" "## 3. MVP scope" "## 4. Non-goals" "## 5. Domain model" "## 6. Interfaces" "### 6.1" "### 6.2" "### 6.3" \
         "## 7. Data and persistence" "## 8. Locked tech stack" "## 9. Quality bar" "## 10. \`just check\`" "## 11. Runtime, configuration and security" "## 12. Layer plan hints" "## 13. Operator notes"; do
  grep -qF "$s" <<<"$body" && ok "section: $s" || bad "missing section: $s"
done
ph="$(sed -E 's/`[^`]*`//g' <<<"$body" | grep -nE '…|<[a-z][^>]*>|\bTODO\b|\bTBD\b' | grep -vE '^[0-9]+:[[:space:]]*>' | head -n 5)"
[[ -z "$ph" ]] && ok "no placeholders" || bad "placeholders remain:"$'\n'"$(sed 's/^/          /' <<<"$ph")"
grep -qE '^\*Why:\*|^\*Ready when:\*' <<<"$body" && bad "template guidance lines (*Why:* / *Ready when:*) still present" || ok "guidance lines removed"
grep -qE '^\| C[0-9]+ \|' <<<"$body" && ok "MVP table has capabilities" || bad "§3 MVP table has no C1.. rows"
[[ "$(grep -cE '^[0-9]+\. No ' <<<"$body")" -ge 5 ]] && ok "non-goals ≥ 5" || bad "§4 needs at least five 'No …' items"
awk '/^```just/{p=1;next} p&&/^```/{exit} p{print}' <<<"$body" | grep -qE '^check:' && ok "just check recipe present" || bad "§10 has no \`\`\`just block with a check: recipe"
grep -qE '^\s*0\. ' <<<"$body" && ok "layer 0 described" || bad "§12 must describe layer 0"
grep -qE '^\| domain ' <<<"$body" && ok "module boundaries table" || bad "§6.2 boundary table has no 'domain' row"

echo
if [[ $FAILS -eq 0 ]]; then
  yq --front-matter=process -i '.ready = true' "$F"; echo "IDEA CHECK: PASS — ready: true written. Next: create the justfile from §10, scaffold, run scripts/doctor.sh"; exit 0
else
  yq --front-matter=process -i '.ready = false' "$F"; echo "IDEA CHECK: FAIL ($FAILS) — fix the items above, or hand this output back to the ideation agent"; exit 1
fi
