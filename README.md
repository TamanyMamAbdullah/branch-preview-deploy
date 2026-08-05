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

## 🤖 Fastest start — one copy-paste into an AI

Using Claude Code, Cursor, or GitHub Copilot? You don't have to configure
anything yourself. Open your AI assistant **in the root folder of the project
you want to deploy**, copy the prompt below, paste it in. The AI installs the
kit, studies your project, fills in the config, verifies its own work, and
hands you a short table of the keys only a human can add — with where to get
each one.

<details>
<summary><b>👉 Click to open the prompt — then hover the block and press the copy icon in its top-right corner</b></summary>

````markdown
You are setting up push-button Railway deployments for THIS project using the
**Branch Preview Deploy kit** — a finished, tested tool. One click in GitHub
Actions deploys any branch to Railway (backend with its own throwaway
database, or a frontend served from its build) and returns a live URL; the
preview destroys itself when its PR closes or its branch is deleted.

Kit home: https://github.com/TamanyMamAbdullah/branch-preview-deploy.git

Your ONLY job is to install and configure the kit for this project. Do not
redesign it, do not "improve" it, do not edit its machinery.

## Step 0 — ask the user these questions before touching anything

Ask them together, wait for the answers, and do not start until you have them.
Nothing below can be guessed from the code.

### Q1 — where this repository lives

> Is this repository under a **GitHub organization**, or under your
> **personal** account?

Ask this one first: it changes the answer to Q2. If they say organization,
ask one more thing:

> What is **your own** GitHub username? You will make your own
> `GHCR_PULL_TOKEN` for this project — do not reuse a teammate's token, and do
> not put the organization's name here.

Write that username **verbatim** into `build.registry_username`. Never invent
one. Never copy one from an example, from another project's config, or from
anything you read in the kit's own docs or git history. Never fall back to the
organization name. If the answer is missing or unclear, ask again instead of
guessing. On a personal repo leave `build.registry_username` empty — the owner
name is already correct there.

### Q2 — the Railway plan

> Is your Railway account on the **Pro** plan or the **Free/Hobby** plan?
> (Not sure? Check railway.com → your avatar → Account Settings → Plans.)

Combine the answer with Q1:

- **Personal + Pro** → set `build.registry_visibility: private` — for BOTH
  frontend and backend projects. The built Docker image stays locked on
  GitHub; nobody can ever download it. This requires the `GHCR_PULL_TOKEN`
  secret (row 2 of the final table).
- **Personal + Free/Hobby** → set `build.registry_visibility: public`. Warn
  the user in your final report: the very first deploy pauses once with
  instructions to flip the GitHub package to Public (one click), then re-run.
- **Organization + Free/Hobby** → `public`, plus a warning that matters. An
  organization publishes the image package **private**, and an ordinary member
  usually cannot make it public. Say who has to act — an organization owner —
  and exactly what they open:
  `https://github.com/<org>/<repo>/pkgs/container/<package>` → Package
  settings → Danger Zone → Change visibility → Public. The organization may
  also have to allow public packages at all, under its Settings → Packages.
- **Organization + Pro** → `private`, `build.registry_username` set to the
  username from Q1, and the user's **own** token added as a **repository**
  secret named `GHCR_PULL_TOKEN`. Do not suggest an organization-wide secret,
  and do not suggest borrowing a teammate's token.

### Q3 — the database

> Every preview branch gets its own throwaway database, created fresh and
> deleted with the preview. Which do you want?
>
> **A — None.** The app has no database, or it talks to one that already
> exists elsewhere (you pass its connection string as a secret).
> **B — Empty.** Give each preview its own database, but start it blank.
> **C — Able to load a dump.** Same as B, plus you can pick a dump file to
> load when you press the deploy button. Previews still start empty by
> default — data arrives only when you ask for it by name.

Set the config from the answer:

- **A** → `db.engine: none`. Skip the rest of this question.
- **B** → set `db.engine`, `db.connection_env` (the EXACT variable the app
  reads), `db.database_name`, and `db.service_image`. Leave
  `db.restore.tool: none`. Nothing else is needed — no bucket, no keys.
- **C** → everything in B, plus Q4 below.

For A and B you are done with the database. Go to Step 1.

### Q4 — only if the answer to Q3 was C

**How dumps work here — understand this before you ask.** You never write a
URL. One bucket holds the dumps for every project, and each project reads from
its own folder inside it, named automatically after `project.name`:

```
s3://<bucket>/<project.name>/<file>
```

Uploading is manual and always will be — you put files in that folder yourself.
Loading is a choice made at deploy time: the "Deploy branch" button has a
**dump** box, and you type a **file name** into it (`baseline.archive.gz`).
Leave the box blank and the database starts empty. That is the default.

