# Branch Preview Deploy Kit

Press one button in GitHub Actions, get back a live URL on Railway — backend
with its own throwaway database, or a frontend served straight from its build.
Press the button again with **destroy** and it's gone, nothing left billing.
Previews also destroy themselves when their PR closes or their branch is
deleted.

Two ways to use it — both run the exact same scripts:

- **Action mode (easiest):** nothing to copy. One small workflow file points
  at this repository and GitHub fetches the kit fresh on every run.
- **Folder mode:** copy `.deploy/` into the project and own the code — works
  without this repository existing, and lets you edit the machinery.

This repository is where the kit is built and tested; it contains no app of
its own.

---

## Action mode — the 3-step setup

```
1. one file     copy templates/deploy.yml
                → your repo's .github/workflows/deploy.yml   (never edited again)
2. one config   copy .deploy/config.example.yml
                → your repo's deploy.config.yml   (often 2 lines; every default works)
3. one secret   RAILWAY_API_TOKEN in Settings → Secrets and variables → Actions
                (an ACCOUNT token from railway.com/account/tokens)

push  →  Actions → Deploy branch → Run workflow  →  URL in the run's summary
```

Kit updates arrive through the `@v2` tag in that one file — you never
re-copy anything.

## Folder mode — copy the kit in

```
1. copy      cp -r /path/to/this/.deploy  /path/to/your-project/.deploy
2. paste     cd /path/to/your-project && bash .deploy/install.sh
3. config    adjust .deploy/config.yml + add the RAILWAY_API_TOKEN secret
4. push      commit and push
5. click     Actions → Deploy branch → Run workflow
```

**Everything you configure lives in one file** — `deploy.config.yml` (action
mode) or `.deploy/config.yml` (folder mode). Secret *values* are the only
exception — they go in GitHub (Settings → Secrets and variables → Actions),
but even their *names* are declared in that same one file. No workflow ever
needs editing.

### Frontend-only project (Vite / React / Vue / …)

No Dockerfile needed — the kit ships one. The entire config is:

```yaml
build:
  dockerfile_path: .deploy/presets/frontend-static.Dockerfile
  build_args: { OUTPUT_DIR: dist }     # dist = Vite, build = CRA
```

The preset builds with `npm run build`, serves the result on Railway's port,
answers `/health` (so the default health check passes), and falls back to
`index.html` so page refreshes on client-side routes don't 404.

### Backend + MongoDB, seeded from a dump

```yaml
db:
  engine: mongo
  connection_env: MONGO_URI            # the variable your app reads
  database_name: myapp
  restore:
    tool: mongorestore
    seed_source: s3://bucket/dump.archive.gz
```

Then upload the dump once: `cp dump.archive.gz .deploy/dumps/ && bash
.deploy/upload-dump.sh` (needs the two `SEED_S3_*` secrets — see below).
In action mode there is no `.deploy/` folder in your repo — clone this kit
next to your project once and run its `upload-dump.sh` from your project's
root, or upload the dump to your bucket any way you like; only
`db.restore.seed_source` matters to the deploy.

### Keeping the built image private (Railway Pro)

By default the built image must be made **public** on GitHub (one click, the
first deploy stops with instructions) — fine for frontends, but it means
anyone can download your built backend code. On Railway Pro, keep it locked
instead:

```yaml
build:
  registry_visibility: private
```

…and add one repo secret, `GHCR_PULL_TOKEN`: a GitHub token (classic) with
the `read:packages` scope, from github.com/settings/tokens. The pipeline
hands it to Railway automatically before every deploy. **The same token works
in every repo you own** — create it once, reuse it everywhere. With this set
there is no visibility click at all: nothing about your code is ever
downloadable by anyone else.

---

## How it works, in one picture

```
 GitHub Actions: "Deploy branch"
        │
        ▼
 validate → build → provision → vars → seed → migrate → deploy → health → summary
   │          │         │         │      │        │         │        │        │
 checks     builds/   creates   applies restores runs the  points  waits    posts the
 config.yml reuses a  isolated  env     the dump migration the app for a    URL to the
 is sane    Docker    Railway   vars    into the command,  at the  real 2xx run
            image     environ-          fresh    if any    image   response summary
            (GHCR)    ment              database
```

