#!/usr/bin/env bash
# =============================================================================
# steps/vars.sh — build the final variable set and apply it in ONE call.
# MACHINERY.
#
# PRECEDENCE, lowest to highest:
#   1. env.static             plain values, every stage
#   2. env.secrets            generic repo secrets
#   3. preview_defaults.env   stage values    <-- beats generic secrets
#   4. env.secrets_by_stage   stage secrets   <-- beats generic secrets
#   5. env.per_env            per-branch derived values
#   6. machinery              the provisioned database connection string
#
# 3 and 4 deliberately outrank 2. If a repo has S3_BUCKET_NAME set as a secret
# for production, a preview must still use the stage's throwaway bucket — the
# generic secret must not leak through and point a preview at production
# storage. That is the exact accident this design exists to prevent.
#
# Applied in one call with skipDeploys:true, so Railway does not start a deploy
# against a half-configured service.
# =============================================================================
# shellcheck shell=bash

step_vars() {
  group_start "Applying variables"

  # Not `local` — release.sh reads the resolved set back to work out the app's
  # URL prefix without having to re-derive precedence.
  VARS='{}'
  _add() { [[ -z "$1" ]] && return 0
           VARS="$(printf '%s' "$VARS" | jq -c --arg k "$1" --arg v "$2" '.[$k]=$v')"; }

  local stage_env stage_secrets k v name src
  stage_env="$(stage_env)"; stage_secrets="$(stage_secret_map)"

  # 1. static
  while IFS= read -r k; do [[ -z "$k" ]] && continue
    _add "$k" "$(interp "$(cfg_json '.env.static' | jq -r --arg k "$k" '.[$k]|tostring')")"
  done < <(cfg_json '.env.static' | jq -r 'keys_unsorted[]')

  # 2. generic secrets — skipped when the stage supplies the same variable
  while IFS= read -r name; do [[ -z "$name" ]] && continue
    printf '%s' "$stage_env"     | jq -e --arg k "$name" 'has($k)' >/dev/null 2>&1 && continue
    printf '%s' "$stage_secrets" | jq -e --arg k "$name" 'has($k)' >/dev/null 2>&1 && continue
    v="$(secret_get "$name")"
    [[ -n "$v" ]] && { mask "$v"; _add "$name" "$v"; }
  done < <(cfg_list '.env.secrets')

  # 3. stage plain values
  while IFS= read -r k; do [[ -z "$k" ]] && continue
    _add "$k" "$(interp "$(printf '%s' "$stage_env" | jq -r --arg k "$k" '.[$k]|tostring')")"
  done < <(printf '%s' "$stage_env" | jq -r 'keys_unsorted[]')

  # 4. stage secrets
  while IFS= read -r k; do [[ -z "$k" ]] && continue
    src="$(printf '%s' "$stage_secrets" | jq -r --arg k "$k" '.[$k]')"
    v="$(secret_get "$src")"
    [[ -z "$v" ]] && die "secret '$src' (supplying $k for stage $STAGE) is not set"
    mask "$v"; _add "$k" "$v"
  done < <(printf '%s' "$stage_secrets" | jq -r 'keys_unsorted[]')

  # 5. per-branch
  while IFS= read -r k; do [[ -z "$k" ]] && continue
    _add "$k" "$(interp "$(cfg_json '.env.per_env' | jq -r --arg k "$k" '.[$k]|tostring')")"
  done < <(cfg_json '.env.per_env' | jq -r 'keys_unsorted[]')

  # 6. machinery-owned
  # PORT: the machinery sets the value the app must listen on, and the deploy
  # step aims the public domain at the same number. Relying on Railway's port
  # detection instead once served 502s while the app ran fine — the edge was
  # aimed at the base image's EXPOSE default. A user-supplied value (env.static
  # or a stage map) wins over the default.
  local pname pport
  pname="$(cfg '.runtime.port_env' 'PORT')"
  pport="$(cfg '.runtime.port' '8080')"
  printf '%s' "$VARS" | jq -e --arg k "$pname" 'has($k)' >/dev/null 2>&1 || _add "$pname" "$pport"

  local conn; conn="$(cfg '.db.connection_env' '')"
  if [[ -n "$conn" && -n "${DB_URI:-}" ]]; then
    _add "$conn" "$DB_URI"
    # Some projects' maintenance scripts read a different name for the same
    # database. Set them all, so those scripts work inside the container too.
    while IFS= read -r name; do [[ -z "$name" ]] && continue; _add "$name" "$DB_URI"; done \
      < <(cfg_list '.db.extra_connection_env')
  fi

  local count; count="$(printf '%s' "$VARS" | jq 'length')"
  log_info "applying $count variables in one call (skipDeploys: true)"
  # Names only — several of these values are secrets.
  printf '%s' "$VARS" | jq -r 'keys_unsorted[]' | sed 's/^/    /' >&2

  rw_vars_set "$PROJECT_ID" "$ENVIRONMENT_ID" "$APP_SERVICE_ID" "$VARS" true \
    || die "could not apply variables to the app service"

  APP_VARS="$VARS"      # read by release.sh to resolve runtime.base_path_env
  log_ok "$count variables applied"
  group_end
}
