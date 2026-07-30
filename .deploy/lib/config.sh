#!/usr/bin/env bash
# =============================================================================
# config.sh — read deploy.config.yml, derive names, expand ${TOKENS}.
# MACHINERY. Contains nothing project-specific.
#
# The YAML is converted to JSON exactly once, then every read goes through jq.
# That keeps YAML parsing in one place and means the rest of the machinery
# never has to think about YAML quirks.
# =============================================================================
# shellcheck shell=bash

: "${DEPLOY_DIR:?DEPLOY_DIR must be set before sourcing config.sh}"
# shellcheck source=./log.sh
source "$DEPLOY_DIR/lib/log.sh"

CFG_JSON=""          # path to the converted JSON
CFG_FILE=""          # path to the source YAML

# -----------------------------------------------------------------------------
# cfg_load [path-to-deploy.config.yml]
# -----------------------------------------------------------------------------
cfg_load() {
  # DEPLOY_CONFIG overrides for tests; otherwise probe the project root (the
  # caller already cd'd there): .deploy/config.yml when the folder was copied
  # into the repo, deploy.config.yml when the kit runs as a GitHub Action and
  # no folder exists. Never fall back to the kit's own blank config — a
  # missing project config must be an error, not a silent empty deploy.
  local file="${1:-${DEPLOY_CONFIG:-}}"
  if [[ -z "$file" ]]; then
    local candidates=(.deploy/config.yml deploy.config.yml)
    # Folder mode keeps the old "next to the kit" fallback so upload-dump.sh
    # works from any directory. Action mode (DEPLOY_PROJECT_DIR set) must not
    # get it: there $DEPLOY_DIR/config.yml is the kit repo's own blank file.
    [[ -z "${DEPLOY_PROJECT_DIR:-}" ]] && candidates+=("$DEPLOY_DIR/config.yml")
    local c
    for c in "${candidates[@]}"; do
      [[ -f "$c" ]] && { file="$c"; break; }
    done
  fi

  [[ -n "$file" && -f "$file" ]] || die "no config found. Expected one of:
  .deploy/config.yml     (copied-folder setup — bash .deploy/install.sh creates it)
  deploy.config.yml      (GitHub Action setup — copy config.example.yml from the kit repo)"

  require_cmd yq jq
  CFG_FILE="$file"
  CFG_JSON="$(mktemp)"

  # mikefarah/yq: -o=json. Failure here means malformed YAML — say so plainly
  # rather than letting jq produce a baffling error two calls later.
  if ! yq -o=json '.' "$file" >"$CFG_JSON" 2>/tmp/yqerr; then
    log_err "deploy.config.yml is not valid YAML:"
    sed 's/^/    /' /tmp/yqerr >&2
    exit 1
  fi

  # --- machinery/config version handshake ------------------------------------
  local machinery_v config_v
  machinery_v="$(tr -d '[:space:]' <"$DEPLOY_DIR/VERSION")"
  config_v="$(cfg '.version' '')"

  [[ -z "$config_v" || "$config_v" == "null" ]] && \
    die "config.yml is missing 'version:'. Add 'version: $machinery_v' at the top."

  if [[ "$config_v" != "$machinery_v" ]]; then
    die "version mismatch — the machinery is v$machinery_v but config.yml says v$config_v.
Nothing has been changed. Either restore the matching machinery version, or
update config.yml to the new format."
  fi

  log_info "config: $(basename "$file") (v$config_v), machinery v$machinery_v"
}

# -----------------------------------------------------------------------------
# cfg <jq-path> [default] — read a scalar. Empty/null falls back to the default.
# -----------------------------------------------------------------------------
cfg() {
  local path="$1" default="${2-}" out
  out="$(jq -r "${path} // empty" "$CFG_JSON" 2>/dev/null || true)"
  [[ -z "$out" || "$out" == "null" ]] && out="$default"
  printf '%s' "$out"
}

# cfg_json <jq-path> — read a sub-tree as raw JSON ({} when absent).
cfg_json() {
  local path="$1" out
  out="$(jq -c "${path} // {}" "$CFG_JSON" 2>/dev/null || printf '{}')"
  [[ -z "$out" || "$out" == "null" ]] && out='{}'
  printf '%s' "$out"
}