Ask all three at once:

> 1. **Which database, and which version made the export?** e.g. "MongoDB 7"
>    or "PostgreSQL 16". I need the version because the preview's database
>    must be the same or newer, or the restore fails.
> 2. **How was the export made?** Paste the exact command if you have it —
>    e.g. `mongodump --archive=dump.gz --gzip`, or `pg_dump -Fc`. If you only
>    know the file name, tell me that (`dump.archive.gz`, `db.sql`, a folder…).
> 3. **Which bucket holds your dumps, and who hosts it?** Just the bucket
>    name — I work out the folder myself. If it is NOT Amazon S3 (IDrive e2,
>    Cloudflare R2, Backblaze B2, MinIO…), paste the endpoint URL from that
>    provider's dashboard. Use the same bucket for every project.

Then fill `db.restore` from the answers. Answer 1 sets `db.service_image` to
that version **or newer** (`mongo:8`, `postgres:16`). Answer 2 maps to the
tool and format:

| How the export was made | `tool` | `format` | `gzip` |
|---|---|---|---|
| `mongodump --archive=x.gz --gzip` | `mongorestore` | `archive` | `true` |
| `mongodump --archive=x` | `mongorestore` | `archive` | `false` |
| `mongodump --out=folder/` (folder of `.bson`) | `mongorestore` | `directory` | `false` |
| `pg_dump -Fc` (`.dump`, `.backup`) | `pg_restore` | `custom` | `false` |
| `pg_dump -Fd` (a folder) | `pg_restore` | `directory` | `false` |
| `pg_dump` plain `.sql` | `psql` | `plain` | `false` |
| plain `.sql.gz` | `psql` | `plain` | `true` |

`pg_dump -Fc` is already compressed internally — leave `gzip: false` for it.
Anything else is unsupported; say so rather than guessing.

Answer 3 sets `bucket` and, for non-Amazon storage, `s3_endpoint`. Leave
`default_dump` empty — that is what makes previews start empty, which is the
behaviour we want.

**Never set `seed_source`.** It is an escape hatch for a dump living outside
the bucket, and it outranks everything else: with it set, the deploy button's
dump box is read and then ignored, so the user types names into a box that
silently does nothing. `bucket` is the default and the only thing to write.

`folder` is the single exception. It defaults to `project.name`. If the objects
already sit in a folder with a different name — check what the user actually
has, never assume — set `folder` to that real name. A `project.name` of
`vod-admin-api` will not find objects stored under `vod-api-admin-test/`, and
the failure just looks like a missing dump.

A finished block looks like:

```yaml
db:
  engine: mongo
  connection_env: DB_MONGO_URI
  service_image: mongo:8
  database_name: myapp
  restore:
    tool: mongorestore
    format: archive
    gzip: true
    mode: always                # reload the chosen dump on every deploy
    bucket: my-team-seeds       # the SAME line in every project
    s3_endpoint: https://xxxx.idrivee2-yy.com   # omit entirely for Amazon S3
    s3_region: us-east-1
```

Two more things you must do for answer C:

- Add `SEED_S3_ACCESS_KEY_ID` and `SEED_S3_SECRET_ACCESS_KEY` as rows in your
  final table (read-only keys for that bucket).
- If the database name INSIDE the export differs from `db.database_name`, say
  so in your report — for Mongo the fix is
  `extra_args: ["--nsFrom=old.*", "--nsTo=new.*"]`.

And warn them once, in plain words: a dump taken straight from production
puts real customer data into preview environments that anyone with the link
can open. Recommend a small scrubbed dump instead.

### Q5 — only if this is a frontend (Vite / CRA / Vue / Svelte)

**Do not ask them to paste URLs.** Find the shape in the code, ask only for the
naming rule, and build every environment's URL from tokens.

**First, read it out of the project.** The app already calls a backend. Look in
`.env.example`, `.env*`, and wherever the HTTP client is created (`src/api*`,
`src/lib/axios*`, `src/services/*`, `vite.config.*`) for the variable holding it
and its current value. That gives you the variable NAME (e.g. `VITE_BASE_URL`)
and the URL SHAPE. Take both from the code — never invent either, and never
rename their variable.

**Then ask only what the code cannot tell you:**

> I found `<VARIABLE>` pointing at `<the value you found>`. Two things:
> 1. Does the backend have a different address per environment (preview, dev,
>    prod), or does everything talk to one backend?
> 2. If it differs — what changes between them? The subdomain (`api-staging` /
>    `api-prod`), the branch name, or something else? Give me the **rule**, not
>    a list of URLs.

