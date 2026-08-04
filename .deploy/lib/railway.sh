#!/usr/bin/env bash
# =============================================================================
# railway.sh — every Railway API call in the system lives here, and only here.
# MACHINERY. Contains nothing project-specific.
#
# Why the GraphQL API and not the `railway` CLI:
#   * the CLI's useful commands (environment, service, add) are interactive by
#     default, and its flags shift between releases — CI would break silently
#   * curl and jq are already on every runner; nothing to install
#   * https://docs.railway.com/guides/api-cookbook documents the contract
#
# Endpoint and auth headers confirmed against Railway's public API docs:
#   account/workspace token -> Authorization: Bearer <token>
#   team token              -> Team-Access-Token: <token>
#   project token           -> Project-Access-Token: <token>   (cannot create
#                              environments, so it is rejected below)
# =============================================================================
# shellcheck shell=bash

RAILWAY_API="${RAILWAY_API:-https://backboard.railway.com/graphql/v2}"

: "${DEPLOY_DIR:?DEPLOY_DIR must be set before sourcing railway.sh}"
# shellcheck source=./log.sh
source "$DEPLOY_DIR/lib/log.sh"
# shellcheck source=./secrets.sh
source "$DEPLOY_DIR/lib/secrets.sh"

# -----------------------------------------------------------------------------
# rw_auth_header — pick the right header for whichever token was supplied.
# -----------------------------------------------------------------------------
# Read via secret_get, NOT straight from the environment. The workflow passes
# secrets as one JSON blob rather than listing each as an env var, so a bare
# "$RAILWAY_API_TOKEN" is empty in CI even when the secret is set correctly.
rw_auth_header() {
  local team api
  team="$(secret_get RAILWAY_TEAM_TOKEN)"
  api="$(secret_get RAILWAY_API_TOKEN)"

  if [[ -n "$team" ]]; then
    printf 'Team-Access-Token: %s' "$team"
  elif [[ -n "$api" ]]; then
    printf 'Authorization: Bearer %s' "$api"
  else
    die "no Railway token found. Add an ACCOUNT token as the repo secret
RAILWAY_API_TOKEN (railway.com/account/tokens). A PROJECT token will not work —
it cannot create environments."
  fi
}

# -----------------------------------------------------------------------------
# rw_gql <query> [variables-json] — run one GraphQL operation.
#
# Returns the .data object on stdout. Retries transient failures (5xx, network,
# rate limit) with backoff; a GraphQL "errors" array is a real error and is
# reported immediately rather than retried.
# -----------------------------------------------------------------------------
rw_gql() {
  local query="$1" vars="${2:-{\}}"
  local attempt=0 max=4 body http resp
  body="$(jq -nc --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')"

  while :; do
    attempt=$((attempt + 1))
    resp="$(curl -sS -w $'\n%{http_code}' \
              -X POST "$RAILWAY_API" \
              -H "$(rw_auth_header)" \
              -H 'Content-Type: application/json' \
              --max-time 60 \
              -d "$body" 2>&1 || true)"

    http="$(printf '%s' "$resp" | tail -n1)"
    resp="$(printf '%s' "$resp" | sed '$d')"

    # When curl itself fails, the last line is error text, not a status code.
    # Normalize to empty so it is treated as a retryable network error below.
    [[ "$http" =~ ^[0-9]{3}$ ]] || http=""

    if [[ "$http" == "200" ]]; then
      if printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1; then
        log_err "Railway API rejected the request:"
        printf '%s' "$resp" | jq -r '.errors[]? | "    • \(.message)"' >&2
        # A bad token is the most common cause and the least obvious message.
        if printf '%s' "$resp" | jq -e '.errors[]?|select(.message|test("[Nn]ot [Aa]uthorized|[Uu]nauthorized"))' >/dev/null 2>&1; then
          log_err "That usually means the token is wrong, expired, or is a PROJECT"
          log_err "token. Environment creation needs an ACCOUNT token."
        fi
        return 1
      fi
      printf '%s' "$resp" | jq -c '.data'
      return 0
    fi

    if (( attempt >= max )) || [[ "$http" =~ ^4[0-9][0-9]$ && "$http" != "429" ]]; then
      log_err "Railway API call failed (HTTP ${http:-network-error}) after $attempt attempt(s)"
      printf '%s' "$resp" | head -c 800 >&2; printf '\n' >&2
      return 1
    fi

    local wait=$((attempt * attempt * 2))
    log_warn "Railway API HTTP ${http:-error} — retrying in ${wait}s (attempt $attempt/$max)"
    sleep "$wait"
  done
}

