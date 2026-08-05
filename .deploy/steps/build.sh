#!/usr/bin/env bash
# =============================================================================
# steps/build.sh — get a runnable image for this commit, reusing one if it
# already exists. Sets IMAGE_REF.
# MACHINERY.
# =============================================================================
# shellcheck shell=bash

_manifest_exists() { docker manifest inspect "$1" >/dev/null 2>&1; }

step_build() {
  require_cmd docker jq
  group_start "Image for $SHA7"

  IMAGE_REPO="$(cfg '.build.image_repo' '')"
  if [[ -z "$IMAGE_REPO" ]]; then
    [[ -z "${GITHUB_REPOSITORY:-}" ]] && \
      die "build.image_repo is empty and GITHUB_REPOSITORY is unset — set build.image_repo when running outside GitHub Actions"
    # Registry paths must be lowercase; repository names often are not.
    IMAGE_REPO="ghcr.io/$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
  fi

  local tag target
  tag="$(interp "$(cfg '.build.tag_template' 'preview-${BRANCH_SLUG}-${SHA7}')")"
  target="${IMAGE_REPO}:${tag}"
  log_info "target: $target"

  IMAGE_REF=""; IMAGE_REUSED="false"

  # --- reuse ------------------------------------------------------------------
  if [[ "$(cfg '.build.reuse_registry' 'true')" == "true" ]]; then
    local tmpl candidate
    while IFS= read -r tmpl; do
      [[ -z "$tmpl" ]] && continue
      candidate="${IMAGE_REPO}:$(interp "$tmpl")"
      log_info "looking for a prebuilt image: $candidate"
      if _manifest_exists "$candidate"; then
        IMAGE_REF="$candidate"; IMAGE_REUSED="true"
        log_ok "found one — skipping the build entirely"
        break
      fi
    done < <(cfg_list '.build.reuse_tag_templates')

    if [[ -z "$IMAGE_REF" ]] && _manifest_exists "$target"; then
      IMAGE_REF="$target"; IMAGE_REUSED="true"
      log_ok "this commit was built by an earlier run — reusing it"
    fi
  fi

  # --- build ------------------------------------------------------------------
  if [[ -z "$IMAGE_REF" ]]; then
    local method context
    method="$(cfg '.build.method' 'dockerfile')"
    context="$(cfg '.build.context' '.')"

    case "$method" in
      dockerfile)
        local df; df="$(resolve_path "$(cfg '.build.dockerfile_path' 'Dockerfile')")"
        [[ -f "$df" ]] || die "build.dockerfile_path '$df' does not exist"
        local args=(build -f "$df" -t "$target")
        local stage_target; stage_target="$(cfg '.build.target' '')"
        [[ -n "$stage_target" ]] && args+=(--target "$stage_target")

        # Non-secret build args only — secrets must never become image layers.
        local k v
        while IFS= read -r k; do
          [[ -z "$k" ]] && continue
          v="$(interp "$(cfg_json '.build.build_args' | jq -r --arg k "$k" '.[$k]|tostring')")"
          args+=(--build-arg "$k=$v")
        done < <(cfg_json '.build.build_args' | jq -r 'keys_unsorted[]')

        args+=(--label "org.opencontainers.image.revision=$SHA"
               --label "deploy.branch=$BRANCH" --label "deploy.stage=$STAGE"
               "$context")
        log_info "docker build -f $df $context"
        docker "${args[@]}"
        ;;
      nixpacks)
        command -v nixpacks >/dev/null 2>&1 || {
          log_info "installing nixpacks"; curl -sSL https://nixpacks.com/install.sh | bash; }
        log_info "nixpacks build $context --name $target"
        nixpacks build "$context" --name "$target"
        ;;
      *) die "build.method must be 'dockerfile' or 'nixpacks' — got '$method'" ;;
    esac

    log_info "pushing $target"
    docker push "$target" || die "push failed — the workflow needs 'permissions: packages: write'"
    IMAGE_REF="$target"
  fi
  group_end

  # --- can Railway actually pull it? -------------------------------------------
  # Private registry credentials are a Railway Pro feature, so on any other plan
  # the package must be public. Verified by pulling anonymously rather than
  # assumed — otherwise this surfaces much later as an opaque Railway error.
  group_start "Checking Railway can pull the image"
  if [[ "$(cfg '.build.registry_visibility' 'public')" == "public" && "$IMAGE_REF" == ghcr.io/* ]]; then
    local path repo rtag token code=000
    path="${IMAGE_REF#ghcr.io/}"; rtag="${path##*:}"; repo="${path%:*}"
    token="$(curl -sS "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null | jq -r '.token // empty')"
    [[ -n "$token" ]] && code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://ghcr.io/v2/${repo}/manifests/${rtag}" 2>/dev/null || echo 000)"

    if [[ "$code" == "200" ]]; then
      log_ok "the image is publicly pullable"
    else
      group_end
      die "The image is private, so Railway cannot pull it.

  Anonymous pull returned HTTP $code.
  Private registry credentials are a Railway Pro feature, so on any other plan
  the package has to be public.

  FIX THIS ONCE, then it stays fixed:

    1. Open  https://github.com/${GITHUB_REPOSITORY:-<owner>/<repo>}/pkgs/container/${repo##*/}
    2. Package settings  (right-hand side)
    3. Danger Zone → Change visibility → Public
    4. Re-run this workflow

  The image itself built and pushed fine — this is the last step before Railway.

  No 'Change visibility' button? Under an organization an ordinary member
  usually cannot flip a package to public. Two ways out:

    - Ask an organization owner to do steps 1-3. The org may first have to
      allow public packages at all, under its Settings → Packages.
    - Or, on Railway Pro, keep the image locked: set
      build.registry_visibility: private in .deploy/config.yml, put your own
      read:packages token in the $(cfg '.build.registry_password_env' 'GHCR_PULL_TOKEN') secret, and set
      build.registry_username to your GitHub username.
      Click-by-click: .deploy/docs/SECRETS.md"
    fi
  else
    log_info "registry_visibility is 'private' — the image stays locked; the deploy step"
    log_info "hands Railway the '$(cfg '.build.registry_password_env' 'GHCR_PULL_TOKEN')' pull token (Railway Pro feature)"
  fi
  group_end

  log_ok "image: $IMAGE_REF (reused: $IMAGE_REUSED)"
}
