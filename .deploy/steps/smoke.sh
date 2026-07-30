#!/usr/bin/env bash
# =============================================================================
# steps/smoke.sh — boot the built image ON THIS RUNNER and prove it answers,
# before anything is created on Railway.
# MACHINERY.
#
# Exists because of a real day lost to the alternative: an app whose nginx
# listened on port 80, IPv4 only, while the config aimed Railway at 8080.
# Every deploy built fine, ran fine, and failed a five-minute platform
# healthcheck with "service unavailable" — four times — because nothing
# checked that the IMAGE and the CONFIG agree. This step checks, in seconds:
#
#   1. run the image with <port_env>=<runtime.port>, exactly as Railway will
#   2. curl the health path from outside the container until it answers 2xx
#   3. read /proc/net/tcp* through the container's own network namespace and
#      verify the port is listening on IPv6 too — Railway's healthchecks and
#      routing connect over IPv6, so an IPv4-only listener deploys, runs,
#      and serves 502 for every request
#
# On failure it reports the ports the app ACTUALLY listens on and the exact
# config line (or app line) that fixes it. Railway is never touched.
# =============================================================================
# shellcheck shell=bash

# _smoke_ports <container> <tcp|tcp6> — decimal LISTEN ports, one per line.
# Read via a helper container sharing the app's network namespace, so this
# works even when the app image has no shell or coreutils of its own.
_smoke_ports() {
  local hex
  docker run --rm --network "container:$1" alpine:3.20 cat "/proc/net/$2" 2>/dev/null \
    | awk 'NR>1 && $4=="0A" { split($2,a,":"); print a[2] }' | sort -u \
    | while IFS= read -r hex; do
        [[ -n "$hex" ]] && printf '%d\n' "0x$hex" 2>/dev/null
      done
}

step_smoke() {
  local mode; mode="$(cfg '.build.smoke_test' 'auto')"
  case "$mode" in
    false)
      log_info "smoke test: skipped (build.smoke_test: false)"
      return 0 ;;
    auto)
      if [[ "$DB_ENGINE" != "none" ]]; then
        log_info "smoke test: skipped — this app needs its database to boot."
        log_info "Set build.smoke_test: true if it can start without one."
        return 0
      fi ;;
    true) ;;
    *) die "build.smoke_test must be auto, true or false — got '$mode'" ;;
  esac

  require_cmd docker curl
  group_start "Smoke test — booting the image on this runner first"

  local port port_env path name mapped code=000
  port="$(cfg '.runtime.port' '8080')"
  port_env="$(cfg '.runtime.port_env' 'PORT')"
  path="$(interp "$(cfg '.runtime.health_check_path' '/')")"
  name="deploy-smoke-$$"

  # Environment: the port variable plus env.static — enough for an app that
  # boots standalone. Secrets and stage values are deliberately absent; an
  # app that cannot boot without them should set build.smoke_test: false.
  local args=(run -d --name "$name" -e "${port_env}=${port}" -p "127.0.0.1:0:${port}")
  local k
  while IFS= read -r k; do [[ -z "$k" ]] && continue
    args+=(-e "$k=$(interp "$(cfg_json '.env.static' | jq -r --arg k "$k" '.[$k]|tostring')")")
  done < <(cfg_json '.env.static' | jq -r 'keys_unsorted[]')

  local sc; sc="$(cfg '.runtime.start_command' '')"
  if [[ -n "$sc" ]]; then
    docker "${args[@]}" "$IMAGE_REF" sh -lc "$sc" >/dev/null
  else
    docker "${args[@]}" "$IMAGE_REF" >/dev/null
  fi
  SMOKE_CONTAINER="$name"          # run.sh's EXIT trap removes it whatever happens

  mapped="$(docker port "$name" "${port}/tcp" 2>/dev/null | head -n1)"

  log_info "image   : $IMAGE_REF"
  log_info "checking: http://127.0.0.1:${port}${path}  (${port_env}=${port}, up to 60s)"

  local deadline=$(( SECONDS + 60 )) running="true"
  while :; do
    running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || printf 'false')"
    if [[ -n "$mapped" ]]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${mapped}${path}" 2>/dev/null || printf '000')"
      [[ "$code" =~ ^2[0-9][0-9]$ ]] && break
    else
      mapped="$(docker port "$name" "${port}/tcp" 2>/dev/null | head -n1)"
    fi
    [[ "$running" != "true" ]] && break
    (( SECONDS >= deadline )) && break
    sleep 2
  done

  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    # Reachable over IPv4 — now the check the platform actually cares about.
    if _smoke_ports "$name" tcp6 | grep -qx "$port"; then
      log_ok "answers ${path} with HTTP $code on port $port, IPv4 + IPv6"
      docker rm -f "$name" >/dev/null 2>&1 || true
      SMOKE_CONTAINER=""
      group_end
      return 0
    fi
    local why="the app answers on port $port — but over IPv4 ONLY.
Railway's healthchecks and routing connect over IPv6: this exact setup
deploys, runs, and then serves 502 for every request. Make the app listen
on IPv6 as well:
  nginx      add    listen [::]:${port};    next to    listen ${port};
  Node       app.listen(port) already binds both — check for an explicit '127.0.0.1'
(Escape hatch if you know better: build.smoke_test: false)"
    group_end
    docker rm -f "$name" >/dev/null 2>&1 || true; SMOKE_CONTAINER=""
    die "$why"
  fi

  # --- failed: say exactly what is true instead ------------------------------
  local v4 v6 listening=""
  v4="$(_smoke_ports "$name" tcp | tr '\n' ' ')"
  v6="$(_smoke_ports "$name" tcp6 | tr '\n' ' ')"
  [[ -n "$v4" ]] && listening="IPv4: ${v4}"
  [[ -n "$v6" ]] && listening="${listening}  IPv6: ${v6}"

  log_err "the image did not answer 2xx on ${path} (port $port) within 60s — last HTTP: $code"
  [[ "$running" != "true" ]] && log_err "the container EXITED — read its logs below; it likely crashed at startup"
  [[ -n "$listening" ]] && log_err "ports actually LISTENING inside the container:  $listening"
  [[ -z "$listening" && "$running" == "true" ]] && log_err "nothing is listening inside the container at all"

  group_start "Container logs"
  docker logs --tail 40 "$name" 2>&1 | sed 's/^/    /' >&2 || true
  group_end
  docker rm -f "$name" >/dev/null 2>&1 || true; SMOKE_CONTAINER=""
  group_end

  die "the image failed the local smoke test — Railway was not touched.
Make the image and .deploy/config.yml agree, whichever side is wrong:
  • runtime.port              must be the port the app REALLY listens on
  • runtime.health_check_path must be a path that REALLY returns 200
  • an app crashing at boot usually misses an env var — env.static values
    are provided here, secrets are not (build.smoke_test: false to skip)"
}
