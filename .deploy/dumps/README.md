# Dumps go here

Drop your database dump in this folder, then push it to the bucket CI reads
from:

```bash
cp ~/Downloads/mydump.archive.gz .deploy/dumps/
bash .deploy/upload-dump.sh
```

That's it. `upload-dump.sh` takes the newest file here and uploads it to
whatever `db.restore.seed_source` says in `config.yml`.

## Why not just leave it here?

Because CI would never see it.

GitHub's build machine clones your repository from GitHub. A file sitting on
your laptop isn't in the clone, so the deploy fails with "the dump does not
exist" — which is confusing, because you can see it right there.

## Why not commit it, then?

Git keeps every version of every file, forever. A 50 MB dump committed today
stays in the repository's history permanently. Next month's dump adds another
50 MB. It can't be removed later without rewriting history, and everyone who
clones the repo downloads all of it.

Object storage is the right home for large files that change. That's why
everything in this folder is git-ignored.

## Before uploading

`upload-dump.sh` checks the file for you. For MongoDB it verifies the archive's
magic number, reads which server version produced it, and warns if
`db.service_image` in your config is older than that — restoring a newer dump
into an older server can fail partway through.

You need credentials that can **write** to the bucket:

```bash
export SEED_S3_ACCESS_KEY_ID=...
export SEED_S3_SECRET_ACCESS_KEY=...
```

The key CI uses only needs **read**. Keeping those separate means a bug in the
pipeline can't overwrite your dump.
