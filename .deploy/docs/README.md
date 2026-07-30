# Branch deploys → Railway

Press a button in GitHub, pick a branch, get a live URL. A backend runs against
**its own database**, freshly loaded from a dump; a frontend is served straight
from its build. Press the button again with `destroy` and it all disappears.

Everything lives in **one folder**: `.deploy/`. Copy it into any project, run
`bash .deploy/install.sh`, adjust `config.yml` — every default already works,
so most projects change only a couple of lines. That's the whole setup.

A frontend project doesn't even need a Dockerfile: point
`build.dockerfile_path` at `.deploy/presets/frontend-static.Dockerfile` (the
recipe is at the top of `config.yml`).

---

## Deploying a branch

1. **Actions → Deploy branch → Run workflow**
2. Pick your branch in the dropdown. *That dropdown is the branch picker* — the
   workflow deploys whatever branch you run it on.
3. Leave **action** as `deploy`, **stage** as `preview`.
4. **Run workflow**.

The URL appears at the top of the run's summary page.

First deploy of a branch: roughly 4–8 minutes. Later ones are faster — the image
is reused when the commit hasn't changed.

| Input | What it does |
|---|---|
| **action** | `deploy` or `destroy` |
| **stage** | `preview` (default), `dev`, `prod` — picks which settings apply |
| **seed** | Use a different dump just this once, e.g. `s3://bucket/other.gz` |

## Destroying a branch

Same workflow, same branch, **action: destroy**.

Deletes the environment, the app, the database and its storage. Running it twice
is fine — the second time it just says there was nothing to do.

**Usually you don't even need to:** merging (or closing) a branch's pull
request, or deleting the branch, destroys its environment automatically —
that's the `cleanup.yml` workflow. The button remains for branches without a
PR you're done with early.

`main` and `master` are protected — destroy refuses to touch them. Change that
under `destroy.protected_branches`.

---

## Running it yourself

The same script the workflow uses. Nothing is GitHub-specific.

```bash
bash .deploy/run.sh validate    # check the config, touch nothing
bash .deploy/run.sh doctor      # also check the Railway token and API
bash .deploy/run.sh deploy      # the full pipeline
bash .deploy/run.sh destroy     # tear this branch down

bash .deploy/selftest.sh        # is the machinery still portable?
bash .deploy/upload-dump.sh     # push a local dump to the seed bucket
bash .deploy/update.sh          # fetch the latest kit; config and dumps survive
```

`validate` is the useful one. It prints every variable that would be applied —
with secrets masked — so you can read the list before anything is created.

---

## Things worth knowing

**Re-deploying reloads the database.** The dump is restored on every deploy, so
each preview is a clean, repeatable copy. Anything you type into a preview by
hand is gone next deploy. Set `db.restore.mode: once` if you'd rather keep it.

**Previews use their own storage bucket.** Look at `preview_defaults.env` in
`config.yml` — the bucket name is written there in plain sight, not hidden in a
secret, so you can confirm at a glance that no preview points at production.

**The database is only briefly reachable from outside.** To load the dump the
run opens a temporary public port, restores, then closes it — from an exit trap,
so it closes even if the restore fails or the job is cancelled. Afterwards only
the app can reach the database, over Railway's private network.

**Adding a secret needs no workflow edit.** Name it in `config.yml` under
`env.secrets`, add the value in repo settings, done. The workflow passes the
whole secrets context once, so it never needs changing.

**One deploy at a time per branch.** A second run waits for the first.

---

## When something breaks

The run prints the container's **raw logs** — build and runtime — whenever a
deploy fails or the health check times out. Apps often crash before their own
logging starts, leaving only a bare stack trace. **Read the first lines of the
runtime log.**

| Symptom | Usually means |
|---|---|
| Health check times out | The app crashed at startup — read the runtime log. Or it isn't listening on Railway's `PORT`. |
| "service unavailable" / 502 while the app runs | The app listens on a different port than `runtime.port`, or only on IPv4 — Railway probes and routes over IPv6, so nginx needs `listen [::]:80;` next to `listen 80;`. |
| `Railway cannot reach the image` | The GHCR package is private. Make it public, or use Railway Pro with registry credentials. |
| `could not open a public port` | Railway account not verified — connect your GitHub account to Railway. |
| Restore fails | Dump is from a newer database version than `db.service_image`, or the database name inside it differs from `db.database_name`. |
| `secret X is not set` | Add it in Settings → Secrets and variables → Actions — full walkthrough in [`SECRETS.md`](SECRETS.md). |
| `the dump does not exist` | It's on your laptop, not in the bucket. Run `bash .deploy/upload-dump.sh`. |

---

## What's in the folder

```
.deploy/
  config.yml           ← the only file you edit
  run.sh               ← one entry point: deploy | destroy | validate | doctor
  install.sh           ← run once after copying the folder in
  update.sh            ← one-command upgrade (config and dumps survive)
  upload-dump.sh       ← send a local dump to the bucket
  selftest.sh          ← is this still portable?
  presets/             ← ready-made Dockerfile for frontend-only projects
  dumps/               ← put dumps here (git-ignored)
  lib/                 ← logging, config, secrets, the Railway API
  steps/               ← the pipeline, one file per stage
  engines/             ← one small file per database type
  workflow/            ← the GitHub workflow, installed by install.sh
  docs/                ← this file, and the onboarding guide
```

Only `config.yml` differs between projects. `selftest.sh` enforces that.
