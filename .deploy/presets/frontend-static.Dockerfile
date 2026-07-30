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
# them on the Railway service does nothing. Pass them here instead:
#
#     build_args:
#       BUILD_TIME_ENV: "VITE_API_URL=https://api.example.com VITE_FLAG=on"
#
# (space-separated NAME=value pairs; values must not contain spaces — and no
# secrets: build args end up readable in the image)
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
RUN if [ -n "$BUILD_TIME_ENV" ]; then export $BUILD_TIME_ENV; fi && npm run build

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

# Default for running the image locally; the deploy sets PORT explicitly and
# routes the public domain to the same number. EXPOSE documents it for tools
# that read image metadata.
ENV PORT=8080
EXPOSE 8080
