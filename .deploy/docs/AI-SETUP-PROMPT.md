# AI setup prompt

Just copied `.deploy/` into a project? Paste everything below the line into
any AI assistant that can read files and run commands (Claude Code, Cursor,
Copilot…). It will configure the deployment and hand you a short human
checklist for the parts only a person can do (secrets, clicking the button).

If your AI can read files itself, this is enough:

> Read `.deploy/docs/AI-SETUP-PROMPT.md` and do exactly what it says.

---

You are configuring an automated Railway deployment for this project. The
`.deploy/` folder is a finished, tested deployment tool (it deploys via a
GitHub Actions button). Your ONLY job is to configure it for this project.
Do not redesign it, do not "improve" it.

## Hard rules — read twice

1. **The project is READ-ONLY.** Never modify, create, delete, or reformat
   any file outside `.deploy/`. Not package.json, not source code, not an
   existing Dockerfile, not docker-compose files, not `.env*` files.
   One exception: running `bash .deploy/install.sh` creates
   `.github/workflows/deploy.yml` — that is expected and allowed.
2. **Inside `.deploy/` you may edit ONLY `config.yml`**, and if truly needed
   create ONE new file: `.deploy/Dockerfile.app` (see step 3). Never edit the
   machinery (`run.sh`, `lib/`, `steps/`, `engines/`, `presets/`, workflow).
   `bash .deploy/selftest.sh` must still pass when you are done.
3. **Never write a secret VALUE anywhere** — not in config, not in files, not
   in your final message. Config takes secret NAMES only.
4. If the correct setup requires changing a project file (see the IPv6 note
   below), do NOT change it — put the exact file, line, and reason into your
   final instructions for the user instead.

## Steps

**1. Install.** Run `bash .deploy/install.sh` once.

**2. Study the project (read-only).** Establish, from the actual code, not
guesses: the framework and package manager; the build/start scripts; any
existing Dockerfiles (dev vs production!); which env variables the app reads
and which have NO defaults (look for an env schema, config module, or
`.env.example`); the port the app really listens on (an env var like PORT, or
a hardcoded number — check nginx configs for `listen`); whether a health
endpoint exists and its exact path; whether routes sit behind a prefix like
`/api/v1`; database engine, connection variable, and migration command if any.

**3. Dockerfile decision — in this order:**
   - A production-ready Dockerfile exists → use it untouched. Set
     `build.dockerfile_path` (and `build.target` if it has a production
     stage). Never point at a dev Dockerfile.
   - No Dockerfile and it's a static frontend (Vite/CRA/Vue/Svelte…) → use
     the shipped preset: `build.dockerfile_path:
     .deploy/presets/frontend-static.Dockerfile`, with
     `build_args: { OUTPUT_DIR: dist }` (`build` for CRA). Frontend env vars
     (`VITE_*`, `REACT_APP_*`) are baked at build time — pass them via
     `build_args: { BUILD_TIME_ENV: "VITE_X=… VITE_Y=…" }`, never as runtime
     variables and never secrets.
   - No Dockerfile and it's a backend → create `.deploy/Dockerfile.app`
     (inside `.deploy/`, so the project stays untouched) and point
     `build.dockerfile_path` at it. Multi-stage, production dependencies
     only, and the app must read the port from the env var named in
     `runtime.port_env`.

**4. Fill `.deploy/config.yml` fully.** The ★-marked lines are the ones that
vary; recipes are at the top of the file. Get these right:
   - `runtime.port` — the port the app REALLY listens on. App reads PORT →
     keep 8080. Hardcoded (e.g. nginx `listen 80;`) → set that number.
   - **IPv6, critical:** Railway's healthchecks and routing connect over
     IPv6. If the app's server config listens IPv4-only (nginx `listen 80;`
     with no `listen [::]:80;`), the deploy will run and still serve 502.
     Do not edit the project file — write the exact one-line fix into your
     final user instructions. (The shipped preset already handles IPv6.)
   - `runtime.health_check_path` — a path that truly returns 200, checked
     against where it sits relative to any base path. For an SPA, `/` works.
   - `runtime.base_path` or `base_path_env` if routes sit behind a prefix.
   - Backends with a database: `db.engine`, `db.connection_env` (the EXACT
     variable the app reads), `db.database_name`, a `db.service_image`
     version matching what the project uses, and `db.migrate.command` if the
     project has migrations (e.g. `npx prisma migrate deploy`). Leave
     restore/seed settings alone unless the project has a dump workflow.
     Never list `db.connection_env` under `env.secrets` — it is provisioned.
   - `env.static` for plain values every stage needs (e.g. `NODE_ENV:
     production`). `env.secrets` = the NAMES of variables that are required
     but secret (the env schema's no-default entries are your list).
   - `build.registry_visibility`: `private` if this is closed-source backend
     code and the user has Railway Pro; otherwise `public`.

**5. Verify before reporting.** Run `bash .deploy/run.sh validate` — fix
config until it passes. Missing-secret errors are expected locally; you may
prove the rest passes with throwaway env values, e.g.
`JWT_SECRET=x bash .deploy/run.sh validate`. Then run
`bash .deploy/selftest.sh` — it must pass. If you created
`.deploy/Dockerfile.app`, sanity-check it builds if docker is available.

**6. Final report — write it for a non-expert, numbered, complete:**
   1. What you configured and why, in two or three sentences.
   2. Every secret NAME to add, with where to get each value — GitHub repo →
      Settings → Secrets and variables → Actions; full walkthrough exists at
      `.deploy/docs/SECRETS.md`. `RAILWAY_API_TOKEN` is always needed
      (an ACCOUNT token). `GHCR_PULL_TOKEN` only if you set
      `registry_visibility: private`.
   3. Any one-line project change you were not allowed to make (file, exact
      line, one-sentence reason).
   4. Commit and push, then: GitHub → Actions → "Deploy branch" → pick the
      branch → Run workflow. The URL appears at the top of the run summary.
   5. Optional hardening: after the first deploy, the run prints the Railway
      project id — pasting it into `railway.project_id` in
      `.deploy/config.yml` pins the project (later runs reuse it by name
      automatically; the pin just also survives a project rename).