# =============================================================================
# Schema introspection.
#
# Railway's docs don't spell out the input shape for tcpProxyCreate, and
# numReplicas on ServiceInstanceUpdateInput is reported deprecated in favour of
# multiRegionConfig. Rather than hardcode a guess that breaks the day they
# finish that migration, we ask the live schema at runtime and adapt.
# =============================================================================

RW_SCHEMA_CACHE=""

rw_input_fields() {              # rw_input_fields <InputTypeName> -> field names
  local type="$1"
  [[ -z "$RW_SCHEMA_CACHE" ]] && RW_SCHEMA_CACHE="$(mktemp -d)"
  local cache="$RW_SCHEMA_CACHE/$type.json"

  if [[ ! -f "$cache" ]]; then
    rw_gql 'query($n:String!){ __type(name:$n){ inputFields{ name } } }' \
           "$(jq -nc --arg n "$type" '{n:$n}')" >"$cache" 2>/dev/null || printf '{}' >"$cache"
  fi
  jq -r '.__type.inputFields[]?.name' "$cache" 2>/dev/null || true
}

rw_has_field() {                 # rw_has_field <InputType> <field>
  rw_input_fields "$1" | grep -qx "$2"
}

rw_obj_fields() {                # rw_obj_fields <ObjectTypeName> -> field names
  local type="$1"
  [[ -z "$RW_SCHEMA_CACHE" ]] && RW_SCHEMA_CACHE="$(mktemp -d)"
  local cache="$RW_SCHEMA_CACHE/obj-$type.json"

  if [[ ! -f "$cache" ]]; then
    rw_gql 'query($n:String!){ __type(name:$n){ fields{ name } } }' \
           "$(jq -nc --arg n "$type" '{n:$n}')" >"$cache" 2>/dev/null || printf '{}' >"$cache"
  fi
  jq -r '.__type.fields[]?.name' "$cache" 2>/dev/null || true
}

rw_obj_has_field() {             # rw_obj_has_field <ObjectType> <field>
  rw_obj_fields "$1" | grep -qx "$2"
}

# =============================================================================
# Projects
# =============================================================================

rw_project_exists() {            # rw_project_exists <projectId>
  rw_gql 'query($id:String!){ project(id:$id){ id name } }' \
         "$(jq -nc --arg id "$1" '{id:$id}')" 2>/dev/null \
    | jq -e '.project.id' >/dev/null 2>&1
}

