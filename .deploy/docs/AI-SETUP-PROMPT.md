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

**0. Ask the user first.** Two things cannot be read from the code. Ask both,
wait for the answers, and start only once you have them.

*Q1 — the plan:* "Is your Railway account on **Pro** or **Free/Hobby**?"
Pro → `build.registry_visibility: private` (needs the `GHCR_PULL_TOKEN`
secret). Free → `public`, and warn them the first deploy pauses once to have
the GitHub package flipped to Public.

*Q2 — the database:* "Every preview branch gets its own throwaway database,
created fresh and deleted with the preview. Do you want **A — none** (no
database, or the app uses one that already exists elsewhere), **B — empty**
(its own database, starting blank), or **C — able to load a dump** (same as B,
plus you can pick a dump file to load when you press the deploy button —
previews still start empty unless you name one)?"

- **A** → `db.engine: none`, and nothing else in the `db:` block matters.
- **B** → set `db.engine`, `db.connection_env` (the EXACT variable the app
  reads), `db.database_name`, `db.service_image`. Leave `restore.tool: none`.
  No bucket and no keys are involved.
- **C** → everything in B, plus Q3.

These answers **beat anything you infer from the code.** A project that has a
database in development may deliberately not want one cloned into previews.

*Q3 — only for answer C.* First understand how dumps work here, because it
changes what you ask. **Nobody writes a URL.** One bucket holds the dumps for
every project; each project reads from its own folder inside it, named
automatically after `project.name`:

```
s3://<bucket>/<project.name>/<file>
```

Uploading is manual and stays manual. Loading is chosen per deploy: the
"Deploy branch" button has a **dump** box, you type a **file name** into it,
and leaving it blank starts the database empty — the default.

Ask all three at once:
1. Which database and which version made the export (e.g. "MongoDB 7")? The
   preview's `db.service_image` must be that version or newer, or the restore
   fails.
2. How was the export made? The exact command if they have it, otherwise the
   file name.
3. Which bucket holds your dumps, and who hosts it? The bucket NAME only — the
   folder is derived. If it is not Amazon S3 (IDrive e2, Cloudflare R2,
   Backblaze B2, MinIO…), the endpoint URL from that provider's dashboard.
   The same bucket should serve every project.

Map answer 2 onto `db.restore`:

| How the export was made | `tool` | `format` | `gzip` |
|---|---|---|---|
| `mongodump --archive=x.gz --gzip` | `mongorestore` | `archive` | `true` |
| `mongodump --archive=x` | `mongorestore` | `archive` | `false` |
| `mongodump --out=folder/` (folder of `.bson`) | `mongorestore` | `directory` | `false` |
| `pg_dump -Fc` (`.dump`, `.backup`) | `pg_restore` | `custom` | `false` |
| `pg_dump -Fd` (a folder) | `pg_restore` | `directory` | `false` |
| `pg_dump` plain `.sql` | `psql` | `plain` | `false` |
| plain `.sql.gz` | `psql` | `plain` | `true` |

`pg_dump -Fc` is compressed internally, so `gzip` stays `false`. Any other
combination is unsupported — say so instead of guessing.

Answer 3 sets `restore.bucket`, plus `restore.s3_endpoint` for non-Amazon
storage. Set **nothing else** about location — leave `folder`, `default_dump`
and `seed_source` empty. An empty `default_dump` is exactly what makes previews
start blank. Using a bucket also means two extra secret rows in your final
report: `SEED_S3_ACCESS_KEY_ID` and `SEED_S3_SECRET_ACCESS_KEY`, read-only keys
for that bucket.

Your final report must then tell them, filled in with the real bucket and real
project name, not as a template:

- **Upload dumps to** `<bucket>/<project.name>/`, with the finished command,
  not a template. Say to use the AWS CLI rather than the web dashboard — a
  browser sends the file in one request and large dumps fail, while the CLI
  splits and retries. Nothing to create first: S3 has no real folders, so the
  path appears on its own.
  ```bash
  aws s3 cp yourdump.archive.gz s3://<bucket>/<project.name>/yourdump.archive.gz \
    --endpoint-url <their endpoint>
  ```
  Drop `--endpoint-url` for Amazon S3. `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` must be set first, with a key that can WRITE — the
  two GitHub secrets only need read.
- **The one file shape this project accepts**, matching the `format`/`gzip`
  you set — e.g. "a gzipped mongodump archive, from
  `mongodump --archive=NAME.archive.gz --gzip`". Name that one only.
- **Names are free** (`baseline.archive.gz`, `2026-08-with-orders.archive.gz`)
  and many can sit side by side, because the name is how you pick one.
- **To load one:** Actions → "Deploy branch" → Run workflow → type the file
  name into the **dump** box. Blank = empty database, which is the normal case.
- In FOLDER mode only, `bash .deploy/upload-dump.sh yourfile.gz` does the same
  without typing the path. In ACTION mode there is no `.deploy/` folder, so the
  `aws s3 cp` line is the way — and every deploy summary reprints it with this
  project's bucket, folder and endpoint already filled in.

Two more things to tell them for answer C: if the database name inside the
export differs from `db.database_name`, Mongo needs
`extra_args: ["--nsFrom=old.*", "--nsTo=new.*"]`; and a dump taken straight
from production puts real customer data into previews that anyone with the
link can open — recommend a small scrubbed dump instead.

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
   - The whole `db:` block comes from the user's step-0 answers, not from the
     code. Add `db.migrate.command` if the project has migrations (e.g. `npx
     prisma migrate deploy`). Never list `db.connection_env` under
     `env.secrets` — the machinery provisions it.
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
      `registry_visibility: private`. `SEED_S3_ACCESS_KEY_ID` and
      `SEED_S3_SECRET_ACCESS_KEY` only if the database is seeded from an
      `s3://` export — read-only keys for that bucket.
   3. Any one-line project change you were not allowed to make (file, exact
      line, one-sentence reason).
   4. Commit and push, then: GitHub → Actions → "Deploy branch" → pick the
      branch → Run workflow. The URL appears at the top of the run summary.
   5. Optional hardening: after the first deploy, the run prints the Railway
      project id — pasting it into `railway.project_id` in
      `.deploy/config.yml` pins the project (later runs reuse it by name
      automatically; the pin just also survives a project rename).
