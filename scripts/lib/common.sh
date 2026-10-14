#!/usr/bin/env bash
# scripts/lib/common.sh — paths, IDEA.md config, logging, timeouts, ntfy, task helpers.
# Sourced by every other lib, by orchestrate.sh, and by .claude/hooks/*. Zero tokens.
[[ -n "${__FLEET_COMMON_LOADED:-}" ]] && return 0
__FLEET_COMMON_LOADED=1

ROOT="${FLEET_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
REPO_NAME="$(basename "$ROOT")"
WT_ROOT="$(dirname "$ROOT")/$REPO_NAME.wt"
BUNDLE_ROOT="$(dirname "$ROOT")/$REPO_NAME.bundles"
AGENTS_DIR="$ROOT/.agents"
TASKS_DIR="$AGENTS_DIR/tasks"
LOG_DIR="$AGENTS_DIR/logs"
RECEIPT_DIR="$AGENTS_DIR/receipts"
REVIEW_DIR="$AGENTS_DIR/reviews"
SCHEMA_DIR="$AGENTS_DIR/schemas"
SKILL_DIR="$AGENTS_DIR/skills"
RULES_DIR="$AGENTS_DIR/rules"
PROMPT_DIR="$AGENTS_DIR/prompts"
TMP_DIR="$AGENTS_DIR/tmp"
QUOTA_DIR="$AGENTS_DIR/quota"
LEDGER="$AGENTS_DIR/ledger.json"
STATE_FILE="$AGENTS_DIR/STATE.md"
FROZEN_FILE="$AGENTS_DIR/frozen.sha256"
LAYERS_FILE="$AGENTS_DIR/layers.yaml"
SPEC_FILE="$AGENTS_DIR/architecture/SYSTEM_SPEC.md"
IDEA_FILE="${FLEET_IDEA_FILE:-$ROOT/IDEA.md}"
DOCS_DIR="$ROOT/docs"
RUN_LOCK="$AGENTS_DIR/run.lock"
LINE_LIMIT=300
PROMPT_TOKEN_LIMIT=100000
TIER1_MODEL="gpt-6.1-sol"
TIER2_MODEL="claude-opus-5-5"
TIER3_MODEL="gpt-6.1-sol"
FLEET_DRY_RUN="${FLEET_DRY_RUN:-0}"

mkdir -p "$LOG_DIR" "$RECEIPT_DIR" "$REVIEW_DIR" "$PROMPT_DIR" "$TMP_DIR" "$QUOTA_DIR" "$TASKS_DIR"

# ---- logging ---------------------------------------------------------------
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_DIR/orchestrate.log" >&2; }
warn() { log "WARN: $*"; }
die() { log "FATAL: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log_tail() { [[ -f "$1" ]] && tail -n "${2:-40}" "$1" | cut -c1-400; }

# ---- subscription-only auth (Section 1.1) ----------------------------------
subscription_only() {
  unset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY_OLD \
        OPENAI_BASE_URL ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1
}

# ---- IDEA.md front-matter config -------------------------------------------
idea_get() {  # idea_get '.quota.soft_ceiling_pct' [default]
  local v=""
  [[ -f "$IDEA_FILE" ]] && v="$(yq --front-matter=extract -r "$1 // \"\"" "$IDEA_FILE" 2>/dev/null)"
  if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi
}
idea_list() { [[ -f "$IDEA_FILE" ]] && yq --front-matter=extract -r "$1 // [] | .[]" "$IDEA_FILE" 2>/dev/null; }
idea_body_block() {  # idea_body_block <fence-info> : contents of ```<fence-info> ... ``` in IDEA.md body
  awk -v tag="$1" 'BEGIN{p=0} $0 ~ "^```"tag"[[:space:]]*$" {p=1; next} p && /^```/ {exit} p {print}' "$IDEA_FILE"
}
base_branch() { idea_get '.pr.base' main; }
stack() { idea_get '.stack.language' ts; }           # ts | python | none
is_ts() { [[ "$(stack)" == "ts" ]]; }
is_py() { [[ "$(stack)" == "python" ]]; }
tier_timeout() {  # tier_timeout <key> -> seconds; keys: tier1 phase_a phase_b surgery coder reviewer closeout gate
  local m; m="$(idea_get ".timeouts.${1}_min")"
  case "${1}:${m}" in
    tier1:) m=45 ;; phase_a:) m=40 ;; phase_b:) m=30 ;; surgery:) m=40 ;;
    coder:) m=50 ;; reviewer:) m=15 ;; closeout:) m=25 ;; gate:) m=20 ;; *) : ;;
  esac
  echo $(( m * 60 ))
}
max_parallel() { idea_get '.quota.max_parallel_workers' 2; }

# ---- time helpers (GNU coreutils on macOS via gdate) -----------------------
_date() { if have gdate; then gdate "$@"; else date "$@"; fi; }
epoch_of() {  # ISO-8601 -> epoch seconds
  _date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}
