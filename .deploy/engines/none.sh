#!/usr/bin/env bash
# =============================================================================
# engines/none.sh — for projects with no database.
# MACHINERY.
#
# Every hook is a no-op. Having this file means the provisioning and seeding
# scripts don't need "if engine == none" branches scattered through them —
# they just call the driver and it politely does nothing.
# =============================================================================
# shellcheck shell=bash

engine_default_port() { printf '0'; }
engine_tools_image()  { printf 'alpine:3.20'; }
engine_server_env()   { printf '{}'; }
engine_password_var() { printf ''; }
engine_build_uri()    { printf ''; }
engine_ping()         { return 0; }
engine_restore()      { log_info "db.engine is 'none' — nothing to restore"; return 0; }
engine_stats()        { printf 'n/a'; }
