#!/usr/bin/env bash
# =============================================================================
# steps/release.sh — migrate, deploy, wait for health, publish the URL.
# MACHINERY.
# =============================================================================
# shellcheck shell=bash

# -----------------------------------------------------------------------------
# step_migrate
#
# An empty db.migrate.command is a DELIBERATE, SUPPORTED skip, not an oversight.
# Plenty of projects have no migration system at all. It says so in the log, so
# nobody is left wondering whether a migration ran and quietly failed.
# -----------------------------------------------------------------------------
step_migrate() {
  local cmd; cmd="$(cfg '.db.migrate.command' '')"

  if [[ -z "$cmd" ]]; then
    log_info "migrate: skipped (no command configured — this project has none)"
    summary "- **Migrations:** skipped — none configured"
    return 0
  fi
  if [[ "$(cfg '.db.migrate.run_in' 'app_image')" == "none" ]]; then
    log_info "migrate: skipped (db.migrate.run_in is 'none')"
    return 0
  fi

  group_start "Running migrations"
  require_cmd docker
  [[ "$DB_ENGINE" == "none" || -z "${DB_URI:-}" ]] && \
    die "db.migrate.command is set, but there is no database to migrate (db.engine: $DB_ENGINE)"
  log_info "command: $cmd"

  # The migration runs HERE, on the CI runner, which sits outside Railway's
  # private network — the app's internal connection string cannot work from
  # here. Go through the same temporary public door the seeding step uses;
  # run.sh's EXIT trap closes it whatever happens.
  db_ensure_public_uri
  db_wait_ready

  # Runs in the app's own image, so the migration tool and its dependencies are
  # exactly the ones the app ships with.
  local rc=0
  set +e
  docker run --rm --network host -e "$(cfg '.db.connection_env')=${DB_PUBLIC_URI}" "$IMAGE_REF" sh -lc "$cmd"
  rc=$?
  set -e
  (( rc != 0 )) && die "migration command failed (exit $rc)"

  log_ok "migrations applied"
  group_end
}

# -----------------------------------------------------------------------------
# step_deploy — point the service at the image and start it.
# -----------------------------------------------------------------------------
step_deploy() {
  group_start "Deploying"
  local health replicas sleep_app=""
  # interp so a per-branch prefix works: /${BRANCH_SLUG}/health
  health="$(interp "$(cfg '.runtime.health_check_path' '')")"
  replicas=""
  if [[ "$STAGE" == "preview" ]]; then
    replicas="$(cfg '.preview_defaults.replicas' '')"
    sleep_app="$(cfg '.preview_defaults.auto_sleep' '')"
  fi

  log_info "image        : $IMAGE_REF"
  log_info "health check : ${health:-<none>}"
  [[ -n "$replicas"  ]] && log_info "replicas     : $replicas"
  [[ "$sleep_app" == "true" ]] && log_info "auto-sleep   : yes — enabled AFTER the app reports healthy"

  # A private image needs pull credentials on the service BEFORE the image is
  # updated — the image change itself can start a deployment, and that deploy
  # must already be able to authenticate against the registry.
  if [[ "$(cfg '.build.registry_visibility' 'public')" == "private" ]]; then
    local rpe rpass ruser
    rpe="$(cfg '.build.registry_password_env' 'GHCR_PULL_TOKEN')"
    rpass="$(secret_get "$rpe")"
    [[ -z "$rpass" ]] && die "secret '$rpe' is not set — Railway needs it to pull the private image.
Create a GitHub token (classic, read:packages scope) at github.com/settings/tokens
and add it as that repo secret. The same token works in every repo you own."
    mask "$rpass"

    ruser="$(cfg '.build.registry_username' '')"
    [[ -z "$ruser" ]] && { ruser="${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY:-}}"; ruser="${ruser%%/*}"; }
    [[ -z "$ruser" ]] && die "build.registry_username is empty and the repository owner is unknown —
set build.registry_username in .deploy/config.yml when running outside GitHub Actions"

    log_info "registry     : private — handing Railway the pull token (user: $ruser)"
    rw_service_set_registry_creds "$APP_SERVICE_ID" "$ENVIRONMENT_ID" "$ruser" "$rpass" \
      || die "could not apply the registry credentials to the service"
  fi

  # Setting the image is what makes this a new deployment. healthcheckPath goes
  # in the same call so Railway gates the rollout on the app being healthy.
  # sleepApplication deliberately does NOT: enabling it during the rollout left
  # Railway's own healthcheck probing a service its proxy already treated as
  # asleep — "service unavailable" on every attempt while the container ran
  # fine. It is applied in step_health, after the app has proven healthy.
  rw_service_update "$APP_SERVICE_ID" "$ENVIRONMENT_ID" "$IMAGE_REF" "$health" "$replicas" "" \
    || die "could not update the service configuration"

  # A changed image usually triggers a deploy on its own. Redeploy explicitly
  # for the case where the image reference is unchanged (re-running the same
  # commit), which would otherwise keep the old container and the old variables.
  log_info "triggering deployment"
  rw_deploy_trigger "$APP_SERVICE_ID" "$ENVIRONMENT_ID" \
    || log_warn "explicit redeploy failed — the image change may already have started one"

  log_ok "deployment requested"
  group_end
}

