#!/usr/bin/env bash
# =============================================================================
# steps/validate.sh — check everything checkable before anything is created.
# MACHINERY.
# =============================================================================
# shellcheck shell=bash

step_validate() {
  local errors=0
  # Problems are also collected so they can be RE-PRINTED outside the log group
  # at the end. GitHub collapses ::group:: blocks by default, so an error only
  # shown inside one is invisible until you expand it — you'd see "1 problem"
  # and nothing about what it was.
  PROBLEMS=()
  _problem() { log_err "$*"; PROBLEMS+=("$*"); errors=$((errors + 1)); }

  # These ALWAYS return 0 on purpose. run.sh runs under `set -e`, so a helper
  # that returned non-zero would abort the whole run at the first bad value —
  # you'd fix one thing, re-run, and be told about the next. The point of this
  # step is to report EVERY problem in one pass.
  _one_of() {                      # _one_of <value> <name> <allowed...>
    local v="$1" name="$2"; shift 2
    for a in "$@"; do [[ "$v" == "$a" ]] && return 0; done
    _problem "$name must be one of: $* — got '$v'"
    return 0
  }

  _need() {                        # _need <jq-path> <human name>
    local v; v="$(cfg "$1" '')"
    [[ -z "$v" ]] && _problem "$2 is required (config: ${1#.})"
    [[ "$v" == "TODO_FILL_ME" ]] && _problem "$2 is still TODO_FILL_ME (config: ${1#.})"
    return 0
  }

  group_start "Checking config.yml"
  log_info "branch      : $BRANCH  →  $BRANCH_SLUG"
  log_info "commit      : $SHA7"
  log_info "stage       : $STAGE"
  log_info "environment : $ENV_NAME"

  # --- placeholders ----------------------------------------------------------
  # Scans the PARSED config, so comments explaining the convention don't trip it.
  if jq -e '[paths(scalars) as $p | select((getpath($p)|tostring)=="TODO_FILL_ME")]|length>0' \
       "$CFG_JSON" >/dev/null 2>&1; then
    _problem "config.yml still has unfilled placeholders — fill in every one of these:"
    while IFS= read -r p; do log "      • $p"; done < <(
      jq -r 'paths(scalars) as $p | select((getpath($p)|tostring)=="TODO_FILL_ME") | ($p|join("."))' "$CFG_JSON")
    log "    File: $CFG_FILE"
    log "    Guide: .deploy/docs/COPY-TO-NEW-PROJECT.md"
    # Later checks would just repeat the same placeholders as separate errors.
    # One clear list beats a dozen near-identical messages.
    group_end
    die "config.yml is not filled in yet — see the list above"
  fi

  # --- railway ----------------------------------------------------------------
  if [[ -z "$(cfg '.railway.project_id' '')" ]]; then
    if [[ "$(cfg '.railway.create_if_missing' 'false')" == "true" ]]; then
      log_warn "railway.project_id is empty — an existing project with this name will be"
      log_warn "reused, or a new one created. Optional: pin the id in config.yml so a"
      log_warn "project rename can never break the link."
    else
      _problem "railway.project_id is required (or set railway.create_if_missing: true)"
    fi
  fi

  # --- build -------------------------------------------------------------------
  local method; method="$(cfg '.build.method' '')"
  _one_of "$method" "build.method" dockerfile nixpacks
  if [[ "$method" == "dockerfile" ]]; then
    local df; df="$(cfg '.build.dockerfile_path' '')"
    if [[ -z "$df" ]]; then
      _problem "build.dockerfile_path is required when build.method is dockerfile"
    elif [[ -z "${DEPLOY_SKIP_FILE_CHECKS:-}" && ! -f "$(resolve_path "$df")" ]]; then
      _problem "build.dockerfile_path points at '$df', which does not exist"
    fi
  fi
  _one_of "$(cfg '.build.registry_visibility' 'public')" "build.registry_visibility" public private

  if [[ "$(cfg '.build.registry_visibility' 'public')" == "private" ]]; then
    local rpe; rpe="$(cfg '.build.registry_password_env' 'GHCR_PULL_TOKEN')"
    secret_has "$rpe" || _problem "build.registry_visibility is 'private', but the secret '$rpe' is not set.
      Railway needs it to pull the locked image. Create a GitHub token (classic)
      with the read:packages scope at github.com/settings/tokens and add it as
      that repo secret — the same token works in every repo you own."
  fi

  # --- runtime ------------------------------------------------------------------
  # interp first: ${TOKENS} are allowed here (e.g. /${BRANCH_SLUG}/health), and
  # the leading-slash rule applies to the expanded result.
  local hc; hc="$(interp "$(cfg '.runtime.health_check_path' '')")"
  _need '.runtime.health_check_path' 'runtime.health_check_path' || true
  [[ -n "$hc" && "${hc:0:1}" != "/" ]] && _problem "runtime.health_check_path must start with '/' — got '$hc'"
  [[ "$(cfg '.runtime.health_check_timeout' '300')" =~ ^[0-9]+$ ]] || \
    _problem "runtime.health_check_timeout must be a whole number"
  _need '.runtime.port_env' 'runtime.port_env' || true

  # --- database -------------------------------------------------------------------
  local engine; engine="$(cfg '.db.engine' 'none')"
  _one_of "$engine" "db.engine" mongo postgres none
  [[ "${DB_ENGINE_INVALID:-}" == "true" ]] && \
    _problem "db.engine '$engine' has no driver — the run cannot provision a database"

  if [[ "$engine" != "none" && -f "$DEPLOY_DIR/engines/$engine.sh" ]]; then
    _need '.db.connection_env' 'db.connection_env' || true
    _need '.db.service_image'  'db.service_image'  || true
    _need '.db.database_name'  'db.database_name'  || true

    local tool; tool="$(cfg '.db.restore.tool' 'none')"
    _one_of "$tool" "db.restore.tool" mongorestore pg_restore psql none

    if [[ "$tool" != "none" ]]; then
      _one_of "$(cfg '.db.restore.mode' 'always')" "db.restore.mode" always once

      # Which dump (if any) this run will load. NO dump is the normal, valid
      # default — a preview starts empty unless someone names one — so an empty
      # answer here is reported, never faulted.
      seed_resolve_source
      local seed="$SEED_SOURCE"
      [[ -n "$SEED_RESOLVE_ERR" ]] && _problem "$SEED_RESOLVE_ERR"

      if [[ -z "$seed" && -z "$SEED_RESOLVE_ERR" ]]; then
        log_info "dump        : none chosen — the database will start EMPTY"
        log_info "              (type a file name in the button's 'dump' box, or"
        log_info "               set db.restore.default_dump to always seed)"
      elif [[ "$seed" == s3://* ]]; then
        log_info "dump        : $seed"
        local kn sn
        kn="$(cfg '.db.restore.s3_key_id_env' 'SEED_S3_ACCESS_KEY_ID')"
        sn="$(cfg '.db.restore.s3_secret_env' 'SEED_S3_SECRET_ACCESS_KEY')"
        secret_has "$kn" || _problem "secret '$kn' is not set — needed to download the dump"
        secret_has "$sn" || _problem "secret '$sn' is not set — needed to download the dump"
      elif [[ -n "$seed" && ! -f "$seed" ]]; then
        _problem "the dump '$seed' is not an s3:// URL and does not exist as a file.
      Remember CI only has what is COMMITTED — an untracked local file is not there.
      Upload dumps to $(seed_folder_url), then pick one by name."
      fi
    fi

    [[ -z "$(cfg '.db.migrate.command' '')" ]] && \
      log_info "migrate     : skipped (no command configured — by design)"
  fi

  # --- secrets ---------------------------------------------------------------------
  local stage_env stage_secrets missing=() name src
  stage_env="$(stage_env)"; stage_secrets="$(stage_secret_map)"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    printf '%s' "$stage_env" | jq -e --arg k "$name" 'has($k)' >/dev/null 2>&1 && continue
    src="$name"
    printf '%s' "$stage_secrets" | jq -e --arg k "$name" 'has($k)' >/dev/null 2>&1 && \
      src="$(printf '%s' "$stage_secrets" | jq -r --arg k "$name" '.[$k]')"
    secret_has "$src" || missing+=("$src  (supplies $name)")
  done < <(cfg_list '.env.secrets')

  if ((${#missing[@]})); then
    _problem "these secrets are named in config.yml but are not set:"
    for m in "${missing[@]}"; do log "      • $m"; PROBLEMS+=("    • $m"); done

    # A stage with no configuration is the most likely cause, and produces a
    # confusing pile of "missing secret" errors that are really one mistake.
    if [[ "$STAGE" != "preview" ]] \
       && [[ "$(cfg_json ".env.secrets_by_stage.\"$STAGE\"")" == '{}' ]]; then
      _problem "LIKELY CAUSE: you ran with stage '$STAGE', but config.yml has no
      settings for it — only 'preview' is configured. Re-run with stage: preview,
      or add an env.secrets_by_stage.$STAGE section."
    else
      log "    Add them under Settings → Secrets and variables → Actions."
      log "    No workflow edit needed — they are picked up automatically."
    fi
  fi

  local conn; conn="$(cfg '.db.connection_env' '')"
  if [[ -n "$conn" ]] && cfg_json '.env.static' | jq -e --arg k "$conn" 'has($k)' >/dev/null 2>&1; then
    _problem "env.static sets $conn, but the machinery provisions that itself. Remove it."
  fi
  group_end

  # --- what will actually be applied -------------------------------------------------
  group_start "Variables that will be applied to $ENV_NAME"
  {
    printf '%-34s %s\n' "VARIABLE" "VALUE"
    printf '%-34s %s\n' "----------------------------------" "-----------------------------"
    local k
    while IFS= read -r k; do [[ -z "$k" ]] && continue
      printf '%-34s %s\n' "$k" "$(interp "$(cfg_json '.env.static' | jq -r --arg k "$k" '.[$k]|tostring')")"
    done < <(cfg_json '.env.static' | jq -r 'keys_unsorted[]')
    while IFS= read -r k; do [[ -z "$k" ]] && continue
      printf '%-34s %s\n' "$k" "$(interp "$(printf '%s' "$stage_env" | jq -r --arg k "$k" '.[$k]|tostring')")   [$STAGE]"
    done < <(printf '%s' "$stage_env" | jq -r 'keys_unsorted[]')
    while IFS= read -r k; do [[ -z "$k" ]] && continue
      printf '%-34s %s\n' "$k" "$(interp "$(cfg_json '.env.per_env' | jq -r --arg k "$k" '.[$k]|tostring')")   [per-branch]"
    done < <(cfg_json '.env.per_env' | jq -r 'keys_unsorted[]')
    while IFS= read -r k; do [[ -z "$k" ]] && continue
      printf '%s' "$stage_env" | jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1 && continue
      printf '%-34s %s\n' "$k" "•••••• (secret)"
    done < <(cfg_list '.env.secrets')
    [[ -n "$conn" ]] && printf '%-34s %s\n' "$conn" "•••••• (provisioned at deploy time)"
    printf '%-34s %s\n' "$(cfg '.runtime.port_env' 'PORT')" "$(cfg '.runtime.port' '8080')   [machinery — the domain routes here]"
  } >&2
  group_end

  # Re-print everything OUTSIDE any group, so the failure is readable in the
  # Actions log without expanding anything.
  if (( errors )); then
    log ""
    log_err "════════ $errors problem(s) — nothing was created ════════"
    local p
    for p in "${PROBLEMS[@]}"; do log "  $p"; done
    log ""
    die "fix the above and re-run"
  fi
  log_ok "config is valid — $ENV_NAME ready"
}