# rw_project_find_by_name <name> — every LIVE project this token can see with
# that exact name, one id per line. Lets a run whose config has no project_id
# find the project a previous run created instead of creating another one —
# and lets automatic cleanup find it too. Best-effort: an API error returns
# nothing and the caller falls back to its old behaviour.
#
# DELETED projects still come back from this query. Railway keeps a deleted
# project recoverable for a grace period — the dashboard shows it under
# "N Deleted" with "Removed in 1d" — and the API lists it exactly like a live
# one, just with deletedAt set. Without this filter a single real project plus
# one in the trash counts as two, and both provision and destroy then refuse to
# guess between a project that exists and one that is on its way out. Reported
# from a real run, not from code review.
#
# The schema check matters: asking for a field the API does not have makes the
# WHOLE query fail, which would return nothing — and "no project found" sends
# provision off to create a duplicate. So only ask when the field is really
# there. The jq filter is written to be correct either way.
rw_project_find_by_name() {
  local q='query{ projects(first:100){ edges{ node{ id name } } } }'
  rw_obj_has_field Project deletedAt \
    && q='query{ projects(first:100){ edges{ node{ id name deletedAt } } } }'

  rw_gql "$q" 2>/dev/null \
    | jq -r --arg n "$1" '.projects.edges[]?.node
                          | select(.name == $n)
                          | select((.deletedAt // null) == null)
                          | .id' || true
  return 0
}

# Projects belong to a workspace. Most accounts have exactly one, so it is
# auto-detected rather than made another thing to configure. Detection is
# BEST-EFFORT and never fails the run: the API has carried both `workspaces`
# and the older `teams` shape, and a workspace-scoped token cannot ask about
# the account at all. When nothing can be detected these return empty, and the
# create path handles it with a visible, actionable message.
rw_workspace_list() {            # -> "id  name" per line; empty when unknowable
  if rw_obj_has_field User workspaces; then
    rw_gql 'query{ me{ workspaces{ id name } } }' 2>/dev/null \
      | jq -r '.me.workspaces[]? | "\(.id)  \(.name)"' || true
  elif rw_obj_has_field User teams; then
    rw_gql 'query{ me{ teams{ edges{ node{ id name } } } } }' 2>/dev/null \
      | jq -r '.me.teams.edges[]?.node | "\(.id)  \(.name)"' || true
  fi
  return 0
}

rw_workspace_default() {         # -> id when there is exactly one, else empty
  local list; list="$(rw_workspace_list)"
  [[ "$(printf '%s\n' "$list" | grep -c .)" == "1" ]] && printf '%s' "${list%%  *}"
  return 0
}

rw_project_create() {            # rw_project_create <name> [workspaceId] -> id
  local name="$1" ws="${2:-}" input out
  input="$(jq -nc --arg n "$name" '{name:$n}')"
  # The input field has been named both workspaceId and teamId over time —
  # ask the schema which one this API wants.
  if [[ -n "$ws" ]]; then
    if rw_has_field ProjectCreateInput workspaceId; then
      input="$(jq -nc --argjson i "$input" --arg w "$ws" '$i + {workspaceId:$w}')"
    elif rw_has_field ProjectCreateInput teamId; then
      input="$(jq -nc --argjson i "$input" --arg w "$ws" '$i + {teamId:$w}')"
    fi
  fi

  out="$(rw_gql 'mutation($input:ProjectCreateInput!){ projectCreate(input:$input){ id name } }' \
                "$(jq -nc --argjson i "$input" '{input:$i}')")" || return 1
  printf '%s' "$out" | jq -r '.projectCreate.id'
}

# =============================================================================
# Environments
# =============================================================================

rw_env_find() {                  # rw_env_find <projectId> <name> -> id | empty
  rw_gql 'query($p:String!){ environments(projectId:$p){ edges{ node{ id name } } } }' \
         "$(jq -nc --arg p "$1" '{p:$p}')" 2>/dev/null \
    | jq -r --arg n "$2" '.environments.edges[]?.node | select(.name==$n) | .id' | head -n1 || true
}

rw_env_create() {                # rw_env_create <projectId> <name> -> id
  local out
  # skipInitialDeploys: we deploy explicitly once variables and the seeded
  # database are ready. Without it Railway would fire a deploy immediately,
  # against an unconfigured service, which then fails and muddies the logs.
  out="$(rw_gql 'mutation($input:EnvironmentCreateInput!){ environmentCreate(input:$input){ id name } }' \
                "$(jq -nc --arg p "$1" --arg n "$2" \
                     '{input:{projectId:$p, name:$n, skipInitialDeploys:true}}')")" || return 1
  printf '%s' "$out" | jq -r '.environmentCreate.id'
}

rw_env_ensure() {                # rw_env_ensure <projectId> <name> -> id
  local id
  id="$(rw_env_find "$1" "$2")"
  if [[ -n "$id" ]]; then
    log_info "environment '$2' already exists — reusing it"
    printf '%s' "$id"; return 0
  fi
  log_info "creating environment '$2'"
  rw_env_create "$1" "$2"
}

rw_env_delete() {                # rw_env_delete <environmentId>
  rw_gql 'mutation($id:String!){ environmentDelete(id:$id) }' \
         "$(jq -nc --arg id "$1" '{id:$id}')" >/dev/null
}

# =============================================================================
# Services
# =============================================================================

rw_service_find() {              # rw_service_find <projectId> <name> -> id | empty
  rw_gql 'query($p:String!){ project(id:$p){ services{ edges{ node{ id name } } } } }' \
         "$(jq -nc --arg p "$1" '{p:$p}')" 2>/dev/null \
    | jq -r --arg n "$2" '.project.services.edges[]?.node | select(.name==$n) | .id' | head -n1 || true
}

rw_service_create_image() {      # rw_service_create_image <projectId> <envId> <name> <image> -> id
  local out
  out="$(rw_gql 'mutation($input:ServiceCreateInput!){ serviceCreate(input:$input){ id name } }' \
                "$(jq -nc --arg p "$1" --arg e "$2" --arg n "$3" --arg i "$4" \
                     '{input:{projectId:$p, environmentId:$e, name:$n, source:{image:$i}}}')")" || return 1
  printf '%s' "$out" | jq -r '.serviceCreate.id'
}

rw_service_ensure_image() {      # <projectId> <envId> <name> <image> -> id
  local id
  id="$(rw_service_find "$1" "$3")"
  if [[ -n "$id" ]]; then
    log_info "service '$3' already exists — reusing it"
    printf '%s' "$id"; return 0
  fi
  log_info "creating service '$3' from image $4"
  rw_service_create_image "$1" "$2" "$3" "$4"
}

# -----------------------------------------------------------------------------
# rw_service_update — set image / healthcheck / replicas on a service instance.
# Builds the input from whatever the live schema actually accepts.
# -----------------------------------------------------------------------------
rw_service_update() {            # <serviceId> <envId> <image|""> <healthPath|""> <replicas|""> [autoSleep|""]
  local svc="$1" env="$2" image="$3" health="$4" replicas="$5" auto_sleep="${6:-}"
  local input='{}'

  [[ -n "$image"  ]] && input="$(jq -nc --argjson i "$input" --arg v "$image"  '$i + {source:{image:$v}}')"
  [[ -n "$health" ]] && input="$(jq -nc --argjson i "$input" --arg v "$health" '$i + {healthcheckPath:$v}')"

  if [[ -n "$replicas" ]]; then
    if rw_has_field ServiceInstanceUpdateInput numReplicas; then
      input="$(jq -nc --argjson i "$input" --argjson v "$replicas" '$i + {numReplicas:$v}')"
    else
      log_info "numReplicas not in the schema — replicas left at Railway's default"
    fi
  fi

  # Scale-to-zero when idle. Schema-checked like the fields above, so a Railway
  # rename degrades to "left at the default" instead of failing the deploy.
  if [[ -n "$auto_sleep" ]]; then
    if rw_has_field ServiceInstanceUpdateInput sleepApplication; then
      input="$(jq -nc --argjson i "$input" --argjson v "$([[ "$auto_sleep" == "true" ]] && echo true || echo false)" \
                 '$i + {sleepApplication:$v}')"
    else
      log_info "sleepApplication not in the schema — auto-sleep left at Railway's default"
    fi
  fi

  [[ "$input" == '{}' ]] && return 0

  rw_gql 'mutation($s:String!,$e:String!,$input:ServiceInstanceUpdateInput!){
            serviceInstanceUpdate(serviceId:$s, environmentId:$e, input:$input) }' \
         "$(jq -nc --arg s "$svc" --arg e "$env" --argjson input "$input" \
              '{s:$s,e:$e,input:$input}')" >/dev/null
}

# -----------------------------------------------------------------------------
# rw_service_set_registry_creds <serviceId> <envId> <username> <password>
#
# Lets Railway pull a PRIVATE image (a Pro-plan feature). Called BEFORE the
# service is pointed at the new image, because an image change can start a
# deployment on its own — the credentials must already be in place when it does.
# -----------------------------------------------------------------------------
rw_service_set_registry_creds() {
  local svc="$1" env="$2" user="$3" pass="$4"
  if ! rw_has_field ServiceInstanceUpdateInput registryCredentials; then
    log_err "this Railway API schema does not expose registryCredentials, so the"
    log_err "pull token cannot be applied automatically. One-time manual fix:"
    log_err "Railway dashboard → the app service → Settings → Source → add the"
    log_err "registry credentials there, then re-run."
    return 1
  fi
  rw_gql 'mutation($s:String!,$e:String!,$input:ServiceInstanceUpdateInput!){
            serviceInstanceUpdate(serviceId:$s, environmentId:$e, input:$input) }' \
         "$(jq -nc --arg s "$svc" --arg e "$env" --arg u "$user" --arg p "$pass" \
              '{s:$s,e:$e,input:{registryCredentials:{username:$u,password:$p}}}')" >/dev/null
}