# -----------------------------------------------------------------------------
# step_health — get a URL, then confirm the app really answers on it.
#
# Two independent checks, because either alone can lie: Railway's deployment
# status knows about crashes and image-pull failures; an actual HTTP request
# knows whether it truly serves.
# -----------------------------------------------------------------------------
step_health() {
  group_start "Public URL"
  local domain
  # The target port is passed explicitly — it is the same runtime.port the
  # vars step handed the app. Leaving it to Railway's detection once routed
  # the domain at the base image's EXPOSE port instead: 502 on every request
  # while the container ran fine.
  domain="$(rw_domain_ensure "$ENVIRONMENT_ID" "$APP_SERVICE_ID" "$(cfg '.runtime.port' '8080')")" \
    || die "could not create a public domain"
  [[ -z "$domain" || "$domain" == "null" ]] && die "Railway did not return a domain"
  PUBLIC_URL="https://${domain}"
  log_ok "$PUBLIC_URL"
  group_end

  group_start "Waiting for the app to become healthy"
  local path timeout deadline last="" code=000 status did
  path="$(interp "$(cfg '.runtime.health_check_path' '/')")"
  timeout="$(cfg '.runtime.health_check_timeout' '300')"
  HEALTH_URL="${PUBLIC_URL}${path}"
  log_info "polling $HEALTH_URL (up to ${timeout}s)"

  deadline=$(( SECONDS + timeout ))
  while :; do
    read -r did status < <(rw_deploy_latest "$PROJECT_ID" "$APP_SERVICE_ID" "$ENVIRONMENT_ID") || true
    DEPLOYMENT_ID="${did:-}"
    if [[ -n "${status:-}" && "$status" != "$last" ]]; then
      log_info "deployment status: $status"; last="$status"
    fi

    case "${status:-}" in
      FAILED|CRASHED|REMOVED)
        group_end; _dump_failure "the deployment reported status: $status" "$path"
        die "deployment failed" ;;
    esac

    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" 2>/dev/null || echo 000)"
    [[ "$code" =~ ^2[0-9][0-9]$ ]] && break

    if (( SECONDS >= deadline )); then
      group_end
      _dump_failure "no 2xx from $HEALTH_URL within ${timeout}s (last HTTP $code, status ${status:-unknown})" "$path"
      die "health check timed out"
    fi
    sleep 5
  done
  group_end
  log_ok "healthy — $HEALTH_URL returned HTTP $code"

  # Only now, with a proven-healthy app, is auto-sleep switched on.
  if [[ "$STAGE" == "preview" && "$(cfg '.preview_defaults.auto_sleep' '')" == "true" ]]; then
    if rw_service_update "$APP_SERVICE_ID" "$ENVIRONMENT_ID" "" "" "" "true"; then
      log_ok "auto-sleep enabled — this preview scales to zero when idle"
    else
      log_warn "could not enable auto-sleep — the preview will keep running while idle"
    fi
  fi

  BASE_URL="${PUBLIC_URL}$(_resolve_base_path)"
  emit deploy_url "$PUBLIC_URL"
  emit base_url   "$BASE_URL"
  emit health_url "$HEALTH_URL"
  notice "Base URL" "$BASE_URL"
}

