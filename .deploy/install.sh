#!/usr/bin/env bash
# =============================================================================
# install.sh — wire this folder into the repo it has been copied into.
# MACHINERY. Contains nothing project-specific.
#
#   bash .deploy/install.sh
#
# Copy .deploy/ into a project, run this once, and you are set up.
#
# NEVER overwrites your config.yml. Safe to re-run after upgrading the folder.
#
# The one thing that cannot live inside .deploy/: GitHub only looks for
# workflows in .github/workflows/, so the workflow file has to be placed there.
# This script does that copy, which is why it exists at all.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR
# shellcheck source=./lib/log.sh
source "$DEPLOY_DIR/lib/log.sh"

REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
cd "$REPO_ROOT"

log_step "Installing branch-deploy machinery into $(basename "$REPO_ROOT")"

# --- 1. the workflows ----------------------------------------------------------
group_start "1/5  GitHub Actions workflows"
mkdir -p .github/workflows
for WF_SRC in "$DEPLOY_DIR"/workflow/*.yml; do
  WF=".github/workflows/$(basename "$WF_SRC")"
  if [[ -f "$WF" ]] && ! diff -q "$WF_SRC" "$WF" >/dev/null 2>&1; then
    cp "$WF" "$WF.backup"
    log_warn "an existing $WF was different — saved a copy as $WF.backup"
  fi
  cp "$WF_SRC" "$WF"
  log_ok "$WF"
done
log_info "generic — they never need a per-project edit, not even for secrets"
group_end

# --- 2. dumps folder -------------------------------------------------------------
group_start "2/5  Dump folder"
mkdir -p "$DEPLOY_DIR/dumps"

# Dumps must never reach git: they are large, and every new one would stay in
# the history forever.
cat >"$DEPLOY_DIR/dumps/.gitignore" <<'EOF'
# Database dumps stay OUT of git — they are large, and git keeps every version
# forever, so each new dump would permanently grow the repository.
# Upload them instead:  bash .deploy/upload-dump.sh
*
!.gitignore
!README.md
EOF
log_ok ".deploy/dumps/  (contents git-ignored)"
group_end

# --- 3. config ---------------------------------------------------------------------
group_start "3/5  Configuration"
if [[ -f "$DEPLOY_DIR/config.yml" ]]; then
  log_ok "config.yml already exists — left untouched"
  NEEDS_CONFIG=false
else
  cp "$DEPLOY_DIR/config.example.yml" "$DEPLOY_DIR/config.yml"
  log_ok "created .deploy/config.yml from the template"
  log_info "every default already works — adjust only what this project needs"
  NEEDS_CONFIG=true
fi
group_end

# --- 4. self-test ---------------------------------------------------------------------
group_start "4/5  Self-test"
bash "$DEPLOY_DIR/selftest.sh" >/dev/null 2>&1 \
  && log_ok "machinery is intact and generic" \
  || log_warn "self-test reported problems — run: bash .deploy/selftest.sh"
group_end

# --- 5. what's left for you -------------------------------------------------------------
group_start "5/5  What you still need to do"
group_end

cat >&2 <<EOF

$(printf '\033[1m')Setup checklist$(printf '\033[0m')

  1. Adjust  .deploy/config.yml   — the only file you edit
     Using an AI assistant? Tell it:
       "Read .deploy/docs/AI-SETUP-PROMPT.md and do exactly what it says."
$( [[ "$NEEDS_CONFIG" == true ]] && echo "     Every default already works. Frontend-only app: copy the two-line
     recipe at the top of the file. Backend with a database: fill the db: block." \
                                 || echo "     Already present. Check it matches this project." )

  2. Add ONE repo secret
     Settings → Secrets and variables → Actions
     (first time? full click-by-click guide: .deploy/docs/SECRETS.md)

       RAILWAY_API_TOKEN            an ACCOUNT token from railway.com/account/tokens
                                    (a PROJECT token cannot create environments)

     Only when restoring a database dump from S3, also add:
       SEED_S3_ACCESS_KEY_ID        read-only key for the bucket holding the dump
       SEED_S3_SECRET_ACCESS_KEY

     ...plus every name you list under env.secrets in config.yml.
     No workflow edit needed — secrets are picked up automatically.

  3. Using a database dump? Put it where CI can reach it
       cp yourdump.archive.gz .deploy/dumps/
       bash .deploy/upload-dump.sh

  4. Check everything without touching anything
       bash .deploy/run.sh validate

  5. Commit, push, then click
       Actions → Deploy branch → Run workflow → pick your branch
       The live URL appears at the top of the run's summary page.

  Updating the kit later is one command:
       bash .deploy/update.sh     (keeps your config.yml and dumps)

  Full walkthrough:  .deploy/docs/COPY-TO-NEW-PROJECT.md

EOF

log_ok "install complete"