# =============================================================================
# Variables
# =============================================================================

# rw_vars_set <projectId> <envId> <serviceId> <json-map> [skipDeploys=true]
#
# skipDeploys defaults to true: applying variables one call at a time would
# otherwise kick off a deploy against a half-configured service.
rw_vars_set() {
  local proj="$1" env="$2" svc="$3" vars="$4" skip="${5:-true}"
  rw_gql 'mutation($input:VariableCollectionUpsertInput!){ variableCollectionUpsert(input:$input) }' \
         "$(jq -nc --arg p "$proj" --arg e "$env" --arg s "$svc" \
                   --argjson v "$vars" --argjson skip "$skip" \
              '{input:{projectId:$p, environmentId:$e, serviceId:$s, variables:$v, skipDeploys:$skip}}')" \
    >/dev/null
}

# =============================================================================
# Domains
# =============================================================================

rw_domain_find() {               # rw_domain_find <envId> <serviceId> -> "id<TAB>domain" | empty
  rw_gql 'query($e:String!,$s:String!){ domains(environmentId:$e, serviceId:$s){
            serviceDomains{ id domain } customDomains{ id domain } } }' \
         "$(jq -nc --arg e "$1" --arg s "$2" '{e:$e,s:$s}')" 2>/dev/null \
    | jq -r '(.domains.serviceDomains[0] // .domains.customDomains[0]) // empty
             | select(. != "") | "\(.id)\t\(.domain)"' || true
}

