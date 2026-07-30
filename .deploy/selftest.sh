#!/usr/bin/env bash
# =============================================================================
# selftest.sh — prove .deploy/ is still generic, complete, and parses.
# MACHINERY.
#
# The promise of this folder is that it is byte-identical in every project and
# config.yml is the only per-project file. That promise decays the moment
# someone hardcodes a bucket name "just for now". This fails the build when it
# happens.
#
#   bash .deploy/selftest.sh
# =============================================================================
set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR
# shellcheck source=./lib/log.sh
source "$DEPLOY_DIR/lib/log.sh"

FAILURES=0
fail() { log_err "$*"; FAILURES=$((FAILURES + 1)); }

# =============================================================================
group_start "1. Every script parses"
while IFS= read -r f; do
  bash -n "$f" 2>/tmp/synerr \
    && log_ok "${f#"$DEPLOY_DIR"/}" \
    || { fail "$f has a syntax error:"; sed 's/^/      /' /tmp/synerr >&2; }
done < <(find "$DEPLOY_DIR" -name '*.sh' | sort)
group_end

# =============================================================================
group_start "2. The folder is complete"
for required in \
  run.sh install.sh selftest.sh upload-dump.sh update.sh VERSION config.example.yml \
  .gitattributes workflow/deploy.yml workflow/cleanup.yml \
  presets/frontend-static.Dockerfile \
  lib/log.sh lib/config.sh lib/secrets.sh lib/railway.sh \
  steps/validate.sh steps/build.sh steps/smoke.sh steps/provision.sh \
  steps/vars.sh steps/seed.sh steps/release.sh steps/destroy.sh \
  engines/mongo.sh engines/postgres.sh engines/none.sh \
  docs/README.md docs/COPY-TO-NEW-PROJECT.md docs/SECRETS.md \
  docs/AI-SETUP-PROMPT.md dumps/README.md
do
  [[ -e "$DEPLOY_DIR/$required" ]] || fail "missing: .deploy/$required"
done
(( FAILURES == 0 )) && log_ok "every expected file is present"
group_end

# =============================================================================
group_start "3. No project-specific values in the machinery"
# Engine names (mongo, postgres) are generic and fine. Project names, buckets,
# hosts and app-specific variable names are not.
FORBIDDEN=(
  'vod' 'idrivee2' 'railway-test' 'api/v1' 'TMDB'
  'DB_MONGO_URI' 'ACCESS_TOKEN_SECRET' 'EDGE_' 'STORAGE_PREFIX'
)
before=$FAILURES

# Scanned: every script and template. Excluded by path, with reasons —
#   selftest.sh   holds the forbidden list itself
#   config.yml    IS the per-project file; these belong there
#   docs/, dumps/ prose and data, not machinery
mapfile -t SCAN < <(find "$DEPLOY_DIR" \( -name '*.sh' -o -name '*.yml' -o -name '*.Dockerfile' \) \
                      ! -path '*/docs/*' ! -path '*/dumps/*' \
                      ! -name 'selftest.sh' ! -name 'config.yml' | sort)

for word in "${FORBIDDEN[@]}"; do
  hits=""
  for f in "${SCAN[@]}"; do
    # Comments are stripped before matching. This check is about hardcoded
    # VALUES; an example path written in a comment to explain an option is
    # documentation. sed preserves the line count, so numbers stay accurate.
    h="$(sed 's/#.*$//' "$f" | grep -niF -- "$word" || true)"
    [[ -n "$h" ]] && hits+="$(printf '%s\n' "$h" | sed "s#^#${f#"$DEPLOY_DIR"/}:#")"$'\n'
  done
  if [[ -n "$hits" ]]; then
    fail "'$word' appears in the machinery — it belongs in config.yml:"
    printf '%s' "$hits" | sed 's/^/      /' >&2
  fi
done
(( FAILURES == before )) && log_ok "machinery contains no project-specific values"
group_end