# cfg_list <jq-path> — read an array as newline-separated values.
cfg_list() {
  jq -r "${1} // [] | .[]" "$CFG_JSON" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# slugify <string> — safe for DNS labels and Railway environment names.
# lowercase, non-alphanumerics collapse to a single dash, trimmed, max 30.
# -----------------------------------------------------------------------------
slugify() {
  # tr first: sed works line by line, so without it a multi-line input would
  # KEEP its newlines and produce a broken multi-line "slug".
  printf '%s' "$1" \
    | tr '[:space:]' ' ' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-30 \
    | sed -E 's/-+$//'
}

# -----------------------------------------------------------------------------
# compute_names — derive every name and token the run needs.
# Sets: BRANCH BRANCH_SLUG SHA SHA7 STAGE PROJECT_NAME ENV_NAME
# -----------------------------------------------------------------------------
compute_names() {
  # The git fallback needs care: on a repo with no commits yet, rev-parse
  # prints a partial "HEAD" AND fails, so a naive $(... || echo local) captures
  # both lines glued together. Capture first, then judge the result — and a
  # detached HEAD (literally "HEAD") is no branch name either.
  local _b=""
  if [[ -z "${DEPLOY_BRANCH:-}${GITHUB_REF_NAME:-}" ]]; then
    _b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || _b=""
    [[ -z "$_b" || "$_b" == "HEAD" ]] && _b="local"
  fi
  BRANCH="${DEPLOY_BRANCH:-${GITHUB_REF_NAME:-$_b}}"
  SHA="${DEPLOY_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo 0000000)}}"
  SHA7="${SHA:0:7}"
  STAGE="${DEPLOY_STAGE:-preview}"

  case "$STAGE" in
    preview|dev|prod) ;;
    *) die "stage must be preview, dev or prod — got '$STAGE'" ;;
  esac

  BRANCH_SLUG="$(slugify "$BRANCH")"
  [[ -z "$BRANCH_SLUG" ]] && die "branch name '$BRANCH' produced an empty slug"

  PROJECT_NAME="$(cfg '.project.name')"

  # An unfilled template must not stop here with one cryptic error — the
  # validator's job is to list EVERY placeholder at once, so a fresh project can
  # be filled in one pass rather than one error at a time.
  if [[ "$PROJECT_NAME" == "TODO_FILL_ME" ]]; then
    PROJECT_NAME="unconfigured"
  elif [[ -z "$PROJECT_NAME" ]]; then
    # Empty means "use the repo's name" — one less thing to configure. The env
    # name budget is 63 chars shared with the branch slug, hence the cap at 20.
    local repo="${GITHUB_REPOSITORY:-}"
    repo="${repo##*/}"
    [[ -z "$repo" ]] && repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || printf 'app')")"
    PROJECT_NAME="$(slugify "$repo" | cut -c1-20 | sed -E 's/-+$//')"
    [[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="app"
    log_info "project.name is empty — using the repository's name: $PROJECT_NAME"
  elif [[ ! "$PROJECT_NAME" =~ ^[a-z0-9-]+$ ]]; then
    die "project.name must be lowercase letters, digits and dashes only — got '$PROJECT_NAME'"
  fi

  ENV_NAME="${PROJECT_NAME}-${BRANCH_SLUG}"
  (( ${#ENV_NAME} > 63 )) && \
    die "environment name '$ENV_NAME' is ${#ENV_NAME} chars (max 63). Shorten project.name."

  export BRANCH BRANCH_SLUG SHA SHA7 STAGE PROJECT_NAME ENV_NAME
}

# -----------------------------------------------------------------------------
# interp <string> — expand the documented ${TOKENS}.
#
# Deliberately NOT eval. Config content is data; running it as shell would let a
# stray backtick in a config file execute commands in CI.
# -----------------------------------------------------------------------------
interp() {
  local s="$1"
  s="${s//\$\{BRANCH_SLUG\}/${BRANCH_SLUG:-}}"
  s="${s//\$\{BRANCH\}/${BRANCH:-}}"
  s="${s//\$\{SHA7\}/${SHA7:-}}"
  s="${s//\$\{SHA\}/${SHA:-}}"
  s="${s//\$\{ENV_NAME\}/${ENV_NAME:-}}"
  s="${s//\$\{STAGE\}/${STAGE:-}}"
  s="${s//\$\{PROJECT_NAME\}/${PROJECT_NAME:-}}"
  s="${s//\$\{DB_URI\}/${DB_URI:-}}"
  s="${s//\$\{PUBLIC_URL\}/${PUBLIC_URL:-}}"
  printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# resolve_path <path> — config paths are relative to the project root, but the
# ready-made presets ship with the kit. When the file is missing from the
# project and the path points into .deploy/, fall back to the kit's own copy —
# that is what keeps `dockerfile_path: .deploy/presets/frontend-static.Dockerfile`
# working even when .deploy/ was never copied into the repo (GitHub Action
# setup, where the kit sits in the action's checkout, not the project).
# -----------------------------------------------------------------------------
resolve_path() {
  local p="$1"
  if [[ ! -f "$p" && "$p" == .deploy/* && -f "$DEPLOY_DIR/${p#.deploy/}" ]]; then
    p="$DEPLOY_DIR/${p#.deploy/}"
  fi
  printf '%s' "$p"
}

# -----------------------------------------------------------------------------
# url_enc <string> — percent-encode a URI component. Used by the database
# engines so a generated password containing @ : / ? # cannot break the
# connection string.
# -----------------------------------------------------------------------------
url_enc() {
  local s="$1" out='' i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# stage_env — the env map for the current stage (preview_defaults.env for
# preview; empty otherwise). Kept separate so precedence stays explicit.
# -----------------------------------------------------------------------------
stage_env() {
  [[ "$STAGE" == "preview" ]] && cfg_json '.preview_defaults.env' || printf '{}'
}

# stage_secret_map — the secrets_by_stage mapping for this stage:
# { APP_VAR_NAME: GITHUB_SECRET_NAME }
stage_secret_map() {
  cfg_json ".env.secrets_by_stage.\"$STAGE\""
}

cfg_cleanup() { [[ -n "$CFG_JSON" && -f "$CFG_JSON" ]] && rm -f "$CFG_JSON"; return 0; }
trap cfg_cleanup EXIT
