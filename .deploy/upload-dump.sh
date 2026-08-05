#!/usr/bin/env bash
# =============================================================================
# upload-dump.sh — send a local dump to the bucket CI reads it from.
# MACHINERY. Contains nothing project-specific.
#
#   bash .deploy/upload-dump.sh                 # the newest file in dumps/
#   bash .deploy/upload-dump.sh mydump.gz       # a specific one
#
# Uploading by hand in your storage provider's dashboard works just as well —
# this is a convenience, not a requirement. Either way the destination is the
# same, and it is DERIVED rather than typed:
#
#     s3://<db.restore.bucket>/<project.name>/<the file's own name>
#
# The file keeps its name, and that name is what you type into the deploy
# button's "dump" box to load it. Nothing anywhere holds a URL.
#
# This exists because of the most common trip-up: the dump sits on your laptop,
# CI clones from GitHub, and the file simply isn't there. A dump doesn't belong
# in git either — it's large, and git keeps every version forever, so each new
# dump would permanently grow the repository.
#
# Needs the seed credentials in your shell:
#   export SEED_S3_ACCESS_KEY_ID=...
#   export SEED_S3_SECRET_ACCESS_KEY=...
# Use a key that can WRITE to the bucket for this — the CI key only needs read.
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR
# shellcheck source=./lib/config.sh
source "$DEPLOY_DIR/lib/config.sh"
# shellcheck source=./lib/secrets.sh
source "$DEPLOY_DIR/lib/secrets.sh"

require_cmd aws jq yq
cfg_load "${DEPLOY_CONFIG:-}"

# The destination folder is derived from project.name, exactly as a deploy
# derives it. compute_names is what fills that in; without it this script and
# the deploy would disagree about where the dump lives.
compute_names
# shellcheck source=./steps/seed.sh
source "$DEPLOY_DIR/steps/seed.sh"     # seed_folder_url, the one definition of the convention

DUMPS="$DEPLOY_DIR/dumps"
mkdir -p "$DUMPS"

# --- pick the file --------------------------------------------------------------
FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  FILE="$(find "$DUMPS" -maxdepth 1 -type f ! -name '.gitignore' ! -name 'README.md' \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
  [[ -z "$FILE" ]] && die "no dump found in .deploy/dumps/
Copy one in first:   cp yourdump.archive.gz .deploy/dumps/"
  log_info "using the newest dump in dumps/: $(basename "$FILE")"
elif [[ ! -f "$FILE" && -f "$DUMPS/$FILE" ]]; then
  FILE="$DUMPS/$FILE"
fi
[[ -f "$FILE" ]] || die "no such file: $FILE"

# --- where it goes ---------------------------------------------------------------
# The file keeps its own name, in this project's folder. That name IS what you
# type into the deploy button's "dump" box later, so what you upload and what
# you pick can never drift apart.
FOLDER="$(seed_folder_url)"
[[ -z "$FOLDER" ]] && die \
"db.restore.bucket is not set in the config — there is nowhere to upload to.
Set it to the bucket that holds every project's dumps, e.g.

  db:
    restore:
      bucket: my-team-seeds

This project's dumps then live in a folder named after it, automatically."

SEED_SOURCE="${FOLDER}$(basename "$FILE")"

ENDPOINT="$(cfg '.db.restore.s3_endpoint' '')"
REGION="$(cfg '.db.restore.s3_region' 'us-east-1')"
KEY_ENV="$(cfg '.db.restore.s3_key_id_env' 'SEED_S3_ACCESS_KEY_ID')"
SEC_ENV="$(cfg '.db.restore.s3_secret_env' 'SEED_S3_SECRET_ACCESS_KEY')"

KEY="$(secret_get "$KEY_ENV")"; SEC="$(secret_get "$SEC_ENV")"
[[ -z "$KEY" || -z "$SEC" ]] && die \
"credentials not found. Set them in your shell first:
    export $KEY_ENV=...
    export $SEC_ENV=...
The key needs WRITE access to upload. The one CI uses only needs read."

# --- sanity-check the file ---------------------------------------------------------
group_start "Checking the dump"
SIZE="$(du -h "$FILE" | cut -f1)"
log_info "file : $(basename "$FILE")  ($SIZE)"
log_info "→    : $SEED_SOURCE"

# A mongodump archive starts with the magic number 0x8199e26d. Verifying it here
# means a wrong file is caught now rather than mid-restore in CI.
if [[ "$(cfg '.db.restore.tool' '')" == "mongorestore" && "$(cfg '.db.restore.format' '')" == "archive" ]]; then
  magic="$( { [[ "$(cfg '.db.restore.gzip' false)" == "true" ]] && gunzip -c "$FILE" || cat "$FILE"; } 2>/dev/null \
            | head -c 4 | od -An -tx1 | tr -d ' \n' || true)"
  if [[ "$magic" == "6de29981" ]]; then
    log_ok "valid mongodump archive"
    server="$( { [[ "$(cfg '.db.restore.gzip' false)" == "true" ]] && gunzip -c "$FILE" || cat "$FILE"; } 2>/dev/null \
               | head -c 8192 | tr -c '[:print:]' '\n' | grep -A1 -m1 'server_version' | tail -1 || true)"
    [[ -n "$server" ]] && {
      log_info "made by MongoDB server $server"
      log_warn "db.service_image is '$(cfg '.db.service_image')' — it must be at least this version"
    }
  else
    log_warn "this does not look like a mongodump archive (magic: ${magic:-none})."
    log_warn "Check db.restore.format and db.restore.gzip match the file."
  fi
fi
group_end

# --- upload -----------------------------------------------------------------------
group_start "Uploading"
mask "$SEC"
args=(s3 cp "$FILE" "$SEED_SOURCE" --only-show-errors)
[[ -n "$ENDPOINT" ]] && args+=(--endpoint-url "$ENDPOINT")

AWS_ACCESS_KEY_ID="$KEY" AWS_SECRET_ACCESS_KEY="$SEC" \
AWS_DEFAULT_REGION="$REGION" AWS_EC2_METADATA_DISABLED=true \
  aws "${args[@]}" || die "upload failed — check the key can WRITE to that bucket"
group_end

log_ok "uploaded to $SEED_SOURCE"
log_info "to use it: Actions → Deploy branch → Run workflow, and put"
log_info "           $(basename "$FILE")"
log_info "           in the 'dump' box. Leaving that box blank starts empty."
