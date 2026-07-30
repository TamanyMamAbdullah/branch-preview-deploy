#!/usr/bin/env bash
# =============================================================================
# update.sh — bring the machinery to the latest version. Your config survives.
# MACHINERY. Contains nothing project-specific.
#
#   bash .deploy/update.sh                    # from the kit's home (.deploy/SOURCE)
#   bash .deploy/update.sh <git-url>          # from a specific repository
#   bash .deploy/update.sh <local-path>       # from a checkout on this machine
#
# What it does:
#   1. fetches the latest kit (git clone --depth 1, using your normal git login)
#   2. replaces every machinery file in .deploy/
#   3. KEEPS your config.yml and everything in dumps/ untouched
#   4. re-runs install.sh, so .github/workflows/deploy.yml is refreshed too
#   5. warns if the new machinery expects a newer config format
#
# Afterwards: review `git diff`, commit, push. CI needs the files committed —
# that is why the kit lives as ordinary files in your repo rather than as a
# nested clone or submodule (either would leave CI with an empty folder or
# extra per-project setup).
# =============================================================================
set -euo pipefail

# --- self-update safety -------------------------------------------------------
# This script replaces the very file it is running from, which Windows in
# particular does not tolerate. So the first thing it does is copy itself to a
# temp file and re-run from there; the copy in .deploy/ is then just data.
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export DEPLOY_DIR
if [[ "${DEPLOY_UPDATE_RELAUNCHED:-}" != "1" ]]; then
  _self_copy="$(mktemp)"
  cp "${BASH_SOURCE[0]}" "$_self_copy"
  DEPLOY_UPDATE_RELAUNCHED=1 exec bash "$_self_copy" "$@"
fi

# shellcheck source=./lib/log.sh
source "$DEPLOY_DIR/lib/log.sh"

# --- where to update from -----------------------------------------------------
SRC="${1:-}"
if [[ -z "$SRC" && -f "$DEPLOY_DIR/SOURCE" ]]; then
  SRC="$(tr -d '[:space:]' <"$DEPLOY_DIR/SOURCE")"
fi
[[ -z "$SRC" ]] && die "no update source known.
Tell it where the kit lives (a git URL or a local checkout):
    bash .deploy/update.sh https://github.com/you/your-deploy-kit.git"

OLD_VERSION="$(tr -d '[:space:]' <"$DEPLOY_DIR/VERSION" 2>/dev/null || printf '?')"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- 1. fetch the latest kit --------------------------------------------------
group_start "Fetching the latest kit"
KIT=""
if [[ -d "$SRC" ]]; then
  # A local checkout: either the repo (kit in .deploy/) or the folder itself.
  for c in "$SRC/.deploy" "$SRC"; do
    [[ -f "$c/run.sh" && -f "$c/VERSION" ]] && { KIT="$c"; break; }
  done
  [[ -z "$KIT" ]] && die "no kit found at $SRC (expected run.sh and VERSION)"
  log_info "using local checkout: $KIT"
else
  require_cmd git
  log_info "git clone --depth 1 $SRC"
  git clone --quiet --depth 1 "$SRC" "$WORK/clone" || die \
"could not download the kit from $SRC
Check the URL, and that this machine's git login can read that repository."
  for c in "$WORK/clone/.deploy" "$WORK/clone"; do
    [[ -f "$c/run.sh" && -f "$c/VERSION" ]] && { KIT="$c"; break; }
  done
  [[ -z "$KIT" ]] && die "that repository does not contain the kit (no run.sh/VERSION found)"
fi

NEW_VERSION="$(tr -d '[:space:]' <"$KIT/VERSION")"
log_ok "fetched machinery v$NEW_VERSION (installed: v$OLD_VERSION)"
group_end

# --- 2. swap the machinery, keep what is yours --------------------------------
group_start "Updating .deploy/"
# Stage in temp first so the kit's own config template and dumps docs can be
# separated from YOUR config.yml and YOUR dumps before anything is touched.
cp -r "$KIT" "$WORK/kit"
rm -f "$WORK/kit/config.yml"          # never ship over the project's config

# Delete old machinery (removed files must actually disappear), keeping the
# two things that belong to this project: config.yml and dumps/.
find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 \
  ! -name 'config.yml' ! -name 'dumps' -exec rm -rf {} +

cp -r "$WORK/kit"/. "$DEPLOY_DIR"/
log_ok "machinery replaced (config.yml and dumps/ untouched)"
group_end

# --- 3. re-install: workflow copy, dumps gitignore, self-test -----------------
bash "$DEPLOY_DIR/install.sh"

# --- 4. config format handshake -----------------------------------------------
CONFIG_V="$(grep -E '^version:' "$DEPLOY_DIR/config.yml" 2>/dev/null | head -n1 | tr -dc '0-9' || true)"
if [[ -n "$CONFIG_V" && "$CONFIG_V" != "$NEW_VERSION" ]]; then
  log_warn "══════════════════════════════════════════════════════════════"
  log_warn " Your config.yml says 'version: $CONFIG_V' but the new machinery is"
  log_warn " v$NEW_VERSION. Deploys will refuse to run until you update it:"
  log_warn "   1. compare your config.yml with the new config.example.yml"
  log_warn "   2. adjust anything that changed, set 'version: $NEW_VERSION'"
  log_warn "══════════════════════════════════════════════════════════════"
fi

log ""
log_ok "update complete: v$OLD_VERSION → v$NEW_VERSION"
log_info "review it, then commit:  git diff  →  git add .deploy .github/workflows/deploy.yml"
