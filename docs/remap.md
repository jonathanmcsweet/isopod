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

## Multiple identities at once — a remap file

The single-pair flags above remap one identity. To remap several in one run —
for example several throwaway box identities to your real one, or different
contributors at once — list them in a **remap file**: one `old -> new` rule per
line, read left-to-right.

```
# old identity          ->  new identity
dev@box-a               ->  Real Name <me@real.com>
dev@box-b               ->  Real Name <me@real.com>
# match the old name too, not just the email:
Throwaway <dev@box-c>   ->  Real Name <me@real.com>
```

- The **left** side must contain an `<email>` (a bare `dev@box` works too) — that
  is what each commit is matched on. Add a name to also require a name match.
- The **right** side is the replacement: `Name <email>`, just `<email>` (keep the
  name), or just a `Name` (keep the email).
- Blank lines and lines starting with `#` are ignored.

Provide the file in either of two ways (precedence: flag, then default file):

1. `--remap-file <file>` on a single run.
2. `~/.config/isopod/remap` (under `$ISOPOD_CONFIG_DIR` if set) — a standing set
   of rules applied automatically whenever you run `isopod remap` without
   single-pair flags.

```sh
isopod remap myproj --remap-file ~/.config/isopod/remap
isopod remap myproj            # uses ~/.config/isopod/remap if it exists
```

When a remap file is in effect the single-pair flags and box auto-detection are
not used. Identities the file does not mention are left untouched, so a
teammate's commits on the same branch are still safe. A `--remap-file` always
wins; the default file is skipped if you pass any of
`--old-email/--old-name/--name/--email`.

> The file is isopod's own format, distinct from git's `.mailmap` (which git
> reads to *display* collapsed identities). isopod translates these rules into a
> mailmap internally to drive the rewrite, but does not read a repo's `.mailmap`.

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

Both backends are driven by a git mailmap (the single-pair flags simply build a
one-line mailmap on the fly). remap uses
[`git-filter-repo`](https://github.com/newren/git-filter-repo) when it's
installed. When it isn't, it falls back to a built-in `git fast-export` →
`fast-import` rewrite that needs only **core git plus `python3`** — the
mailmap-driven rewrite logic lives in
[`lib/remap_identity_filter.py`](../lib/remap_identity_filter.py). Neither path
touches the working tree or needs a network.