# =============================================================================
group_start "4. Every engine implements the full driver interface"
REQUIRED_FNS=(
  engine_default_port engine_tools_image engine_server_env
  engine_password_var
  engine_build_uri engine_ping engine_restore engine_stats
)
while IFS= read -r eng; do
  name="$(basename "$eng" .sh)"; missing=()
  for fn in "${REQUIRED_FNS[@]}"; do
    grep -qE "^[[:space:]]*${fn}[[:space:]]*\(\)" "$eng" || missing+=("$fn")
  done
  ((${#missing[@]})) && fail "engine '$name' is missing: ${missing[*]}" \
                     || log_ok "engine '$name' implements all ${#REQUIRED_FNS[@]} functions"
done < <(find "$DEPLOY_DIR/engines" -name '*.sh' | sort)
group_end

# =============================================================================
group_start "5. Every pipeline step defines its function"
for pair in \
  "validate:step_validate" "build:step_build" "smoke:step_smoke" \
  "provision:step_provision" \
  "vars:step_vars" "seed:step_seed" "destroy:step_destroy" \
  "release:step_migrate" "release:step_deploy" "release:step_health" "release:step_summary"
do
  f="${pair%%:*}"; fn="${pair##*:}"
  grep -qE "^[[:space:]]*${fn}[[:space:]]*\(\)" "$DEPLOY_DIR/steps/$f.sh" 2>/dev/null \
    || fail "steps/$f.sh does not define $fn()"
done
grep -q 'step_summary' "$DEPLOY_DIR/run.sh" || fail "run.sh does not call step_summary"
log_ok "all pipeline steps are wired up"
group_end

# =============================================================================
group_start "6. The workflows need no per-project editing"
for WF in "$DEPLOY_DIR"/workflow/*.yml; do
  wfname="workflow/$(basename "$WF")"
  if grep -qE '\$\{\{[[:space:]]*toJSON\(secrets\)' "$WF"; then
    log_ok "$wfname passes secrets as one context — no per-project edit"
  else
    fail "$wfname no longer passes toJSON(secrets); onboarding would
      need a manual edit for every secret"
  fi
  # Any OTHER named secret would be a project-specific edit creeping back in.
  strays="$(grep -oE 'secrets\.[A-Z_][A-Z0-9_]*' "$WF" | sort -u | grep -v 'secrets.GITHUB_TOKEN' || true)"
  [[ -n "$strays" ]] && { fail "$wfname names specific secrets — that breaks portability:"
                          printf '%s\n' "$strays" | sed 's/^/      /' >&2; }
done
group_end

# =============================================================================
group_start "7. Secrets are read via secret_get, not straight from the env"
# The workflow passes secrets as ONE JSON blob rather than as individual env
# vars, so "$SOME_TOKEN" is empty in CI even when the secret is set. Anything
# reading a credential directly from the environment silently fails there.
# This exact bug shipped once — the Railway token read as a bare env var and
# every deploy failed with "could not authenticate".
grep -rnE '"\$\{?(RAILWAY_API_TOKEN|RAILWAY_TEAM_TOKEN)\b' \
     "$DEPLOY_DIR" --include='*.sh' 2>/dev/null \
  | grep -v '/selftest\.sh:' | grep -v 'secret_get' \
  | grep -vE ':[0-9]+:[[:space:]]*#' >/tmp/envreads || true
if [[ -s /tmp/envreads ]]; then
  fail "a credential is read directly from the environment — use secret_get:"
  sed 's/^/      /' /tmp/envreads >&2
else
  log_ok "credentials go through secret_get"
fi
group_end

# =============================================================================
group_start "8. No secret value reaches the log"
# The real mistake: passing a secret-valued variable to a logging or summary
# function, where it lands in the workflow log verbatim. Building an auth
# header or reading a secret into a variable is how the thing works, and is
# deliberately not flagged.
grep -rnE '(log_(info|warn|err|ok|step)|summary)[[:space:]]+.*\$\{?[A-Za-z_]*(TOKEN|SECRET|PASSWORD|PASS|_KEY)' \
     "$DEPLOY_DIR" --include='*.sh' 2>/dev/null \
  | grep -v '/selftest\.sh:' | grep -v 'mask\|_var\b' >/tmp/leaks || true
[[ -s /tmp/leaks ]] && { fail "a script logs a secret value:"; sed 's/^/      /' /tmp/leaks >&2; } \
                    || log_ok "no secret values reach the log"
group_end

# =============================================================================
group_start "9. Dumps cannot be committed by accident"
if [[ -f "$DEPLOY_DIR/dumps/.gitignore" ]] && grep -qE '^\*$' "$DEPLOY_DIR/dumps/.gitignore"; then
  log_ok "dumps/ ignores everything except its own docs"
else
  fail "dumps/.gitignore is missing or does not ignore '*' — a dump could be committed"
fi
group_end

# =============================================================================
group_start "10. The blank template deploys with zero edits"
# The promise since v2: every default in the template already works, so a
# frontend-only project can deploy without touching config.yml at all. A
# TODO_FILL_ME creeping back into a VALUE breaks that. Comments may still
# mention the convention, so they are stripped before matching.
if sed 's/#.*$//' "$DEPLOY_DIR/config.example.yml" | grep -q 'TODO_FILL_ME'; then
  fail "config.example.yml has a TODO_FILL_ME value — the template must work as-is"
else
  log_ok "no required placeholders — the template is deployable as-is"
fi
group_end

# =============================================================================
group_start "11. Machinery version is declared"
[[ -f "$DEPLOY_DIR/VERSION" ]] \
  && log_ok "machinery version: $(tr -d '[:space:]' <"$DEPLOY_DIR/VERSION")" \
  || fail ".deploy/VERSION is missing — the config handshake needs it"
group_end

# =============================================================================
(( FAILURES )) && die "$FAILURES self-test failure(s) — this folder is not safely portable"
log_ok "self-test passed — copy .deploy/ into any project and run install.sh"
