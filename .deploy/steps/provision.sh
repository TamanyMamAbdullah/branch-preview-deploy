#!/usr/bin/env bash
# =============================================================================
# steps/provision.sh — ensure the environment, database and app service exist.
# Idempotent: every create is preceded by a lookup, so re-deploying a branch
# reuses what is there rather than duplicating it.
# Sets PROJECT_ID, ENVIRONMENT_ID, APP_SERVICE_ID, DB_SERVICE_ID, DB_URI.
# MACHINERY.
# =============================================================================
# shellcheck shell=bash

step_provision() {
  require_cmd curl jq

  # --- project ----------------------------------------------------------------
  group_start "Railway project"
  PROJECT_ID="$(cfg '.railway.project_id' '')"

  if [[ -n "$PROJECT_ID" ]]; then
    rw_project_exists "$PROJECT_ID" || die "railway.project_id '$PROJECT_ID' not found, or this token cannot see it.
Check the id, and that the token belongs to the same account or team."
    log_ok "using project $PROJECT_ID"
  else
    [[ "$(cfg '.railway.create_if_missing' 'false')" == "true" ]] \
      || die "railway.project_id is empty and create_if_missing is false"
    local pname ws
    pname="$(cfg '.railway.project_name' '')"
    [[ -z "$pname" ]] && pname="$PROJECT_NAME"

    # A project must belong to a workspace. Auto-detect when there is only one,
    # so this isn't another value to look up and paste in. Detection is
    # best-effort: a workspace-scoped token cannot list workspaces at all, but
    # can often still create the project — so an empty answer downgrades to a
    # warning and the create is attempted anyway. If Railway then refuses, the
    # error is shown along with exactly what to configure.
    ws="$(cfg '.railway.workspace_id' '')"
    if [[ -z "$ws" ]]; then
      ws="$(rw_workspace_default)"
      if [[ -n "$ws" ]]; then
        log_info "workspace: $ws (auto-detected — the only one on this account)"
      else
        local wslist; wslist="$(rw_workspace_list)"
        if [[ -n "$wslist" ]]; then
          log_err "this account has more than one workspace, so the right one cannot be guessed."
          log_err "Set railway.workspace_id in .deploy/config.yml to one of:"
          printf '%s\n' "$wslist" | sed 's/^/      /' >&2
          die "railway.workspace_id is required for this account"
        fi
        log_warn "could not list this account's workspaces (a workspace-scoped token"
        log_warn "cannot ask) — attempting to create the project without one"
      fi
    else
      log_info "workspace: $ws (from config)"
    fi

    log_info "creating project '$pname'"
    PROJECT_ID="$(rw_project_create "$pname" "$ws")" || die "could not create the Railway project.
If the error above mentions a workspace or team: set railway.workspace_id in
.deploy/config.yml (open railway.com, pick the workspace, the id is in the
URL) — OR create an empty project in the dashboard yourself and paste its id
into railway.project_id. Either one unblocks every future deploy."
    log_ok "created project $PROJECT_ID"

    log_warn "══════════════════════════════════════════════════════════"
    log_warn " Put this in .deploy/config.yml so future runs reuse it:"
    log_warn "     railway:"
    log_warn "       project_id: \"$PROJECT_ID\""
    log_warn " Until you do, every deploy creates ANOTHER new project."
    log_warn "══════════════════════════════════════════════════════════"
    summary "> ⚠️ **New Railway project created.** Add \`project_id: \"$PROJECT_ID\"\` under \`railway:\` in \`.deploy/config.yml\`, or the next deploy makes another one."
  fi
  group_end

  # --- environment -------------------------------------------------------------
  group_start "Environment: $ENV_NAME"
  ENVIRONMENT_ID="$(rw_env_ensure "$PROJECT_ID" "$ENV_NAME")"
  [[ -z "$ENVIRONMENT_ID" ]] && die "could not create or find environment '$ENV_NAME'"
  log_ok "environment id: $ENVIRONMENT_ID"
  group_end

  # --- database ------------------------------------------------------------------
  DB_URI=""; DB_SERVICE_ID=""; DB_CREATED="false"

  if [[ "$DB_ENGINE" != "none" ]]; then
    group_start "Database ($DB_ENGINE)"
    local sname simage dbname dport existing pass_var user pass
    sname="$(cfg '.db.service_name' 'db')"
    simage="$(cfg '.db.service_image')"
    dbname="$(cfg '.db.database_name')"
    dport="$(engine_default_port)"

    existing="$(rw_service_find "$PROJECT_ID" "$sname")"
    [[ -z "$existing" ]] && DB_CREATED="true"

    DB_SERVICE_ID="$(rw_service_ensure_image "$PROJECT_ID" "$ENVIRONMENT_ID" "$sname" "$simage")"
    [[ -z "$DB_SERVICE_ID" ]] && die "could not create the database service"

    # Credentials are generated once and stored as service variables. On a
    # redeploy they are read back rather than rotated — rotating would orphan
    # the data already in the volume.
    user="railway"
    pass="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    pass_var="$(engine_password_var)"

    if [[ "$DB_CREATED" != "true" ]]; then
      local prev
      prev="$(rw_gql 'query($p:String!,$e:String!,$s:String!){ variables(projectId:$p, environmentId:$e, serviceId:$s) }' \
               "$(jq -nc --arg p "$PROJECT_ID" --arg e "$ENVIRONMENT_ID" --arg s "$DB_SERVICE_ID" '{p:$p,e:$e,s:$s}')" 2>/dev/null \
               | jq -r --arg v "$pass_var" '.variables[$v] // empty' || true)"
      [[ -n "$prev" ]] && { pass="$prev"; log_info "reusing the existing database credentials"; }
    fi
    mask "$pass"

    rw_vars_set "$PROJECT_ID" "$ENVIRONMENT_ID" "$DB_SERVICE_ID" \
                "$(engine_server_env "$user" "$pass")" true

    # Railway gives every service an internal DNS name inside the project:
    # <service>.railway.internal — https://docs.railway.com/guides/private-networking
    DB_URI="$(engine_build_uri "${sname}.railway.internal" "$dport" "$user" "$pass" "$dbname")"
    mask "$DB_URI"
    DB_USER="$user"

    log_ok "$sname → ${sname}.railway.internal:$dport/$dbname"
    group_end
  else
    log_info "db.engine is 'none' — no database provisioned"
  fi

  # --- app -------------------------------------------------------------------------
  group_start "Application service"
  : "${IMAGE_REF:?internal error: build step did not run}"
  # $PROJECT_NAME, not the raw config value — the config may be empty (name
  # derived from the repo), and compute_names has already validated it.
  APP_SERVICE_ID="$(rw_service_ensure_image "$PROJECT_ID" "$ENVIRONMENT_ID" "$PROJECT_NAME" "$IMAGE_REF")"
  [[ -z "$APP_SERVICE_ID" ]] && die "could not create the application service"
  log_ok "app service id: $APP_SERVICE_ID"
  group_end
}