**Then build the value from tokens**, so it resolves itself on every deploy:

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
cannot be derived. Do not try — say so, and point previews at one fixed backend
with the runtime option below.

**The trap that decides how you write it:** `VITE_*` and `REACT_APP_*` values are
compiled into the JavaScript **at build time**. Setting them on the Railway
service afterwards does nothing. Users report this as "Railway won't let me
change the variable" — the variable is fine; the value was frozen into the
bundle.

- **A pattern exists** → bake it. `build_args` go through the same token
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
  That becomes the default and stays editable: set a `RUNTIME_ENV` variable on
  any Railway environment and restart to point it somewhere else. No rebuild.

  **Change nothing in the app for this.** The preset builds a marker into the
  bundle in place of the value and rewrites it at container start, so the code
  still reads `import.meta.env.VITE_BASE_URL` and `npm run dev` is unaffected.
  A name goes in one list or the other, never both — and if the project
  validates its env *while building* rather than in the browser, keep it in
  `BUILD_TIME_ENV`.

Never put a secret in `build_args` — they stay readable inside the image.

## Step 1 — fetch the kit from GitHub into this project

```bash
git clone --depth 1 https://github.com/TamanyMamAbdullah/branch-preview-deploy.git /tmp/bpd-kit
cp -r /tmp/bpd-kit/.deploy ./.deploy
rm -rf /tmp/bpd-kit
bash .deploy/install.sh
```

(On Windows, run these in Git Bash. `install.sh` creating
`.github/workflows/deploy.yml` and `.deploy/config.yml` is expected.)

## Step 2 — hard rules (they apply to everything you do from here)

1. **The project's own files are READ-ONLY.** Never modify, create, delete,
   or reformat anything outside `.deploy/`. Not package.json, not source
   code, not an existing Dockerfile, not `.env*` files. The one exception is
   the workflow file `install.sh` just created.
2. **Inside `.deploy/` you may edit ONLY `config.yml`**, and if truly needed
   create ONE new file, `.deploy/Dockerfile.app`. Never touch `run.sh`,
   `lib/`, `steps/`, `engines/`, `presets/`, or the workflow files.
3. **Never write a secret VALUE anywhere** — not in config, not in files,
   not in your final message. The config takes secret NAMES only.
4. If a correct setup would require changing a project file (e.g. an nginx
   config that listens on IPv4 only — Railway health-checks over IPv6), do
   NOT change it. Put the exact file, line, and reason into your final
   report instead.

## Step 3 — configure

Read `.deploy/docs/AI-SETUP-PROMPT.md` (now inside this project) and follow
its steps 2–5 exactly. In short: study the project read-only (framework,
build/start scripts, real port, health path, env variables with no defaults,
database engine + connection variable + migrations); pick the Dockerfile in
this order — existing production Dockerfile → the shipped frontend preset
(`.deploy/presets/frontend-static.Dockerfile`) for static frontends → write
`.deploy/Dockerfile.app` for backends; then fill `.deploy/config.yml` fully
(the ★-marked lines). Three overrides on that doc:

- `build.registry_visibility` and `build.registry_username` come from the
  user's Step-0 answers — Pro = `private` for frontend AND backend, Free =
  `public`; and on an organization, `registry_username` is the username they
  gave you in Q1.
- The whole `db:` block comes from the user's Q3/Q4 answers above. Those
  answers win over anything you infer from the code — the project may well
  have a database it does NOT want cloned into every preview.
- Your final report must end with the table defined in Step 5 below.

## Step 4 — verify before reporting

- `bash .deploy/run.sh validate` must pass. Missing-secret errors are
  expected locally — prove the rest passes with throwaway values, e.g.
  `JWT_SECRET=x bash .deploy/run.sh validate`.
- `bash .deploy/selftest.sh` must pass.
- If you created `.deploy/Dockerfile.app` and docker is available, check
  that it builds.

Fix the config until all of that is green. Do not report success otherwise.

## Step 5 — final report (write it for a non-expert)

1. Two or three sentences: what you configured and why (frontend or backend,
   which Dockerfile, which database, private or public image).
2. Any one-line project change you were not allowed to make (file, exact
   line, one-sentence reason).