# rw_domain_update_port <domainId> <targetPort> — best-effort, schema-checked.
# The update input's id field has varied in name; ask the schema.
rw_domain_update_port() {
  local id="$1" port="$2" key=""
  if rw_has_field ServiceDomainUpdateInput serviceDomainId; then key="serviceDomainId"
  elif rw_has_field ServiceDomainUpdateInput id; then key="id"
  else return 1; fi
  rw_gql 'mutation($input:ServiceDomainUpdateInput!){ serviceDomainUpdate(input:$input) }' \
         "$(jq -nc --arg k "$key" --arg id "$id" --argjson p "$port" \
              '{input: ({($k): $id, targetPort: $p})}')" >/dev/null
}

rw_domain_create() {             # rw_domain_create <envId> <serviceId> [targetPort] -> domain
  local vars
  if [[ -n "${3:-}" ]]; then
    vars="$(jq -nc --arg e "$1" --arg s "$2" --argjson p "$3" '{input:{environmentId:$e,serviceId:$s,targetPort:$p}}')"
  else
    vars="$(jq -nc --arg e "$1" --arg s "$2" '{input:{environmentId:$e,serviceId:$s}}')"
  fi
  rw_gql 'mutation($input:ServiceDomainCreateInput!){ serviceDomainCreate(input:$input){ domain } }' "$vars" \
    | jq -r '.serviceDomainCreate.domain'
}

rw_domain_ensure() {             # <envId> <serviceId> [targetPort] -> domain
  local entry id d port="${3:-}"
  entry="$(rw_domain_find "$1" "$2")"
  if [[ -n "$entry" ]]; then
    id="${entry%%$'\t'*}"; d="${entry#*$'\t'}"
    # Re-aim the existing domain too: an earlier run may have created it
    # without a target port, leaving Railway routing to the image's EXPOSE
    # default — which serves 502 while the app runs fine.
    if [[ -n "$port" && -n "$id" ]]; then
      rw_domain_update_port "$id" "$port" || log_warn \
        "could not set the existing domain's target port — if the URL returns 502, run destroy for this branch and deploy again"
    fi
    printf '%s' "$d"; return 0
  fi
  rw_domain_create "$1" "$2" "$port"
}

# =============================================================================
# TCP proxy — the temporary public door used to seed the database.
# Input shape is discovered from the live schema rather than assumed.
# =============================================================================

rw_tcp_proxy_create() {          # <envId> <serviceId> <applicationPort> -> "host:port"
  local env="$1" svc="$2" port="$3" vars out
  vars="$(jq -nc --arg e "$env" --arg s "$svc" --argjson p "$port" \
            '{input:{environmentId:$e, serviceId:$s, applicationPort:$p}}')"

  out="$(rw_gql 'mutation($input:TCPProxyCreateInput!){ tcpProxyCreate(input:$input){
                   id domain proxyPort applicationPort } }' "$vars")" || return 1
  printf '%s' "$out" | jq -r '"\(.tcpProxyCreate.domain):\(.tcpProxyCreate.proxyPort)"'
}

rw_tcp_proxy_list() {            # <envId> <serviceId> -> id<TAB>domain<TAB>port
  rw_gql 'query($e:String!,$s:String!){ tcpProxies(environmentId:$e, serviceId:$s){
            id domain proxyPort } }' \
         "$(jq -nc --arg e "$1" --arg s "$2" '{e:$e,s:$s}')" 2>/dev/null \
    | jq -r '.tcpProxies[]? | "\(.id)\t\(.domain)\t\(.proxyPort)"' || true
}

rw_tcp_proxy_delete() {          # <proxyId>
  rw_gql 'mutation($id:String!){ tcpProxyDelete(id:$id) }' \
         "$(jq -nc --arg id "$1" '{id:$id}')" >/dev/null
}

