# Adding this to another project

Copy one folder. Run one command. Adjust one file — often by two lines.

> **Shortcut:** have an AI assistant do steps 1–2 for you. Tell it:
> *"Read `.deploy/docs/AI-SETUP-PROMPT.md` and do exactly what it says."*
> It configures everything it can and hands you a checklist for the rest.

Frontend-only projects: about 5 minutes. Backend with a database: about 15.

---

## 1. Copy the folder, run the installer

```bash
cp -r /path/to/existing/.deploy /path/to/new-project/.deploy
cd /path/to/new-project
bash .deploy/install.sh
```

`install.sh` puts the workflow where GitHub can see it (`.github/workflows/` —
the one place that can't live inside the folder), creates the dumps folder,
makes a `config.yml` from the template, and runs the self-test.

It **never** overwrites an existing `config.yml`.

> **Don't edit anything inside `.deploy/` except `config.yml`.** Everything
> else is identical in every project — that's what makes upgrading a folder
> copy. `bash .deploy/selftest.sh` fails if project-specific values creep in.

---

## 2. Adjust `.deploy/config.yml`

**Every default already works.** You only change what your project needs.
Both common setups are spelled out as recipes at the top of the file:

### Frontend-only (Vite / React / Vue / any static build)

```yaml
build:
  dockerfile_path: .deploy/presets/frontend-static.Dockerfile
  build_args: { OUTPUT_DIR: dist }     # dist = Vite, build = CRA
```

That's the entire configuration. The preset serves the build on Railway's
port, answers `/health`, and falls back to `index.html` for app routes.
Frontend env vars (`VITE_*`…) are baked at **build** time — pass them via
`build_args: { BUILD_TIME_ENV: "VITE_API_URL=https://…" }`, never as secrets.

### Backend with a database

```yaml
db:
  engine: mongo                        # or postgres
  connection_env: MONGO_URI            # the variable your app reads
  database_name: myapp
  restore:
    tool: mongorestore
    seed_source: s3://bucket/dump.archive.gz
```

### Worth checking either way

- **`project.name`** — empty means "use the repo's name". Set it only if you
  want a different one. Lowercase, digits, dashes, under ~20 characters.
- **`railway.project_id`** — leave empty: the first deploy creates a Railway
  project and prints its id. **Paste that id back in**, or every deploy makes
  another new project.
- **`runtime.health_check_path`** — the *literal* path returning 200.
  `/health` by default; the frontend preset serves it. Wrong value = deploys
  hang until timeout.
- **`runtime.base_path` / `base_path_env`** — if routes sit behind a prefix
  (`/api/v1`), say so, and the deploy reports a URL you can actually paste
  into Postman. Not fatal to skip — just a confusing 404 on the bare domain.
- **`runtime.port_env`** — Railway injects `PORT`; the app must read it.
- **`build.reuse_tag_templates`** — if this repo's CI already builds images,
  put its tag pattern here. **The single biggest speed-up available.**
- **`db.service_image`** — must be **at least** the version that produced the
  dump (`upload-dump.sh` checks this and warns).
- **`db.migrate.command`** — leave `""` if there are no migrations; that's a
  supported, documented skip.
- **`build.registry_visibility`** — `public` means anyone can download the
  built image (fine for frontends; the first deploy pauses once until you flip
  the GitHub package to Public). On Railway Pro, set `private` and add the
  `GHCR_PULL_TOKEN` secret: the image stays locked, Railway logs in to pull
  it, and there is no visibility click at all.
- **`preview_defaults.env`** — where a preview differs from production. Put
  the throwaway storage bucket here, in plain sight, so anyone can confirm
  previews never touch production storage.

---

## 3. Add the secrets

**Click-by-click guide with screenshots-level detail: [`SECRETS.md`](SECRETS.md).**
Short version: **Settings → Secrets and variables → Actions**

| Secret | When |
|---|---|
| `RAILWAY_API_TOKEN` | Always. An **account** token from railway.com/account/tokens — a *project* token can't create environments. |
| `SEED_S3_ACCESS_KEY_ID` / `SEED_S3_SECRET_ACCESS_KEY` | Only when seeding a database from S3. Read-only key. |
| `GHCR_PULL_TOKEN` | Only with `build.registry_visibility: private` (Railway Pro). A GitHub token (classic) with the `read:packages` scope — the same token works in every repo you own. |

Plus every name from `env.secrets` / `env.secrets_by_stage`.

**No workflow edit needed.** Naming a secret in `config.yml` is enough; a
missing one is caught by the validator before anything is created.

---

## 4. Seeding? Get the dump into the bucket

```bash
cp yourdump.archive.gz .deploy/dumps/
export SEED_S3_ACCESS_KEY_ID=...        # a key that can WRITE
export SEED_S3_SECRET_ACCESS_KEY=...
bash .deploy/upload-dump.sh
```

**The dump cannot live in the repo** — CI clones from GitHub, so a local file
isn't there, and committing it would grow the history forever. See
`.deploy/dumps/README.md`. CI itself only needs a **read-only** key.

Skip this section entirely for frontend or no-database projects.

---

## 5. Try it

```bash
bash .deploy/run.sh validate
```

Prints every variable that would be applied, secrets masked. Read the list —
it's the fastest way to spot a wrong bucket or missing prefix.

Then commit, push, and run **Actions → Deploy branch → Run workflow**.

**First deploy only:** copy the printed Railway project id into `config.yml`.
And with `registry_visibility: public`, GitHub creates the image package
private, so the run stops once with exact instructions to flip it to Public
(one click, stays fixed) — with `private` (Railway Pro) this step doesn't
exist.

**Destroy the preview when you're done.**

---

## Upgrading the kit later

One command, from inside the project:

```bash
bash .deploy/update.sh
```

It fetches the newest kit from its home repository (recorded in
`.deploy/SOURCE`), replaces every machinery file, **keeps your `config.yml`
and your dumps untouched**, and refreshes the installed workflow. Then review
`git diff`, commit, push.

It can also update from a different URL or a local checkout:

```bash
bash .deploy/update.sh /path/to/kit-checkout
```

If the new machinery expects a newer config format, the version numbers won't
match: `update.sh` warns immediately, and every run stops with a clear message
until you adjust. Nothing is changed or lost when that happens — compare your
`config.yml` with the new `config.example.yml` and set its `version:` to match
`.deploy/VERSION`.

---

## Checklist

- [ ] `.deploy/` copied; `bash .deploy/install.sh` run
- [ ] `config.yml` adjusted (frontend: preset recipe; backend: `db:` block)
- [ ] `RAILWAY_API_TOKEN` (an **account** token) added as a repo secret
- [ ] Every `env.secrets` name added as a repo secret
- [ ] Seeding only: dump uploaded (`bash .deploy/upload-dump.sh`), `SEED_S3_*` secrets added, database image version ≥ the dump's
- [ ] Health check path is the literal path returning 200
- [ ] `bash .deploy/run.sh validate` passes
- [ ] After the first deploy: image package set to Public, Railway project id pasted into `config.yml`
