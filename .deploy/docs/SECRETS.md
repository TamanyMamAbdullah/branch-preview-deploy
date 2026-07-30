# Setting up the secrets (one-time, ~5 minutes)

The deploy needs a couple of keys. They are **never written in the repo** —
you paste them into GitHub once, and every deploy picks them up
automatically. No workflow edits, ever.

## Which secrets does this project need?

| Secret name | Needed when | What it is |
|---|---|---|
| `RAILWAY_API_TOKEN` | **Always** | Lets the deploy create/update things on Railway |
| `GHCR_PULL_TOKEN` | Only if `config.yml` has `registry_visibility: private` | Lets Railway download the locked app image |
| `SEED_S3_ACCESS_KEY_ID` + `SEED_S3_SECRET_ACCESS_KEY` | Only if the project restores a database dump from S3 | Read-only key for the dump's bucket |
| Whatever `env.secrets` lists in `.deploy/config.yml` | Per project | The app's own secrets (e.g. a JWT secret) |

Not sure which apply? Run `bash .deploy/run.sh validate` — it names every
missing secret, before anything is created.

---

## Part 1 — Get the Railway key (`RAILWAY_API_TOKEN`)

1. Open **railway.com/account/tokens** (log in if asked).
2. Name it anything, e.g. `github-deploys`.
3. If it asks for a scope, pick your **account** — *not* a single project.
   A project-scoped token cannot create environments and will not work.
4. Click **Create** and **copy the value now** — it is shown only once.

## Part 2 — Get the GitHub image key (`GHCR_PULL_TOKEN`)

Skip this part if `config.yml` says `registry_visibility: public`.
If someone on the team already made this token, **reuse it** — the same
token works in every repository. Don't create a new one per project.

1. Open **github.com/settings/tokens**.
2. **Generate new token** → **Generate new token (classic)**.
3. Note: `railway-image-pull` (any name works).
4. Expiration: **No expiration** is simplest. (A dated token makes deploys
   fail on that date until someone creates a new one.)
5. Tick **only** the `read:packages` box. Nothing else.
6. **Generate token** and **copy the value now** — shown only once.

## Part 3 — Paste them into the repository

1. Open the repository on GitHub.
2. **Settings** (top tab) → left sidebar **Secrets and variables** → **Actions**.
3. Green button **New repository secret**.
4. Name: `RAILWAY_API_TOKEN` — exactly, capitals and underscores.
   Value: paste the Railway key. **Add secret**.
5. Repeat for `GHCR_PULL_TOKEN` and any other name from the table above.

You should now see the names listed; the values stay hidden forever — normal.

---

## For teams and organizations

- **Add secrets once for the whole org** instead of per repo:
  org **Settings → Secrets and variables → Actions → New organization
  secret**, shared with all repositories. Every project's deploy finds them
  automatically.
- If the org uses **SAML single sign-on**, open the classic token's page and
  click **Authorize** for the org — without that, the token is rejected there.
- The GitHub token dies with the account that created it. If that person
  leaves, deploys stop — for a company, create it from a shared/bot account.

## If something complains

- **"secret 'X' is not set"** — the name in GitHub doesn't match exactly.
  Check spelling, capitals, underscores. Then re-run.
- **Railway says not authorized** — the token is a *project* token, expired,
  or pasted with a stray space. Make an **account** token and re-add it.
- **Railway cannot pull the image** — `GHCR_PULL_TOKEN` is missing,
  expired, or lacks the `read:packages` scope.