Every step runs inside one script (`.deploy/run.sh`), in one process, with one
safety net: however the run ends — success, failure, cancel — the temporary
public database port opened for seeding is closed again automatically.

Between build and provision sits a **smoke test**: the freshly built image is
booted on the CI runner itself and must answer the health path — on the right
port, over IPv6 too — before anything is created on Railway. A misconfigured
port or a crash at startup fails in seconds with exact instructions, not
after a five-minute platform timeout.

---

## Day to day

**Deploy:** Actions → Deploy branch → pick your branch in the dropdown (that
dropdown *is* the branch picker) → Run workflow. First deploy of a branch:
roughly 4–8 minutes; later ones reuse the image when the commit hasn't changed.

**Destroy:** same workflow, same branch, **action: destroy**. Deletes the
environment, app, database and volume in one shot. `main`/`master` refuse to
be destroyed (`destroy.protected_branches`).

**Destroy is also automatic:** when a branch's pull request closes (merged
*or* abandoned), or the branch itself is deleted, the `cleanup.yml` workflow
tears its environment down by itself — a forgotten preview can't keep
billing. Pair it with GitHub's *Settings → General → "Automatically delete
head branches"* and merging a PR cleans up everything. (Event workflows run
from the default branch, so this activates once merged there.)

**From your own terminal** (nothing is GitHub-specific):

```bash
bash .deploy/run.sh validate    # check config.yml, touch nothing — run this first
bash .deploy/run.sh doctor      # validate + prove the Railway token works
bash .deploy/run.sh deploy      # the full pipeline
bash .deploy/run.sh destroy     # tear this branch's environment down

bash .deploy/selftest.sh        # is the tool itself still generic/portable?
bash .deploy/upload-dump.sh     # push a local database dump to the seed bucket
bash .deploy/update.sh          # fetch the latest kit; config.yml and dumps survive
```

| Workflow input | Meaning |
|---|---|
| `action` | `deploy` or `destroy` |
| `stage` | `preview` (default), `dev`, `prod` — which settings in `config.yml` apply |
| `seed` | Optional: a different dump for this one run (`s3://…`). Blank = config.yml |

---

## Secrets

**New developer? Follow the click-by-click guide:
[`.deploy/docs/SECRETS.md`](.deploy/docs/SECRETS.md)** — where to create each
key and where to paste it, ~5 minutes.

| Secret | When | What |
|---|---|---|
| `RAILWAY_API_TOKEN` | always | An **account** token from railway.com/account/tokens. A *project* token can't create environments. |
| `SEED_S3_ACCESS_KEY_ID` / `SEED_S3_SECRET_ACCESS_KEY` | only when seeding from S3 | **Read-only** key for the dump's bucket |
| `GHCR_PULL_TOKEN` | only with `registry_visibility: private` | GitHub token (classic, `read:packages`) so Railway can pull the locked image. One token works for every repo you own. |

Plus whatever your `config.yml` names under `env.secrets` /
`env.secrets_by_stage`. Adding one needs **no workflow edit** — name it in
config, add the value in GitHub, done.

---

## Guardrails built in

- **The image must prove itself before Railway sees it** — the smoke test
  boots it on the runner and checks the health path, port, and IPv6 binding
  (`build.smoke_test`).
- **One isolated Railway environment per branch** — app + database + network,
  named `<project>-<branch>`.
- **The database is only briefly public.** A temporary port opens to load the
  dump, then closes — via an exit trap, even on failure or cancel.
- **Re-deploying reloads the database from the dump** (set
  `db.restore.mode: once` to keep data instead).
- **Previews can't inherit production secrets by accident** — stage values in
  `config.yml` deliberately outrank generic repo secrets.
- **Previews auto-sleep when idle** (`preview_defaults.auto_sleep`), so a
  forgotten one stops burning credit.
- **Dumps never reach git** — `.deploy/dumps/` is git-ignored; dumps live in
  object storage.
- **Secrets never reach the logs** — enforced by `selftest.sh`.
- **Line endings can't break the scripts on Windows** — `.deploy/.gitattributes`
  pins everything to LF and travels with the folder.
- **One deploy at a time per branch** — a second run waits, not races.

---

## Repository layout

