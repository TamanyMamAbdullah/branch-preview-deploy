# syntax=docker/dockerfile:1
# =============================================================================
# presets/frontend-static.Dockerfile — deploy a frontend with NO Dockerfile of
# its own. MACHINERY. Contains nothing project-specific.
#
# Builds any npm-scripted frontend (Vite, Create React App, Vue, Svelte, …)
# and serves the static result with nginx:
#   * listens on the PORT Railway injects
#   * answers 200 on /health, matching config.yml's default health check
#   * falls back to index.html, so client-side routes survive a refresh
#
# Point config.yml at it — that is the whole setup:
#
#   build:
#     dockerfile_path: .deploy/presets/frontend-static.Dockerfile
#     build_args:
#       OUTPUT_DIR: dist              # dist = Vite/Vue/Svelte, build = CRA
#
# Frontend env vars (VITE_*, REACT_APP_*) are baked in AT BUILD TIME — setting
# them on the Railway service does nothing, because the bundler already
# replaced them with literal strings. Pass them here instead:
#
#     build_args:
#       BUILD_TIME_ENV: "VITE_API_URL=https://api.example.com VITE_FLAG=on"
#
# (space-separated NAME=value pairs; values must not contain spaces — and no
# secrets: build args end up readable in the image)
#
# RUNTIME values — editable in Railway, no rebuild, NO app change
# ---------------------------------------------------------------
# A baked value cannot be changed afterwards, which is why editing the Railway
# variable appears to do nothing. List a variable here instead and it stays
# editable for the life of the image:
#
#     build_args:
#       RUNTIME_ENV: "VITE_API_URL=https://api.example.com"
#
# How: the build bakes the marker __RV_VITE_API_URL__ into the bundle instead
# of the value, and container start rewrites that marker in the built files —
# to the default above, or to whatever a RUNTIME_ENV variable on the service
# says. Change it in Railway, restart, done.
#
# The app is not touched and does not know any of this happened. It still reads
# import.meta.env.VITE_API_URL, and `npm run dev` is unaffected.
#
# Same NAME=value format as BUILD_TIME_ENV. Use BUILD_TIME_ENV for values that
# never change per environment, RUNTIME_ENV for the ones that do. A name must
# appear in only one of them.
#
# One limit worth knowing: the marker replaces the value at BUILD time, so a
# project that validates its env while building (rather than in the browser)
# will reject it. Those keep using BUILD_TIME_ENV.
# =============================================================================

# --- build stage --------------------------------------------------------------
FROM node:22-alpine AS build
WORKDIR /app

# Lockfile first, so dependency installation is cached across builds. The
# wildcards make every lockfile flavour optional — only package.json must exist.
COPY package.json package-lock.json* pnpm-lock.yaml* pnpm-workspace.yaml* yarn.lock* .npmrc* ./
RUN if [ -f package-lock.json ]; then npm ci; \
    elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; \
    else npm install; fi

COPY . .

ARG BUILD_TIME_ENV=""
# Every RUNTIME_ENV name is built with a marker in place of its value, so the
# value can be swapped in the finished files later. The marker is deliberately
# unmistakable: a plain value like "main" would be far too dangerous to search
# and replace across a whole bundle.
ARG RUNTIME_ENV=""
RUN if [ -n "$BUILD_TIME_ENV" ]; then export $BUILD_TIME_ENV; fi \
 && for pair in $RUNTIME_ENV; do \
      name=${pair%%=*}; \
      if [ "$name" != "$pair" ]; then export "$name=__RV_${name}__"; fi; \
    done \
 && npm run build

# --- serve stage --------------------------------------------------------------
# Note: the official nginx image starts as root and drops to the unprivileged
# `nginx` user for its worker processes — standard, and required for its
# template mechanism. Static-file serving keeps the surface minimal.
FROM nginx:stable-alpine

ARG OUTPUT_DIR=dist
COPY --from=build /app/${OUTPUT_DIR} /usr/share/nginx/html

# The official nginx image runs envsubst over /etc/nginx/templates/*.template
# at startup, substituting only DEFINED environment variables — so ${PORT}
# becomes Railway's injected port while nginx's own $uri stays untouched.
COPY <<'EOF' /etc/nginx/templates/default.conf.template
server {
    listen       ${PORT};
    listen  [::]:${PORT};
    root   /usr/share/nginx/html;
    index  index.html;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    # Hashed build assets never change — cache them hard.
    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
        try_files $uri =404;
    }

    # Single-page app: unknown paths are client-side routes, not files.
    location / {
        try_files $uri $uri/ /index.html;
    }

    # The deploy pipeline's health check.
    location = /health {
        add_header Content-Type text/plain;
        return 200 "ok";
    }
}
EOF

# The defaults travel with the image; a RUNTIME_ENV variable on the service
# overrides any of them at boot. Kept under a separate name so Railway setting
# RUNTIME_ENV cannot wipe the fallbacks.
ARG RUNTIME_ENV=""
ENV RUNTIME_ENV_DEFAULTS="$RUNTIME_ENV"

# The nginx image runs every /docker-entrypoint.d/*.sh before starting, so each
# boot re-resolves the markers from the CURRENT variables. Restarting the
# service is therefore enough to change a value — no rebuild.
COPY <<'EOF' /docker-entrypoint.d/40-runtime-env.sh
#!/bin/sh
set -e
root=/usr/share/nginx/html
[ -n "${RUNTIME_ENV_DEFAULTS:-}" ] || exit 0

# Resolve each name ONCE, override first. Replacing as we go would consume the
# marker on the default pass and leave the override with nothing to match.
for pair in $RUNTIME_ENV_DEFAULTS; do
  name=${pair%%=*}
  if [ "$name" = "$pair" ]; then continue; fi

  value=${pair#*=}
  for override in ${RUNTIME_ENV:-}; do
    case "$override" in
      "$name"=*) value=${override#*=} ;;
    esac
  done

  # Markers only ever appear in the built assets, so this cannot touch anything
  # else. '#' as the delimiter keeps URLs (full of '/') working.
  find "$root" -type f \( -name '*.js' -o -name '*.css' -o -name '*.html' \) \
    -exec sed -i "s#__RV_${name}__#${value}#g" {} +
  echo "runtime-env: ${name} resolved"
done
EOF

RUN chmod +x /docker-entrypoint.d/40-runtime-env.sh

# Default for running the image locally; the deploy sets PORT explicitly and
# routes the public domain to the same number. EXPOSE documents it for tools
# that read image metadata.
ENV PORT=8080
EXPOSE 8080
