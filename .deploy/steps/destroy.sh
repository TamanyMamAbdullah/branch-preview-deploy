#!/usr/bin/env bash
# =============================================================================
# steps/destroy.sh — delete this branch's environment, and its database with it.
# MACHINERY.
#
# Deleting the environment removes the app, the database and the volume in one
# operation, so nothing is left behind billing.
#
# Safe to run twice: an environment that is already gone is a success, not an
# error. This often runs as cleanup, where failing on "already deleted" would
# be pure noise.
# =============================================================================
# shellcheck shell=bash

step_destroy() {
  require_cmd curl jq
  group_start "Destroying $ENV_NAME"

  # --- guard rail --------------------------------------------------------------
  # The point of a destroy button is that it's easy to press. That is exactly
  # why the doors that matter need a lock.
  local protected
  while IFS= read -r protected; do
    [[ -z "$protected" ]] && continue
    [[ "$BRANCH" == "$protected" ]] && die \
"refusing to destroy '$BRANCH' — it is in destroy.protected_branches.
Remove it from config.yml if you really mean to, and think twice."
  done < <(cfg_list '.destroy.protected_branches')

  local project_id env_id
  project_id="$(cfg '.railway.project_id' '')"
  if [[ -z "$project_id" ]]; then
    # No pinned id — find the project by name, the same way deploy does. This
    # matters most for the automatic PR-close/branch-delete cleanup: it must
    # work even when nobody ever pasted the id back into config.yml.
    local pname found matches
    pname="$(cfg '.railway.project_name' '')"
    [[ -z "$pname" ]] && pname="$PROJECT_NAME"
    found="$(rw_project_find_by_name "$pname")"
    matches="$(printf '%s\n' "$found" | grep -c . || true)"
    if (( matches == 1 )); then
      project_id="$found"
      log_info "railway.project_id is empty — using project '$pname' ($project_id), found by name"
    elif (( matches > 1 )); then
      log_err "this account has $matches projects named '$pname' — destroy refuses to guess."
      log_err "Set railway.project_id in .deploy/config.yml to one of:"
      printf '%s\n' "$found" | sed 's/^/      /' >&2
      die "railway.project_id is required when several projects share a name"
    else
      log_warn "railway.project_id is empty and no project named '$pname' exists — nothing to destroy"
      summary "- Nothing to destroy: no \`railway.project_id\` set and no project named \`$pname\` found"
      group_end; return 0
    fi
  fi

  rw_project_exists "$project_id" \
    || die "railway.project_id '$project_id' not found, or this token cannot see it"

  env_id="$(rw_env_find "$project_id" "$ENV_NAME")"
  if [[ -z "$env_id" ]]; then
    log_ok "environment '$ENV_NAME' does not exist — nothing to destroy"
    summary "## 🧹 Nothing to destroy"
    summary ""
    summary "No environment named \`$ENV_NAME\` was found — already destroyed, or never created."
    group_end; return 0
  fi

  log_info "found environment $env_id"
  log_info "deleting it, its services, its database and its volume"
  rw_env_delete "$env_id" || die "could not delete environment '$ENV_NAME'"

  # Confirm, rather than trusting the mutation's return value.
  sleep 3
  if [[ -n "$(rw_env_find "$project_id" "$ENV_NAME")" ]]; then
    log_warn "Railway still lists the environment. Deletion is asynchronous, so this"
    log_warn "is usually just timing — check the dashboard shortly."
  else
    log_ok "environment '$ENV_NAME' is gone"
  fi
  group_end

  summary "## 🧹 Destroyed \`$ENV_NAME\`"
  summary ""
  summary "The app, its database and its volume were all removed. Nothing is billing."
  summary ""
  summary "Deploying this branch again builds a fresh environment and reloads the dump."
  log_ok "destroy complete"
}