```
action.yml                 ← lets any repo run the kit with `uses:` (action mode)
templates/deploy.yml       ← the ONE file an action-mode project pastes in

.github/workflows/
  run.yml                  ← reusable workflow behind action mode: all trigger
                             logic (deploy button, PR-close/branch-delete cleanup)
  deploy.yml               ← installed copy of .deploy/workflow/deploy.yml (folder mode)
  cleanup.yml              ← installed copy of .deploy/workflow/cleanup.yml (folder mode)
  selftest.yml             ← CI for THIS repo only; does not travel

.deploy/
  config.yml               ← the ONLY file you edit per project
  config.example.yml       ← blank template install.sh copies from
  VERSION                  ← config-format version, checked on every run
  run.sh                   ← single entry point: deploy | destroy | validate | doctor
  install.sh               ← run once after copying the folder into a project
  update.sh                ← one-command upgrade from the kit's home repo
  SOURCE                   ← where update.sh fetches from
  upload-dump.sh           ← push a local dump to the seed bucket
  selftest.sh              ← proves the tool is still generic and complete
  .gitattributes           ← keeps scripts LF even on Windows checkouts

  presets/
    frontend-static.Dockerfile  ← ready-made Dockerfile for frontend-only projects

  lib/                     ← logging, config, secrets, the Railway API
  steps/                   ← the pipeline, one file per stage
  engines/                 ← mongo / postgres / none database drivers
  workflow/deploy.yml      ← the generic workflow (source of truth, folder mode)
  dumps/                   ← put local dumps here (git-ignored)
  docs/                    ← usage guide + new-project walkthrough
```

Only `config.yml` differs between projects. `selftest.sh` fails if anything
project-specific leaks into the machinery, and CI runs it on every push here.

---

## What's supported today

| | Status |
|---|---|
| Frontend-only (own Dockerfile) | **Proven live** — deployed, health-checked, auto-cleaned |
| Frontend preset (`presets/frontend-static.Dockerfile`) | Written and validated; first live run pending |
| MongoDB backend | Proven end-to-end |
| PostgreSQL | Driver written, not yet exercised by a real project |
| No database | Fully supported (`db.engine: none`, the default) |
| Docker build + smoke test | Proven live |
| Auto-destroy on PR close / branch delete | **Proven live** — four real cleanup runs, all green |
| Action mode (`uses:` from another repo) | Written and self-checked; first live run pending |
| Nixpacks build | Written, not yet exercised |
| One service per repo | Yes — one app (plus optionally one database) per copy of `.deploy/` |

A frontend and a backend live in **separate repos**, each with its own copy of
`.deploy/` — same tool, same button, two URLs.

### Adding another database engine

Create `.deploy/engines/<name>.sh` implementing the eight driver functions —
use `engines/postgres.sh` as the template. `selftest.sh` fails if any are
missing.

---

## When something breaks

Any failed deploy or timed-out health check prints the container's **raw
logs** — build and runtime — straight into the run. Apps often crash before
their logger starts, so **read the first lines of the runtime log first.**

| Symptom | Usually means |
|---|---|
| Health check times out | The app crashed at startup — read the runtime log. Or it isn't listening on Railway's injected `PORT`, or bound to 127.0.0.1 instead of 0.0.0.0. |
| "service unavailable" / 502 while the app runs fine | The app isn't listening where Railway knocks: its real port must equal `runtime.port`, and it must listen on IPv6 too (`[::]` — Railway probes and routes over IPv6). An nginx with only `listen 80;` needs `listen [::]:80;` added. |
| `Railway cannot pull the image` | The GHCR package is private — make it public (one-time), or use Railway Pro with registry credentials. |
| `could not open a public port` | The Railway account isn't verified — connect GitHub to Railway. |
| Restore fails | The dump is from a newer database version than `db.service_image`, or its database name differs from `db.database_name`. |
| `secret X is not set` | Add it under Settings → Secrets and variables → Actions. |
| `the dump does not exist` | It's only on your laptop — run `bash .deploy/upload-dump.sh`. |

---

## Further reading

- **[`.deploy/docs/README.md`](.deploy/docs/README.md)** — day-to-day usage
- **[`.deploy/docs/COPY-TO-NEW-PROJECT.md`](.deploy/docs/COPY-TO-NEW-PROJECT.md)** — new-project walkthrough with checklist
- **[`.deploy/dumps/README.md`](.deploy/dumps/README.md)** — why dumps live in object storage, not git