# -----------------------------------------------------------------------------
# _resolve_base_path — the prefix every app route sits behind, e.g. /api/v1.
#
# The domain alone is rarely what anyone wants to paste into Postman: hit the
# bare host on an app with a route prefix and you get a 404, which reads like a
# broken deploy when it is nothing of the sort.
#
# Two ways to declare it, so nothing has to be written twice:
#   runtime.base_path      a literal, for apps where it is fixed
#   runtime.base_path_env  the name of the variable that already carries it
#                          — resolved from the variables actually applied, so
#                          it honours stage and per-branch overrides
# Neither set = routes live at the root, and this returns nothing.
# -----------------------------------------------------------------------------
_resolve_base_path() {
  local p name vars
  # interp so base_path can be derived, e.g. /${BRANCH_SLUG}
  p="$(interp "$(cfg '.runtime.base_path' '')")"

  if [[ -z "$p" ]]; then
    name="$(cfg '.runtime.base_path_env' '')"
    if [[ -n "$name" ]]; then
      vars="${APP_VARS:-}"; [[ -z "$vars" ]] && vars='{}'
      p="$(printf '%s' "$vars" | jq -r --arg k "$name" '.[$k] // empty' 2>/dev/null || true)"
      [[ -z "$p" ]] && log_warn \
        "runtime.base_path_env names '$name', but no such variable was applied — assuming routes are at the root"
    fi
  fi

  p="${p%/}"                        # drop a trailing slash
  [[ -n "$p" && "$p" != /* ]] && p="/$p"
  printf '%s' "$p"
}

# Dump the RAW logs, both streams. Apps commonly crash before their logger
# starts — a missing environment variable throwing during module import, say —
# which leaves a bare stack trace and nothing structured at all. A pipeline that
# only reads structured logs reports "failed" and explains nothing.
_dump_failure() {
  local why="$1" path="$2"
  log_err "$why"
  if [[ -n "${DEPLOYMENT_ID:-}" ]]; then
    group_start "Raw deployment logs (build + runtime)"
    rw_deploy_logs "$DEPLOYMENT_ID" 300 | tail -n 200 | sed 's/^/    /' >&2 \
      || log_warn "could not retrieve logs"
    group_end
  fi
  log_err ""
  log_err "Worth checking, most likely first:"
  log_err "  • a required variable is missing — many apps throw a bare stack trace"
  log_err "    before logging starts, so read the FIRST lines of the runtime log"
  log_err "  • the app isn't listening on the port Railway injected ($(cfg '.runtime.port_env' PORT))"
  log_err "  • it bound to 127.0.0.1 rather than 0.0.0.0, so nothing outside reaches it"
  log_err "  • the health path is wrong — this checked '${path}'"
  log_err "  • the database connection string isn't reachable from the app"
}

# -----------------------------------------------------------------------------
# step_summary — write the result to the workflow summary panel.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# summary_seeding_help — print the exact, filled-in command for putting a dump
# where this project reads them from.
#
# This exists because of ACTION MODE. There the project has no .deploy/ folder,
# so `bash .deploy/upload-dump.sh` is not sitting there to run — and the bucket,
# the endpoint and the project's folder are all things the run already knows and
# the user would otherwise have to reassemble by hand. Printing the finished
# command needs no script, no clone and no tool beyond the AWS CLI.
#
# Doubly worth it because the storage GUIs fall over on real dumps: a browser
# sends the file as one request, while `aws s3 cp` splits anything sizeable into
# parts and retries them. IDrive e2's own upload dialog says as much.
# -----------------------------------------------------------------------------
summary_seeding_help() {
  [[ "$DB_ENGINE" == "none" ]] && return 0
  [[ "$(cfg '.db.restore.tool' 'none')" == "none" ]] && return 0

  local folder ep
  folder="$(seed_folder_url)"
  [[ -z "$folder" ]] && return 0          # no bucket configured — nothing to say
  ep="$(cfg '.db.restore.s3_endpoint' '')"

  summary "<details><summary><b>📦 Load a dump into the next deploy</b></summary>"
  summary ""
  summary "This project's dumps live in \`$folder\` — one folder per project, named"
  summary "automatically. Put a file there from your machine:"
  summary ""
  summary '```bash'
  if [[ -n "$ep" ]]; then
    summary "aws s3 cp yourdump.archive.gz ${folder}yourdump.archive.gz \\"
    summary "  --endpoint-url $ep"
  else
    summary "aws s3 cp yourdump.archive.gz ${folder}yourdump.archive.gz"
  fi
  summary '```'
  summary ""
  summary "S3 has no real folders, so that path creates itself — there is nothing to"
  summary "set up in the dashboard first. Use the CLI rather than the web uploader:"
  summary "it splits large files into parts and retries them, which is why a browser"
  summary "upload of a big dump tends to fail."
  summary ""
  summary "Then run this workflow again and put **\`yourdump.archive.gz\`** in the"
  summary "**dump** box. Leaving that box blank keeps the database empty."
  summary "</details>"
  summary ""
}

step_summary() {
  summary "## 🚀 \`$BRANCH\` is live"
  summary ""
  summary "### ${BASE_URL:-$PUBLIC_URL}"
  summary ""

  # Spelled out as a variable assignment because that is how it gets used:
  # pasted straight into Postman/Insomnia as {{baseUrl}}.
  summary '```'
  summary "baseUrl = ${BASE_URL:-$PUBLIC_URL}"
  summary '```'
  summary ""

  summary "| | |"
  summary "|---|---|"
  [[ -n "$BASE_URL" && "$BASE_URL" != "$PUBLIC_URL" ]] \
    && summary "| Host | \`$PUBLIC_URL\` |"
  summary "| Environment | \`$ENV_NAME\` |"
  summary "| Branch | \`$BRANCH\` |"
  summary "| Commit | \`$SHA7\` |"
  summary "| Image | \`${IMAGE_REF:-?}\` (reused: ${IMAGE_REUSED:-false}) |"
  summary "| Health | [\`$(interp "$(cfg '.runtime.health_check_path' /)")\`](${HEALTH_URL:-$PUBLIC_URL}) |"
  if [[ "$DB_ENGINE" != "none" ]]; then
    if [[ -n "${SEED_SOURCE:-}" ]]; then
      summary "| Database | \`$DB_ENGINE\` — fresh, seeded from \`$(basename "$SEED_SOURCE")\` |"
    else
      summary "| Database | \`$DB_ENGINE\` — fresh and **empty** (no dump chosen) |"
    fi
  fi
  summary ""

  summary_seeding_help


  if [[ "$STAGE" == "preview" ]]; then
    summary "---"
    summary ""
    summary "**Destroy this when you're done with the branch.** Run the workflow again"
    summary "with **action: destroy**. A preview left running keeps costing money, and"
    summary "on a Trial or Free plan a couple of forgotten previews will use up the"
    summary "credit within days."
    summary ""
    if [[ -n "${SEED_SOURCE:-}" ]]; then
      summary "Re-deploying reloads the database from the dump, so anything entered by"
      summary "hand in this preview will be gone."
    elif [[ "$DB_ENGINE" != "none" ]]; then
      summary "Re-deploying rebuilds the database empty again, so anything entered by"
      summary "hand in this preview will be gone."
    fi
  fi

  log_ok "summary written"
  log ""
  log "  base URL   ${BASE_URL:-$PUBLIC_URL}"
  log "  health     ${HEALTH_URL:-$PUBLIC_URL}"
  log ""
}