# rw_tcp_proxy_delete_all <envId> <serviceId> — close every public door we opened.
rw_tcp_proxy_delete_all() {
  local id rest n=0
  while IFS=$'\t' read -r id rest; do
    [[ -z "$id" ]] && continue
    rw_tcp_proxy_delete "$id" && n=$((n + 1))
  done < <(rw_tcp_proxy_list "$1" "$2")
  (( n )) && log_ok "closed $n public database port(s)"
  return 0
}

# =============================================================================
# Deployments
# =============================================================================

rw_deploy_trigger() {            # <serviceId> <envId>
  rw_gql 'mutation($s:String!,$e:String!){ serviceInstanceRedeploy(serviceId:$s, environmentId:$e) }' \
         "$(jq -nc --arg s "$1" --arg e "$2" '{s:$s,e:$e}')" >/dev/null
}

rw_deploy_latest() {             # <projectId> <serviceId> <envId> -> "id status"
  rw_gql 'query($p:String!,$s:String!,$e:String!){
            deployments(first:1, input:{projectId:$p, serviceId:$s, environmentId:$e}){
              edges{ node{ id status createdAt } } } }' \
         "$(jq -nc --arg p "$1" --arg s "$2" --arg e "$3" '{p:$p,s:$s,e:$e}')" 2>/dev/null \
    | jq -r '.deployments.edges[0].node | "\(.id) \(.status)"' 2>/dev/null || true
}

# rw_deploy_logs <deploymentId> [limit]
# Both build and runtime streams. Runtime logs are the ones that carry an
# uncaught stack trace thrown before an app's logger exists.
rw_deploy_logs() {
  local id="$1" limit="${2:-200}"
  rw_gql 'query($id:String!,$l:Int!){ buildLogs(deploymentId:$id, limit:$l){ message severity timestamp } }' \
         "$(jq -nc --arg id "$id" --argjson l "$limit" '{id:$id,l:$l}')" 2>/dev/null \
    | jq -r '.buildLogs[]? | "[build] \(.message)"' || true
  rw_gql 'query($id:String!,$l:Int!){ deploymentLogs(deploymentId:$id, limit:$l){ message severity timestamp } }' \
         "$(jq -nc --arg id "$id" --argjson l "$limit" '{id:$id,l:$l}')" 2>/dev/null \
    | jq -r '.deploymentLogs[]? | "[run] \(.message)"' || true
}

# =============================================================================
# selftest — prove the token works before anything else is attempted.
# =============================================================================
rw_selftest() {
  require_cmd curl jq
  group_start "Railway connectivity self-test"

  # Two ways to prove the token works, because `me` is not valid for every
  # token type (a team token has no personal user). Only fail when BOTH fail —
  # otherwise a perfectly good token would block every deploy here.
  local me ok=false
  if me="$(rw_gql 'query{ me{ id name email } }' 2>/dev/null)" \
     && [[ -n "$(printf '%s' "$me" | jq -r '.me.id // empty')" ]]; then
    log_ok "authenticated as: $(printf '%s' "$me" | jq -r '.me.name // .me.email // .me.id')"
    ok=true
  elif me="$(rw_gql 'query{ projects(first:1){ edges{ node{ id } } } }' 2>/dev/null)" \
     && printf '%s' "$me" | jq -e '.projects' >/dev/null 2>&1; then
    log_ok "token accepted (project-scoped — 'me' is not available for this token type)"
    ok=true
  fi

  if [[ "$ok" != "true" ]]; then
    group_end
    die "could not authenticate against the Railway API.
Add an ACCOUNT token as the repo secret RAILWAY_API_TOKEN
(railway.com/account/tokens). A PROJECT token cannot create environments."
  fi

  log_info "checking which schema fields this account's API exposes:"
  local f
  for f in numReplicas multiRegionConfig healthcheckPath source sleepApplication registryCredentials; do
    if rw_has_field ServiceInstanceUpdateInput "$f"; then
      log_ok  "  ServiceInstanceUpdateInput.$f  present"
    else
      log_warn "  ServiceInstanceUpdateInput.$f  ABSENT"
    fi
  done
  for f in environmentId serviceId applicationPort; do
    if rw_has_field TCPProxyCreateInput "$f"; then
      log_ok  "  TCPProxyCreateInput.$f  present"
    else
      log_warn "  TCPProxyCreateInput.$f  ABSENT"
    fi
  done

  group_end
  log_ok "Railway self-test passed"
}

# Allow running this file directly:  bash .deploy/lib/railway.sh selftest
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-selftest}" in
    selftest) rw_selftest ;;
    *) die "usage: railway.sh selftest" ;;
  esac
fi