iso_of() {    # epoch seconds -> ISO-8601 UTC
  _date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# ---- hard timeouts (Section 4 stall protection) ----------------------------
timeout_bin() { if have gtimeout; then echo gtimeout; elif have timeout; then echo timeout; fi; }
run_with_timeout() {  # run_with_timeout <seconds> <logfile> -- cmd args... ; stdin passes through; 124 on timeout
  local secs="$1" logf="$2"; shift 2; [[ "${1:-}" == "--" ]] && shift
  local tb; tb="$(timeout_bin)"
  if [[ -n "$tb" ]]; then
    "$tb" --kill-after=20 --signal=TERM "$secs" "$@" >>"$logf" 2>&1
    return $?
  fi
  set -m; "$@" >>"$logf" 2>&1 & local pid=$!; set +m
  ( sleep "$secs"; kill -TERM -- -"$pid" 2>/dev/null; sleep 20; kill -KILL -- -"$pid" 2>/dev/null ) & local wd=$!
  wait "$pid"; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [[ $rc -eq 143 ]] && rc=124
  return $rc
}

# ---- ntfy push notifications -----------------------------------------------
ntfy_send() {  # ntfy_send <title> <message> [priority: min|low|default|high|urgent]
  local topic server; topic="$(idea_get '.ntfy.topic')"; server="$(idea_get '.ntfy.server' https://ntfy.sh)"
  log "ntfy[$1] $2"
  [[ -z "$topic" || "$FLEET_DRY_RUN" == 1 ]] && return 0
  curl -fsS -m 10 -H "Title: $REPO_NAME: $1" -H "Priority: ${3:-default}" -H "Tags: robot" \
    -d "$2" "${server%/}/$topic" >/dev/null 2>&1 || warn "ntfy send failed"
}

# ---- git helpers -----------------------------------------------------------
main_sha() { git -C "$ROOT" rev-parse "$(base_branch)"; }
remote_main_sha() {
  [[ "$FLEET_DRY_RUN" == 1 ]] && { cat "$TMP_DIR/remote-main.sha" 2>/dev/null || main_sha; return; }
  git -C "$ROOT" ls-remote origin "refs/heads/$(base_branch)" 2>/dev/null | cut -f1
}
wt_dir() { printf '%s/%s' "$WT_ROOT" "$1"; }
wt_list() { git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2}' | grep -v "^$ROOT\$" || true; }
json_validate() {  # json_validate <schema> <file>
  check-jsonschema --schemafile "$1" "$2" >>"$LOG_DIR/jsonschema.log" 2>&1
}

# ---- task file helpers (frontmatter is the Dataview view of the ledger) -----
task_file() { printf '%s/%s.md' "$TASKS_DIR" "$1"; }
task_fm() { [[ -f "$(task_file "$1")" ]] && yq --front-matter=extract -r "$2" "$(task_file "$1")" 2>/dev/null; }
task_list_field() {  # prefers ledger, falls back to the task file frontmatter
  local v=""
  [[ -f "$LEDGER" ]] && v="$(jq -r --arg t "$1" --arg f "$2" '.tasks[$t][$f] // [] | .[]' "$LEDGER" 2>/dev/null)"
  [[ -n "$v" ]] || v="$(task_fm "$1" ".$2 // [] | .[]")"
  printf '%s\n' "$v" | sed '/^$/d'
}
task_owned_files() { task_list_field "$1" owned_files; }
task_readonly_files() { task_list_field "$1" readonly_files; }
task_approved_deps() { task_list_field "$1" approved_deps; }
task_risk() { local r; r="$(jq -r --arg t "$1" '.tasks[$t].risk // ""' "$LEDGER" 2>/dev/null)"; [[ -n "$r" ]] || r="$(task_fm "$1" '.risk // "low"')"; echo "${r:-low}"; }
task_layer() { printf '%s' "$1" | sed -E 's/^TASK-0*([0-9]+)-.*/\1/'; }
layer_tag() { printf 'layer-%s-base' "$1"; }

# ---- 300-line rule exclusions (lockfiles, generated, snapshots, migrations, data) ---
LINE_LIMIT_EXCLUDE_RE='(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|uv\.lock|poetry\.lock|Cargo\.lock)$|\.snap$|(^|/)__snapshots__/|(^|/)migrations?/|\.generated\.|(^|/)__generated__/|(^|/)generated/|\.min\.(js|css)$|_pb2\.py$|\.pb\.go$|\.(json|jsonl|csv|tsv|svg|html|md|txt|lock)$'
line_limit_excluded() { printf '%s' "$1" | grep -Eq "$LINE_LIMIT_EXCLUDE_RE"; }
contract_path_re() { printf '%s' '(\.d\.ts$|(^|/)contracts?(/|$)|(^|/)schemas?(/|$)|\.schema\.json$|openapi|swagger|\.proto$|\.graphql$|\.prisma$)'; }
is_contract_path() { printf '%s' "$1" | grep -Eq "$(contract_path_re)"; }

# ---- frozen contracts / acceptance tests -----------------------------------
frozen_verify() {  # frozen_verify [dir] : verify .agents/frozen.sha256 against a tree (default root)
  local dir="${1:-$ROOT}"
  [[ -s "$FROZEN_FILE" ]] || return 0
  (cd "$dir" && shasum -a 256 --check --quiet --strict "$FROZEN_FILE") >>"$LOG_DIR/frozen.log" 2>&1
}
frozen_record() {  # frozen_record <file...> : (re)write hashes for the given root-relative files
  (cd "$ROOT" && shasum -a 256 "$@") > "$FROZEN_FILE"
}
