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

**Make your own token.** Do not borrow a teammate's, and do not hand yours
out. Part 4 explains why, and what an organization has to allow first.

1. Open **github.com/settings/tokens**.
2. **Generate new token** → **Generate new token (classic)**.
3. Note: `railway-image-pull` (any name works).
4. Expiration: **No expiration** is simplest. (A dated token makes deploys
   fail on that date until someone creates a new one.)
5. Tick **only** the `read:packages` box. Nothing else.
6. **Generate token** and **copy the value now** — shown only once.

That one box is the whole power of this key: it can download private
container images, and nothing else. It cannot read your source code, push
commits, or change any setting.

## Part 3 — Paste them into the repository

1. Open the repository on GitHub.
2. **Settings** (top tab) → left sidebar **Secrets and variables** → **Actions**.
3. Green button **New repository secret**.
4. Name: `RAILWAY_API_TOKEN` — exactly, capitals and underscores.
   Value: paste the Railway key. **Add secret**.
5. Repeat for `GHCR_PULL_TOKEN` and any other name from the table above.

You should now see the names listed; the values stay hidden forever — normal.

---

## Part 4 — Organizations

Read this if the repository lives under a GitHub **organization** rather than
your personal account. Things work differently there, and the difference is
easy to miss.

### One token per person — never one for the team

Everyone sets up their own projects with **their own** token, pasted as a
**repository** secret in each project they set up. Do not create an
organization-wide `GHCR_PULL_TOKEN`. Do not pass your token to a teammate.

Three reasons:

- A shared token makes every deploy authenticate as one person. Anything
  logged, revoked, or misused points at them, for work they never did.
- A shared token is one point of failure. It expires or gets revoked once, and
  every project in the organization stops the same morning.
- Your own token keeps trouble inside your own project, and makes it obvious
  who to ask when something breaks.

To be clear, because it sounds like a contradiction: one token *can* read
every package its account is allowed to read, so one would technically work
everywhere. The rule here is about who is answerable for a deploy, not about
what is possible.

The cost, said plainly: a token dies with the account that made it. When
someone leaves, the projects **they** set up stop deploying, and the person
taking over adds their own token and their own username. That is a small,
contained cost — not a reason to share one key.

Other secrets are a different matter. `RAILWAY_API_TOKEN` and the `SEED_S3_*`
keys are team resources and are fine as organization secrets
(org **Settings → Secrets and variables → Actions → New organization
secret**). `GHCR_PULL_TOKEN` is the one that stays personal.

### Three things must be true, or the token cannot pull

1. **Your account can read the package.** Being an organization member with
   read access to the repository is normally enough. If it isn't, an owner
   opens the package → **Package settings → Manage access** and adds you with
   the **Read** role.
2. **The organization allows classic tokens.** Some block them. Check
   organization **Settings → Third-party Access**, under **Personal access
   tokens**.
3. **Single sign-on is authorized — if the organization uses it.** On
   **github.com/settings/tokens**, look next to your token for a **Configure
   SSO** button. If it is there, click it and authorize your organization.
   No button means the organization has no single sign-on, and there is
   nothing to do.

### Also set your username in the config

With `registry_visibility: private`, put the GitHub username of whoever made
the token into `.deploy/config.yml`:

```yaml
build:
  registry_visibility: private
  registry_username: "<your-github-username>"
```

Left empty, it falls back to the repository's owner — which on an organization
is the **organization's** name, not an account that owns a token. Filling it in
removes the guess from the one place that is hardest to debug later.

### Check the token before you trust it

```bash
docker login ghcr.io -u <your-github-username> -p <your-token>
docker pull ghcr.io/<org>/<repo>:<a-tag-that-exists>
```

The **pull** is the real test — logging in succeeds far more easily than
pulling does. A `denied` here means point 1 above.

### Public images need an owner on an organization

With `registry_visibility: public`, GitHub still publishes the package as
private on the first push, and an ordinary member usually cannot change that.
An organization owner opens
`https://github.com/<org>/<repo>/pkgs/container/<package>` → **Package
settings → Danger Zone → Change visibility → Public**. The organization may
first have to allow public packages at all, under its **Settings → Packages**.

## If something complains

- **"secret 'X' is not set"** — the name in GitHub doesn't match exactly.
  Check spelling, capitals, underscores. Then re-run.
- **Railway says not authorized** — the token is a *project* token, expired,
  or pasted with a stray space. Make an **account** token and re-add it.
- **Railway cannot pull the image** — `GHCR_PULL_TOKEN` is missing,
  expired, or lacks the `read:packages` scope. On an organization, work
  through the three points in Part 4 as well.
