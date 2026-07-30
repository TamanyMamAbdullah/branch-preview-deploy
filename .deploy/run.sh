#!/usr/bin/env bash
# =============================================================================
# run.sh — the one entry point. Everything goes through here.
# MACHINERY. Contains nothing project-specific.
#
#   bash .deploy/run.sh deploy      build, provision, seed, deploy, report
#   bash .deploy/run.sh destroy     delete this branch's environment
#   bash .deploy/run.sh validate    check the config, touch nothing
#   bash .deploy/run.sh doctor      check the Railway token and API
#
# Every step runs in THIS process, so state passes between them as ordinary
# variables — no writing ids to files and reading them back, and one EXIT trap
# can guarantee the database's public port is closed no matter how the run ends.
# =============================================================================
set -euo pipefail
# -E so the ERR trap below fires inside functions too, not just at top level.
set -E

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR

# Everything relative in config.yml (dockerfile_path, build context) is
# relative to the PROJECT root, so run from there no matter where this was
# invoked from. Copied into a repo that is the folder above .deploy/; running
# as a GitHub Action the kit lives in the action's own checkout instead, so
# the action passes the project's location in DEPLOY_PROJECT_DIR.
cd "${DEPLOY_PROJECT_DIR:-$DEPLOY_DIR/..}"

# shellcheck source=./lib/log.sh
source "$DEPLOY_DIR/lib/log.sh"
# shellcheck source=./lib/config.sh
source "$DEPLOY_DIR/lib/config.sh"
# shellcheck source=./lib/secrets.sh
source "$DEPLOY_DIR/lib/secrets.sh"
# shellcheck source=./lib/railway.sh
source "$DEPLOY_DIR/lib/railway.sh"

for s in validate build smoke provision vars seed release destroy; do
  # shellcheck source=./steps/validate.sh
  source "$DEPLOY_DIR/steps/$s.sh"
done

ACTION="${1:-${DEPLOY_ACTION:-deploy}}"

# --- shared state -------------------------------------------------------------
PROJECT_ID=""; ENVIRONMENT_ID=""; APP_SERVICE_ID=""; DB_SERVICE_ID=""
DB_URI=""; DB_PUBLIC_URI=""; DB_USER="railway"; DB_CREATED="false"
IMAGE_REF=""; IMAGE_REUSED="false"
PUBLIC_URL=""; BASE_URL=""; HEALTH_URL=""; DEPLOYMENT_ID=""
APP_VARS='{}'
PROXY_OPENED="false"; SEED_WORKDIR=""; SMOKE_CONTAINER=""

# -----------------------------------------------------------------------------
# One trap for the whole run. However this ends — success, failure, cancellation
# — the temporary public port on the database gets closed and the downloaded
# dump is deleted. This is the single most important safety property here.
# -----------------------------------------------------------------------------
on_exit() {
  local rc=$?
  set +e
  [[ -n "$SEED_WORKDIR" && -d "$SEED_WORKDIR" ]] && rm -rf "$SEED_WORKDIR"
  [[ -n "$SMOKE_CONTAINER" ]] && docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1
  if [[ "$PROXY_OPENED" == "true" && "$(cfg '.db.keep_public_proxy' 'false')" != "true" ]]; then
    log_info "closing the database's temporary public port"
    rw_tcp_proxy_delete_all "$ENVIRONMENT_ID" "$DB_SERVICE_ID" \
      || log_warn "could not close it automatically — remove the TCP proxy in the Railway dashboard"
  fi
  cfg_cleanup
  exit $rc
}
trap on_exit EXIT

# -----------------------------------------------------------------------------
# Silent failures are forbidden. `set -e` kills the script on any unhandled
# failing command — including an assignment whose command substitution failed
# with its stderr suppressed, which once produced a run that stopped inside a
# log group with no message at all. This trap makes every such death name the
# command and the place it died, outside any collapsed group.
# -----------------------------------------------------------------------------
on_err() {
  local rc=$? where=""
  where="$(caller 0 2>/dev/null || caller 2>/dev/null || true)"
  while (( _GROUP_DEPTH > 0 )); do group_end; done
  log_err "unexpected failure (exit $rc) running: ${BASH_COMMAND:-?}"
  [[ -n "$where" ]] && log_err "at: $where   (line, function, file)"
}
trap on_err ERR

# =============================================================================
require_cmd jq
cfg_load "${DEPLOY_CONFIG:-}"

# The workflow's optional `seed` input overrides the dump for this run only.
# Patched into the in-memory config, so config.yml on disk is never rewritten.
if [[ -n "${DEPLOY_SEED_OVERRIDE:-}" ]]; then
  log_warn "seed override for this run only: $DEPLOY_SEED_OVERRIDE"
  tmp="$(mktemp)"
  jq --arg s "$DEPLOY_SEED_OVERRIDE" '.db.restore.seed_source=$s' "$CFG_JSON" >"$tmp" && mv "$tmp" "$CFG_JSON"
fi

compute_names
secrets_mask_all

DB_ENGINE="$(cfg '.db.engine' 'none')"
DB_SERVICE_IMAGE="$(cfg '.db.service_image' '')"
DB_NAME="$(cfg '.db.database_name' '')"
export DB_SERVICE_IMAGE DB_NAME

# Load the engine driver defensively. A typo'd db.engine would otherwise abort
# here with a raw "no such file" from bash, before the validator gets a chance
# to say what is actually wrong. Fall back to the no-op driver so validation
# runs and reports it properly.
if [[ -f "$DEPLOY_DIR/engines/${DB_ENGINE}.sh" ]]; then
  # shellcheck source=./engines/none.sh
  source "$DEPLOY_DIR/engines/${DB_ENGINE}.sh"
else
  log_err "db.engine is '$DB_ENGINE', but there is no driver at .deploy/engines/${DB_ENGINE}.sh"
  log_err "Supported: $(find "$DEPLOY_DIR/engines" -name '*.sh' -exec basename {} .sh \; | sort | tr '\n' ' ')"
  source "$DEPLOY_DIR/engines/none.sh"
  DB_ENGINE_INVALID=true
fi

log_info "machinery v$(tr -d '[:space:]' <"$DEPLOY_DIR/VERSION")  •  action: $ACTION"

case "$ACTION" in
  validate)
    step_validate
    ;;

  doctor)
    step_validate
    rw_selftest
    ;;

  destroy)
    step_validate
    step_destroy
    ;;

  deploy)
    step_validate
    rw_selftest            # prove the token works before building anything
    step_build
    step_smoke             # the image must answer HERE before Railway sees it
    step_provision
    step_vars
    step_seed
    step_migrate
    step_deploy
    step_health
    step_summary
    ;;

  *)
    die "unknown action '$ACTION' — expected: deploy | destroy | validate | doctor"
    ;;
esac
