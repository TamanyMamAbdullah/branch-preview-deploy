#!/usr/bin/env bash
# =============================================================================
# steps/seed.sh — load the dump into the freshly-provisioned database.
# MACHINERY.
#
# The CI runner is OUTSIDE Railway's private network, so it cannot reach
# <service>.railway.internal. Therefore:
#
#   1. open a temporary public TCP port on the database  (tcpProxyCreate)
#   2. wait until the database actually accepts connections
#   3. download the dump
#   4. restore through the public address, in a container matching the engine
#   5. CLOSE THE PORT AGAIN                              (tcpProxyDelete)
#
# Step 5 runs from run.sh's EXIT trap, so the port closes even if the restore
# fails or the job is cancelled. Leaving a database exposed to the internet
# because something threw halfway through is not an acceptable failure mode.
#
# Steps 1–2 live in helpers (db_ensure_public_uri, db_wait_ready) because the
# migration step needs the exact same door: it also runs on the CI runner, so
# the private <service>.railway.internal address is just as unreachable there.
# =============================================================================
# shellcheck shell=bash

# -----------------------------------------------------------------------------
# db_ensure_public_uri — make the database reachable from THIS runner.
# Sets DB_PUBLIC_URI and flips PROXY_OPENED so run.sh's EXIT trap closes the
# port however the run ends. Safe to call twice; the second call is free.
# -----------------------------------------------------------------------------
db_ensure_public_uri() {
  [[ -n "$DB_PUBLIC_URI" ]] && return 0
  [[ "$DB_ENGINE" == "none" || -z "$DB_SERVICE_ID" ]] && \
    die "internal error: db_ensure_public_uri called with no database provisioned"

  local dport existing host port addr pass
  dport="$(engine_default_port)"

  existing="$(rw_tcp_proxy_list "$ENVIRONMENT_ID" "$DB_SERVICE_ID" | head -n1)"
  if [[ -n "$existing" ]]; then
    host="$(printf '%s' "$existing" | cut -f2)"
    port="$(printf '%s' "$existing" | cut -f3)"
    log_info "reusing an existing public port"
  else
    addr="$(rw_tcp_proxy_create "$ENVIRONMENT_ID" "$DB_SERVICE_ID" "$dport")" || die \
"could not open a public port on the database.
On an UNVERIFIED Railway Trial account outbound access and ports are restricted —
connect your GitHub account to Railway to lift that."
    host="${addr%:*}"; port="${addr##*:}"
  fi
  PROXY_OPENED="true"     # run.sh's trap reads this
  log_ok "temporary address: $host:$port"

  # The password is read back from the service rather than trusted from memory,
  # so this works even when provisioning reused an existing database.
  pass="$(rw_gql 'query($p:String!,$e:String!,$s:String!){ variables(projectId:$p, environmentId:$e, serviceId:$s) }' \
          "$(jq -nc --arg p "$PROJECT_ID" --arg e "$ENVIRONMENT_ID" --arg s "$DB_SERVICE_ID" '{p:$p,e:$e,s:$s}')" \
          | jq -r --arg v "$(engine_password_var)" '.variables[$v] // empty' || true)"
  [[ -z "$pass" ]] && die "could not read the database password back from Railway"
  mask "$pass"

  DB_PUBLIC_URI="$(engine_build_uri "$host" "$port" "${DB_USER:-railway}" "$pass" "$DB_NAME")"
  mask "$DB_PUBLIC_URI"
}

# -----------------------------------------------------------------------------
# db_wait_ready — poll until the database answers on the public address.
# -----------------------------------------------------------------------------
db_wait_ready() {
  local deadline=$(( SECONDS + 300 ))
  until engine_ping "$DB_PUBLIC_URI"; do
    (( SECONDS >= deadline )) && die \
"the database did not accept connections within 300s.
A brand-new service also has to pull its image first, so the first deploy of a
branch is the slowest. Check the '$(cfg '.db.service_name' db)' service in Railway."
    printf '.' >&2; sleep 5
  done
  printf '\n' >&2
  log_ok "database is accepting connections"
}

