#!/usr/bin/env bash
# =============================================================================
# engines/postgres.sh — PostgreSQL driver.
# MACHINERY. Contains nothing project-specific.
#
# Same shape as the mongo driver: the database is an ordinary container built
# from a pinned image, and client tools run from that same image so versions
# always match.
#
# Not exercised by the first project through this pipeline, which uses MongoDB.
# Written so the next project that needs Postgres changes one line of config
# rather than any code.
# =============================================================================
# shellcheck shell=bash

engine_default_port() { printf '5432'; }
engine_tools_image()  { printf '%s' "${DB_SERVICE_IMAGE:-postgres:16}"; }

# engine_server_env <user> <pass> -> JSON env map for the database container
engine_server_env() {
  jq -nc --arg u "$1" --arg p "$2" \
    '{POSTGRES_USER:$u, POSTGRES_PASSWORD:$p, POSTGRES_DB:($ENV.DB_NAME // "app")}'
}

engine_password_var() { printf 'POSTGRES_PASSWORD'; }

engine_build_uri() {
  local host="$1" port="$2" user="$3" pass="$4" db="$5"
  printf 'postgresql://%s:%s@%s:%s/%s' \
    "$(url_enc "$user")" "$(url_enc "$pass")" "$host" "$port" "$db"
}

engine_ping() {
  docker run --rm --network host -e PGCONNECT_TIMEOUT=5 "$(engine_tools_image)" \
    psql "$1" -tAc 'SELECT 1' >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# engine_restore <uri> <dump-path> <format> <gzip> <dbname> [extra...]
#
#   custom  -> pg_restore --clean --if-exists --no-owner --no-acl
#              (--no-owner/--no-acl because the preview role differs from
#               whichever role produced the dump)
#   plain   -> psql -v ON_ERROR_STOP=1, so a failure mid-script is a failure,
#              not a half-restored database reported as success
# -----------------------------------------------------------------------------
engine_restore() {
  local uri="$1" dump="$2" format="$3" gz="$4" db="$5"; shift 5
  local dir base
  dir="$(cd "$(dirname "$dump")" && pwd)"
  base="$(basename "$dump")"

  case "$format" in
    custom|directory)
      local args=(--dbname="$uri" --clean --if-exists --no-owner --no-acl --single-transaction)
      [[ "$format" == directory ]] && args+=(--format=d "/dump/$base") || args+=("/dump/$base")
      (( $# )) && args+=("$@")
      log_info "restoring with pg_restore ($(engine_tools_image))"
      # --user 0:0 — see the note in engines/mongo.sh: the dump is written by
      # the CI user into a private temp dir the image's user cannot read.
      docker run --rm --network host --user 0:0 -v "$dir:/dump:ro" "$(engine_tools_image)" pg_restore "${args[@]}"
      ;;
    plain)
      log_info "restoring with psql ($(engine_tools_image))"
      if [[ "$gz" == "true" ]]; then
        docker run --rm -i --network host --user 0:0 -v "$dir:/dump:ro" "$(engine_tools_image)" \
          sh -c "gunzip -c /dump/$base | psql '$uri' -v ON_ERROR_STOP=1"
      else
        docker run --rm --network host --user 0:0 -v "$dir:/dump:ro" "$(engine_tools_image)" \
          psql "$uri" -v ON_ERROR_STOP=1 -f "/dump/$base"
      fi
      ;;
    *) die "postgres engine: db.restore.format must be 'custom', 'directory' or 'plain' — got '$format'" ;;
  esac
}

engine_stats() {
  docker run --rm --network host "$(engine_tools_image)" \
    psql "$1" -tAc "SELECT count(*)||' tables' FROM information_schema.tables WHERE table_schema='public'" \
    2>/dev/null | tr -d '[:space:]' || printf 'unavailable'
}
