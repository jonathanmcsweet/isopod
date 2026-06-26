# Identity remap (`isopod remap`)

Commits made inside a container carry whatever git identity was configured
there — often a throwaway like `dev@<container>`. `isopod remap` rewrites those
commits to your real name/email after you've pulled them onto the host,
while preserving commit messages and author/committer dates.

It complements [`isopod fetch`](../README.md#getting-work-back-out-export-vs-fetch),
which brings the container's history onto the host as remote-tracking refs.

## Prerequisite: fetch first

`remap` only operates on refs that `fetch` has already imported. From inside the
host clone you fetched into:

```sh
isopod fetch myproj        # imports the container's branches as refs/remotes/myproj/*
isopod remap myproj        # rewrites the identity on those refs
```

If no `refs/remotes/<name>/*` refs exist yet, `remap` stops and tells you to run
`fetch` first.

## The two identities

A remap is "rewrite commits matching the **old** identity to the **new** one."

### Old identity — *who to rewrite from*

Only commits whose email matches the old identity are touched, so a teammate's
commits on the same branch are left alone. It is resolved as:

1. `--old-email <e>` (and optionally `--old-name <n>` to also require the name)
2. otherwise **auto-detected** from the still-running container (its
   `git config user.email`)

If the container is gone and you didn't pass `--old-email`, remap stops and asks
for it.

### New identity — *who to rewrite to*

If you don't pass `--name`/`--email`, the new identity is filled from a fallback
chain (each step used only if the ones above it are empty):

1. `--name` / `--email` flags
2. `ISOPOD_GIT_NAME` / `ISOPOD_GIT_EMAIL` environment variables
3. host `git config user.name` / `user.email`

So the common case — rewrite the container's throwaway identity to your real one —
is just:

```sh
isopod remap myproj
```

Name and email resolve independently, so you can pin one with a flag and let the
other fall through. If none of the three sources yields a value, remap stops with
a clear error rather than writing an empty identity.

## What it touches (and what it doesn't)

- **Scoped to the container's refs** (`refs/remotes/<name>/*`) — your own
  branches are never rewritten.
- **Dates preserved** — author and committer timestamps are kept verbatim.
- **Messages preserved** — including any identity-looking text inside a commit
  body (the rewrite is data-block aware, not a blind line replacement).

## Undo

Before rewriting, the original refs are snapshotted under `refs/remap-backup/`.
Inspect and restore or discard them:

```sh
git for-each-ref refs/remap-backup/                 # list the backups
git update-ref refs/remotes/myproj/main refs/remap-backup/remotes/myproj/main  # restore one
git update-ref -d refs/remap-backup/remotes/myproj/main                        # discard when happy
```

## Does the original author leak?

A normal `git push` does **not** send the original `dev@<container>` identity to
origin: remap writes new commit objects (new SHAs, rewritten author **and**
committer), so the originals become unreachable from the branch you push. Caveats:

- **Locally**, the originals survive in `refs/remap-backup/*`, the reflog, and
  dangling objects until you drop the backups and `git gc --prune=now`.
- **`git push --mirror`** (or pushing `refs/*`) *will* leak them — it pushes the
  backup refs too. Use a normal `git push <remote> <branch>`.
- **Already pushed before remapping?** Too late — remap is meant to run before the
  commits leave your machine; it can't retract what origin already has.

Verify a branch is clean before pushing (every line should show only your real
identity on both sides):

```sh
git log --format='%an <%ae> | %cn <%ce>' mybranch
```

## Confirmation

Because rewriting changes commit SHAs, remap prints the planned change and asks
for confirmation. Pass `--force`/`-f` to skip the prompt (e.g. in scripts).

## Implementation

remap uses [`git-filter-repo`](https://github.com/newren/git-filter-repo) when
it's installed (via a mailmap matching the old identity). When it isn't, it falls
back to a built-in `git fast-export` → `fast-import` rewrite that needs only
**core git plus `python3`** — the rewrite logic lives in
[`lib/remap_identity_filter.py`](../lib/remap_identity_filter.py). Neither path
touches the working tree or needs a network.
