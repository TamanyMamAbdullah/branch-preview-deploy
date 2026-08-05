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

**0. Ask the user first.** Three things cannot be read from the code. Ask them
together, wait for the answers, and start only once you have them.

*Q1 — where the repo lives:* "Is this repository under a **GitHub
organization**, or under your **personal** account?" Ask this one first — it
changes the answer to Q2.

If they say organization, ask one more thing:

> "What is **your own** GitHub username? You will make your own
> `GHCR_PULL_TOKEN` for this project — do not reuse a teammate's token, and do
> not put the organization's name here."

Write that username **verbatim** into `build.registry_username`. Never invent
one. Never copy one from an example, from another project's config, or from
anything in this repo's own docs or git history. Never fall back to the
organization name. If the answer is missing or unclear, ask again instead of
guessing. On a personal repo leave `build.registry_username` empty — the owner
name is already correct there.

*Q2 — the plan:* "Is your Railway account on **Pro** or **Free/Hobby**?"
The answer combines with Q1:

- **Personal + Free/Hobby** → `public`. Warn them the first deploy pauses once
  to have the GitHub package flipped to Public.
- **Personal + Pro** → `private` (needs the `GHCR_PULL_TOKEN` secret).
- **Organization + Free/Hobby** → `public`, with a warning that matters. An
  organization publishes the image package **private**, and an ordinary member
  usually cannot make it public. Say who has to act — an organization owner —
  and exactly what they open:
  `https://github.com/<org>/<repo>/pkgs/container/<package>` → Package
  settings → Danger Zone → Change visibility → Public. The organization may
  also have to allow public packages at all, under its Settings → Packages.
- **Organization + Pro** → `private`, `build.registry_username` set to the
  username from Q1, and the user's **own** token added as a **repository**
  secret named `GHCR_PULL_TOKEN`. Do not suggest an organization-wide secret,
  and do not suggest borrowing a teammate's token. `.deploy/docs/SECRETS.md`
  explains why, and lists what an organization has to allow first.

*Q3 — the database:* "Every preview branch gets its own throwaway database,
created fresh and deleted with the preview. Do you want **A — none** (no
database, or the app uses one that already exists elsewhere), **B — empty**
(its own database, starting blank), or **C — able to load a dump** (same as B,
plus you can pick a dump file to load when you press the deploy button —
previews still start empty unless you name one)?"

- **A** → `db.engine: none`, and nothing else in the `db:` block matters.
- **B** → set `db.engine`, `db.connection_env` (the EXACT variable the app
  reads), `db.database_name`, `db.service_image`. Leave `restore.tool: none`.
  No bucket and no keys are involved.
- **C** → everything in B, plus Q4.

These answers **beat anything you infer from the code.** A project that has a
database in development may deliberately not want one cloned into previews.

*Q4 — only for answer C.* First understand how dumps work here, because it
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

*Q5 — only when this is a frontend* (Vite, CRA, Vue, Svelte…):

**Do not ask them to paste URLs.** Find the shape in the code, ask only for the
naming rule, and build every environment's URL from tokens.

**First, read it out of the project.** The app already calls a backend. Look in
`.env.example`, `.env*`, and wherever the HTTP client is created (`src/api*`,
`src/lib/axios*`, `src/services/*`, `vite.config.*`) for the variable holding
it and its current value. That gives you the variable NAME (e.g.
`VITE_BASE_URL`) and the URL SHAPE. Take both from the code — never invent
either, and never rename their variable.

**Then ask only what the code cannot tell you:**

> "I found `<VARIABLE>` pointing at `<the value you found>`. Two things:
> 1. Does the backend have a different address per environment (preview, dev,
>    prod), or does everything talk to one backend?
> 2. If it differs — what changes between them? The subdomain
>    (`api-staging` / `api-prod`), the branch name, or something else? Give me
>    the **rule**, not a list of URLs."

**Then build the value from tokens**, so it resolves itself on every deploy and
nobody edits config again. Hardcoding a stage name into the URL is the mistake
this avoids:

| What changes between environments | What to write |
|---|---|
| Nothing — one shared backend | the value you found, unchanged |
| The stage name is in the host | `https://api-${STAGE}.<their domain>` |
| The branch name is in the host | `https://api-${BRANCH_SLUG}.<their domain>` |
| The project name is in the host | `https://api-${PROJECT_NAME}.<their domain>` |

Available tokens: `${STAGE}`, `${BRANCH_SLUG}`, `${BRANCH}`, `${ENV_NAME}`,
`${PROJECT_NAME}`, `${SHA7}`.

**One case where no pattern exists:** if the backend is deployed by this kit and
uses Railway's *generated* domain, that hostname carries a random part and
cannot be derived from anything. Do not try. Say so plainly and point previews
at one fixed backend using the runtime option below.

Now the trap that decides how you write it: `VITE_*` and `REACT_APP_*` values
are **compiled into the JavaScript at build time**. Setting them on the Railway
service afterwards does nothing at all. The usual report is "Railway won't let
me change the variable" — the variable is fine; the value was frozen into the
bundle.

Pick from their answer:

- **A pattern exists** → bake it. `build_args` values go through the same token
  substitution, so one line covers every stage. Use THEIR variable name:
  ```yaml
  build:
    build_args:
      BUILD_TIME_ENV: "VITE_BASE_URL=https://api-${STAGE}.example.com"
  ```
- **No pattern, or it must stay changeable after the deploy** → move that name
  from `BUILD_TIME_ENV` to `RUNTIME_ENV`, same format, same place:
  ```yaml
  build:
    build_args:
      BUILD_TIME_ENV: "VITE_ENV=${BRANCH_SLUG}"
      RUNTIME_ENV: "VITE_BASE_URL=https://api-staging.example.com"
  ```
  That value becomes the default, and stays editable: whoever needs a different
  backend sets a `RUNTIME_ENV` variable on that Railway environment and
  restarts. No rebuild, no redeploy, no config edit.

  **Change nothing in the app for this.** The preset builds a marker into the
  bundle in place of the value and rewrites it at container start, so the code
  still reads `import.meta.env.VITE_BASE_URL` and `npm run dev` is unaffected.
  Do not add a `window.__ENV__` lookup, and do not touch the project's env
  module — that would break hard rule 1 for no reason.

  A name goes in `BUILD_TIME_ENV` **or** `RUNTIME_ENV`, never both. And if the
  project validates its env *while building* rather than in the browser, the
  marker fails that check — keep those in `BUILD_TIME_ENV`.

Never put a secret in `build_args` — build args stay readable inside the image.

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
   - `build.registry_visibility` and `build.registry_username` come from the
     step-0 answers, not from the code. `private` needs Railway Pro; on an
     organization it also needs `registry_username` set to the username the
     user gave you.

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
      `registry_visibility: private` — and on an organization, say plainly
      that this must be **their own** token, made by the account named in
      `build.registry_username`, added to this repository only.
      `SEED_S3_ACCESS_KEY_ID` and
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
