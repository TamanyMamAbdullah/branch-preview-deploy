#!/usr/bin/env bash
# =============================================================================
# engines/mongo.sh — MongoDB driver.
# MACHINERY. Contains nothing project-specific.
#
# Railway's "MongoDB" is not a managed database — it is the official `mongo`
# Docker image run as an ordinary container
# (https://docs.railway.com/databases/mongodb). So we create it ourselves from
# a version we pin in config, set the root credentials, and build the
# connection string. Deterministic, and identical in shape to the postgres
# driver.
#
# Verified: the mongo:8 image ships mongorestore/mongodump/mongosh
# (tools 100.17.0), so restores run in the same image as the server.
# =============================================================================
# shellcheck shell=bash

engine_default_port() { printf '27017'; }

# Image used to run client tools. Same image as the server, so the tool version
# always matches the engine version.
engine_tools_image() { printf '%s' "${DB_SERVICE_IMAGE:-mongo:8}"; }

# engine_server_env <user> <pass> -> JSON env map for the database container
engine_server_env() {
  jq -nc --arg u "$1" --arg p "$2" \
    '{MONGO_INITDB_ROOT_USERNAME:$u, MONGO_INITDB_ROOT_PASSWORD:$p}'
}

# engine_password_var — which service variable holds the root password. Lets the
# generic scripts read credentials back on a redeploy without knowing anything
# about this engine.
engine_password_var() { printf 'MONGO_INITDB_ROOT_PASSWORD'; }

# engine_build_uri <host> <port> <user> <pass> <dbname>
# authSource=admin because the root user is created in the admin database.
engine_build_uri() {
  local host="$1" port="$2" user="$3" pass="$4" db="$5"
  printf 'mongodb://%s:%s@%s:%s/%s?authSource=admin' \
    "$(url_enc "$user")" "$(url_enc "$pass")" "$host" "$port" "$db"
}

# engine_ping <uri> — 0 when the server answers.
engine_ping() {
  docker run --rm --network host "$(engine_tools_image)" \
    mongosh "$1" --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# engine_restore <uri> <dump-path> <format> <gzip:true|false> <dbname> [extra...]
#
# Flags confirmed against https://www.mongodb.com/docs/database-tools/mongorestore/
#   --archive=<file>  restore a `mongodump --archive` file
#   --gzip            required when the archive was gzip-compressed
#   --drop            drop each collection before restoring it, so re-seeding
#                     is repeatable rather than merging into what's there
#
# Index definitions travel inside a mongodump archive, so this recreates them.
# That matters for apps that refuse to create their own indexes at runtime.
# -----------------------------------------------------------------------------
engine_restore() {
  local uri="$1" dump="$2" format="$3" gz="$4" db="$5"; shift 5
  local dir base
  dir="$(cd "$(dirname "$dump")" && pwd)"
  base="$(basename "$dump")"

  local args=(--uri="$uri" --drop --numParallelCollections=1)
  case "$format" in
    archive)   args+=(--archive="/dump/$base") ;;
    directory) args+=(--dir="/dump/$base") ;;
    *) die "mongo engine: db.restore.format must be 'archive' or 'directory' — got '$format'" ;;
  esac
  [[ "$gz" == "true" ]] && args+=(--gzip)
  (( $# )) && args+=("$@")

  log_info "restoring with mongorestore ($(engine_tools_image))"
  # --network host  so the container can reach Railway's public TCP proxy.
  # --user 0:0      the dump is written by the CI user into a private temp dir;
  #                 without this the container user can hit "permission denied"
  #                 on a file that is plainly mounted. Throwaway container, one
  #                 read-only mount, so root here costs nothing.
  docker run --rm --network host --user 0:0 \
    -v "$dir:/dump:ro" \
    "$(engine_tools_image)" \
    mongorestore "${args[@]}"
}

# engine_stats <uri> <dbname> — a sanity read after restoring, so a "successful"
# restore that produced an empty database is caught here rather than surfacing
# later as a confusing application error.
engine_stats() {
  docker run --rm --network host "$(engine_tools_image)" \
    mongosh "$1" --quiet --eval '
      const c = db.getSiblingDB("'"$2"'").getCollectionNames();
      let n = 0;
      for (const name of c) n += db.getSiblingDB("'"$2"'").getCollection(name).estimatedDocumentCount();
      print(c.length + " collections, ~" + n + " documents");
    ' 2>/dev/null || printf 'unavailable'
}
