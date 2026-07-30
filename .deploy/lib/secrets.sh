#!/usr/bin/env bash
# =============================================================================
# secrets.sh — read a secret by name, wherever it happens to live.
# MACHINERY. Contains nothing project-specific.
#
# This is what removes the per-project workflow edit.
#
# GitHub does not expose secrets to a script automatically — normally every
# single one has to be listed in the workflow's `env:` block by hand, which
# means onboarding a project involves editing the workflow, and forgetting one
# is a confusing runtime failure.
#
# Instead the workflow passes the whole secrets context ONCE:
#
#     env:
#       DEPLOY_SECRETS_JSON: ${{ toJSON(secrets) }}
#
# so config.yml can name any secret it likes and it just works, with no
# workflow change ever. GitHub still masks every value in the logs.
#
# Falls back to real environment variables when that JSON is absent, so the
# same scripts run locally.
# =============================================================================
# shellcheck shell=bash

# secret_get <NAME> -> value on stdout, empty if unset
secret_get() {
  local name="$1" v=""
  if [[ -n "${DEPLOY_SECRETS_JSON:-}" ]]; then
    v="$(printf '%s' "$DEPLOY_SECRETS_JSON" | jq -r --arg k "$name" '.[$k] // empty' 2>/dev/null || true)"
  fi
  [[ -z "$v" ]] && v="${!name:-}"
  printf '%s' "$v"
}

# secret_has <NAME> -> 0 when the secret is present and non-empty
secret_has() { [[ -n "$(secret_get "$1")" ]]; }

# secret_names -> every secret name available (for diagnostics only; never values)
secret_names() {
  [[ -n "${DEPLOY_SECRETS_JSON:-}" ]] || return 0
  printf '%s' "$DEPLOY_SECRETS_JSON" | jq -r 'keys_unsorted[]' 2>/dev/null || true
}

# Registers every supplied secret with the log masker up front, so a value
# cannot leak even through an unexpected code path.
secrets_mask_all() {
  local n v
  while IFS= read -r n; do
    [[ -z "$n" || "$n" == "github_token" ]] && continue
    v="$(secret_get "$n")"
    mask "$v"
  done < <(secret_names)
}