step_seed() {
  local tool; tool="$(cfg '.db.restore.tool' 'none')"
  if [[ "$DB_ENGINE" == "none" || "$tool" == "none" ]]; then
    log_info "seed: nothing to do (engine=$DB_ENGINE, tool=$tool)"
    return 0
  fi

  if [[ "$(cfg '.db.restore.mode' 'always')" == "once" && "${DB_CREATED:-false}" != "true" ]]; then
    log_info "seed: mode is 'once' and the database already exists — keeping its data"
    return 0
  fi

  require_cmd docker curl jq

  # --- 1+2. reach the database from here ---------------------------------------
  group_start "Opening a temporary public port on the database"
  db_ensure_public_uri
  group_end

  group_start "Waiting for the database"
  db_wait_ready
  group_end

  # --- 3. fetch the dump ----------------------------------------------------------
  group_start "Downloading the dump"
  local src work dest
  src="$(interp "$(cfg '.db.restore.seed_source')")"
  work="$(mktemp -d)"; SEED_WORKDIR="$work"      # run.sh's trap cleans this up

  if [[ "$src" == s3://* ]]; then
    require_cmd aws
    local kn sn endpoint region key sec
    kn="$(cfg '.db.restore.s3_key_id_env' 'SEED_S3_ACCESS_KEY_ID')"
    sn="$(cfg '.db.restore.s3_secret_env' 'SEED_S3_SECRET_ACCESS_KEY')"
    endpoint="$(cfg '.db.restore.s3_endpoint' '')"
    region="$(cfg '.db.restore.s3_region' 'us-east-1')"
    key="$(secret_get "$kn")"; sec="$(secret_get "$sn")"
    [[ -z "$key" || -z "$sec" ]] && die "secrets '$kn' / '$sn' are needed to download the dump"
    mask "$sec"

    dest="$work/$(basename "$src")"
    log_info "aws s3 cp $src   (endpoint: ${endpoint:-aws default})"

    local aws_args=(s3 cp "$src" "$dest" --only-show-errors)
    [[ -n "$endpoint" ]] && aws_args+=(--endpoint-url "$endpoint")

    # Credentials scoped to this one command; never written to the runner's
    # aws config. This key only ever needs read access.
    AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$sec" \
    AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true \
      aws "${aws_args[@]}" || die \
"could not download the dump from $src
Check the object exists at exactly that key, and that the seed key can read that bucket."
  else
    dest="$src"
    [[ -f "$dest" ]] || die \
"db.restore.seed_source '$dest' does not exist.
CI only has what is COMMITTED to git — an untracked local file will not be there.
Put dumps in .deploy/dumps/ and run: bash .deploy/upload-dump.sh"
  fi

  [[ -s "$dest" ]] || die "the dump is empty: $dest"

  # The restore runs inside the database's own image, and those images run as a
  # NON-ROOT user (mongodb, postgres). mktemp -d creates a 0700 directory owned
  # by the CI user, so that container user cannot even enter it — mongorestore
  # fails with "permission denied" on a file that is plainly there.
  chmod 755 "$(dirname "$dest")" 2>/dev/null || true
  chmod 644 "$dest"              2>/dev/null || true

  log_ok "dump ready: $(basename "$dest") ($(du -h "$dest" | cut -f1))"
  group_end

  # --- 4. restore ------------------------------------------------------------------
  group_start "Restoring into $(cfg '.db.database_name')"
  local extra=() rc=0
  mapfile -t extra < <(cfg_list '.db.restore.extra_args')

  set +e
  engine_restore "$DB_PUBLIC_URI" "$dest" "$(cfg '.db.restore.format' 'archive')" \
                 "$(cfg '.db.restore.gzip' 'false')" "$(cfg '.db.database_name')" "${extra[@]}"
  rc=$?
  set -e

  (( rc != 0 )) && die \
"restore failed (exit $rc).
Most common causes, in order:
  • 'permission denied' on the dump — the restore container runs as a non-root
    user and could not read the mounted file
  • the dump came from a NEWER server than db.service_image
  • the database name inside the dump differs from db.database_name
    (fix with db.restore.extra_args: [\"--nsFrom=old.*\", \"--nsTo=new.*\"])
  • the archive is not the format declared in db.restore.format"

  log_ok "restore finished"
  log_info "database now holds: $(engine_stats "$DB_PUBLIC_URI" "$(cfg '.db.database_name')")"
  group_end
}