3. **The keys table.** List ONLY the rows that apply to this project, plus
   one row for every name you put under `env.secrets` in the config. Keep
   the "Where to get it" and "How" columns filled in:

   | Key to add | Needed? | Where to get it | How |
   |---|---|---|---|
   | `RAILWAY_API_TOKEN` | Always | railway.com/account/tokens | Create a token scoped to your **account** (a project token cannot create environments and will fail). Copy the value immediately — it is shown only once. |
   | `GHCR_PULL_TOKEN` | Only when the image is private (Railway Pro) | github.com/settings/tokens → "Generate new token (classic)" | Tick **only** the `read:packages` box. Expiration: "No expiration". Copy immediately. Make **your own** — never reuse a teammate's, and never ask for an organization-wide secret. Under an organization, the account also needs read access to the package, the org must allow classic tokens, and single sign-on (if used) must be authorized for the token. Full guide: `.deploy/docs/SECRETS.md`. |
   | `SEED_S3_ACCESS_KEY_ID` + `SEED_S3_SECRET_ACCESS_KEY` | Only when restoring a database dump from S3 | Your storage provider's console (AWS IAM, Cloudflare R2, Backblaze…) | Create a **read-only** access key for the dump's bucket. |
   | *(each `env.secrets` name)* | Always for this project | *(say where this app's value comes from — e.g. the Stripe dashboard for `STRIPE_API_KEY`, or "invent a long random string" for a `JWT_SECRET`)* | *(one sentence)* |

   Then tell the user where every value gets pasted: the GitHub repository →
   **Settings → Secrets and variables → Actions → New repository secret** —
   the name must match the table exactly, capitals and underscores included.
   Click-by-click guide: `.deploy/docs/SECRETS.md`.

4. **Where to put the dump — only if the Q3 answer was C.** Write this out
   filled in, not as a template. The user has to be able to follow it in
   their storage dashboard without asking you anything:

   > **Upload your dump files here:**
   > `<bucket>/<project.name>/`
   > *(state the real bucket and the real project name — e.g.
   > `my-team-seeds/vod-admin-api/`)*
   >
   > **Upload it with the AWS CLI, not the web dashboard.** A browser sends the
   > file in one request and large dumps fail; the CLI splits them into parts
   > and retries. Nothing to create first — S3 has no real folders, so this
   > path appears on its own:
   >
   > ```bash
   > aws s3 cp yourdump.archive.gz s3://<bucket>/<project.name>/yourdump.archive.gz \
   >   --endpoint-url <their endpoint>
   > ```
   > *(fill in all three. Drop the `--endpoint-url` line entirely for Amazon S3.
   > Set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` first, using a key that
   > can WRITE — the two GitHub secrets only need read.)*
   >
   > **This project accepts:** *(name the ONE shape matching the `format` and
   > `gzip` you set — e.g. "a gzipped mongodump archive, made with
   > `mongodump --archive=NAME.archive.gz --gzip`". Do not list the others.)*
   >
   > **Name it whatever you like** — `baseline.archive.gz`,
   > `2026-08-with-orders.archive.gz`. The file name is how you pick it later,
   > so make it descriptive. You can keep as many as you want side by side.
   >
   > **To load one:** Actions → "Deploy branch" → Run workflow → type the file
   > name into the **dump** box → Run. **Leave that box blank and the preview
   > starts with an empty database** — that is the normal case.

   In folder mode only, mention that `bash .deploy/upload-dump.sh yourfile.gz`
   does the same thing without typing the path. In action mode there is no
   `.deploy/` folder, so the `aws s3 cp` line above IS the way — and every
   deploy's summary reprints it with this project's values already filled in.
5. The launch steps: commit and push, then GitHub → **Actions** → **"Deploy
   branch"** → pick the branch → **Run workflow**. The live URL appears at
   the top of the run's summary page.
6. Optional hardening: after the first deploy, the run prints the Railway
   project id — pasting it into `railway.project_id` in `.deploy/config.yml`
   pins the project. Later deploys and cleanups already find it by name
   automatically; the pin just also survives a project rename.
````

</details>

Prefer to set things up by hand instead? The two manual paths are below.

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

> **Copy `templates/deploy.yml` exactly — do not swap its secrets block for
> `secrets: inherit`.** The kit passes every repo secret to the config as one
> JSON value, and that value has to be built in *your* workflow:
>
> ```yaml
>     secrets:
>       secrets_json: ${{ toJSON(secrets) }}
> ```
>
> `secrets: inherit` looks equivalent and is not. Inherited secrets can be read
> by name but cannot be listed, so `toJSON(secrets)` inside the kit's workflow
> returns only `github_token` — and every secret you configured reports as
> "not set" while your settings page looks perfect. This shipped broken once;
> `validate` now prints the secret names it can actually see so the cause is
> visible in one glance.

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

### Backend + MongoDB, with dumps you can pick from

```yaml
db:
  engine: mongo
  connection_env: MONGO_URI            # the variable your app reads
  database_name: myapp
  restore:
    tool: mongorestore
    bucket: my-team-seeds              # the SAME line in every project
```

**You never write a path.** One bucket holds every project's dumps, and each
project reads from its own folder inside it, named after `project.name`:

```
s3://my-team-seeds/myapp/baseline.archive.gz
s3://my-team-seeds/myapp/2026-08-with-orders.archive.gz
```

Upload files there however you like — your provider's dashboard, or
`bash .deploy/upload-dump.sh yourfile.gz`, which puts them in exactly that
folder. Keep as many as you want side by side.

Then pick one **per deploy**: Actions → Deploy branch → put the file name in
the **dump** box. Leave it blank and the preview starts with an **empty
database** — that is the default, so data never appears unless someone asks
for it by name. To make a project always seed, set `default_dump` in the
config and the choice is recorded in git rather than in whoever pressed the
button.

Not on Amazon? Add the endpoint from your provider's dashboard —
`s3_endpoint: https://…` — and everything else stays the same.

### Keeping the built image private (Railway Pro)

By default the built image must be made **public** on GitHub (one click, the
first deploy stops with instructions) — fine for frontends, but it means
anyone can download your built backend code. On Railway Pro, keep it locked
instead:

```yaml
build:
  registry_visibility: private
```

…and add one repo secret, `GHCR_PULL_TOKEN`: **your own** GitHub token
(classic) with the `read:packages` scope, from github.com/settings/tokens. The
pipeline hands it to Railway automatically before every deploy. With this set
there is no visibility click at all: nothing about your code is ever
downloadable by anyone else.

**Under a GitHub organization**, two more things. Set
`build.registry_username` to the GitHub username of whoever made the token —
left empty it falls back to the repository's owner, which there is the
organization's name. And make your **own** token rather than sharing one:
a shared token makes every deploy look like one person's, and breaks every
project at once the day it expires.
[`.deploy/docs/SECRETS.md`](.deploy/docs/SECRETS.md) has the full list of what
an organization must allow first.

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
after a five-minute platform timeout. By default it runs when there is no
database, since the app must boot standalone (`build.smoke_test: auto`);
set it to `true` to run it always.

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
| `seed` | Which dump to load, **file name only** (`baseline.archive.gz`). Blank = empty database |

---

## Secrets

**New developer? Follow the click-by-click guide:
[`.deploy/docs/SECRETS.md`](.deploy/docs/SECRETS.md)** — where to create each
key and where to paste it, ~5 minutes.

| Secret | When | What |
|---|---|---|
| `RAILWAY_API_TOKEN` | always | An **account** token from railway.com/account/tokens. A *project* token can't create environments. |
| `SEED_S3_ACCESS_KEY_ID` / `SEED_S3_SECRET_ACCESS_KEY` | only when seeding from S3 | **Read-only** key for the dump's bucket |
| `GHCR_PULL_TOKEN` | only with `registry_visibility: private` | **Your own** GitHub token (classic, `read:packages`) so Railway can pull the locked image. Never a teammate's, never an organization-wide secret — see [`SECRETS.md`](.deploy/docs/SECRETS.md). |

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
  workflow/                ← deploy.yml + cleanup.yml (source of truth, folder mode)
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
| `Railway cannot pull the image` | The GHCR package is private — make it public (one-time), or use Railway Pro with registry credentials. Under an organization: an owner has to make it public, and a private image needs `registry_username` set plus a token that can read the package. |
| `could not open a public port` | The Railway account isn't verified — connect GitHub to Railway. |
| Restore fails | The dump is from a newer database version than `db.service_image`, or its database name differs from `db.database_name`. |
| `secret X is not set` | Add it under Settings → Secrets and variables → Actions. If the run's secret-name list is empty or shows only `github_token`, the secret is fine and the workflow is wrong — its secrets block must be `secrets_json: ${{ toJSON(secrets) }}`, not `secrets: inherit`. |
| `the dump does not exist` | It's only on your laptop — run `bash .deploy/upload-dump.sh`. |

---

## Further reading

- **[`.deploy/docs/README.md`](.deploy/docs/README.md)** — day-to-day usage
- **[`.deploy/docs/COPY-TO-NEW-PROJECT.md`](.deploy/docs/COPY-TO-NEW-PROJECT.md)** — new-project walkthrough with checklist
- **[`.deploy/docs/AI-SETUP-PROMPT.md`](.deploy/docs/AI-SETUP-PROMPT.md)** — the AI setup guide that travels inside `.deploy/`; the copy-paste prompt at the top of this README fetches the kit first and then follows it
- **[`.deploy/dumps/README.md`](.deploy/dumps/README.md)** — why dumps live in object storage, not git
