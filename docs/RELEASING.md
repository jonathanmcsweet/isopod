# Releasing isopod

isopod is versioned with [Semantic Versioning](https://semver.org/). The version
string lives in one place — `ISOPOD_VERSION` near the top of the `isopod` script —
and is what `isopod version` prints.

The Homebrew formula lives in a separate `homebrew-isopod` tap repository.

## Releasing is automatic

Releases are cut by [`.github/workflows/release.yml`](../.github/workflows/release.yml),
which runs on every push to `master`. Because the `version-bump` check
(`.github/workflows/version-bump.yml`) requires every PR to raise `ISOPOD_VERSION`,
each merge to `master` carries a new version — so the workflow can derive the whole
release with no human input. On each push it:

1. Reads `ISOPOD_VERSION` from `isopod`.
2. Tags `v<version>` and pushes it (skips if the tag already exists).
3. Creates a GitHub Release with auto-generated notes.
4. Opens/commits a `url` + `sha256` bump on `Formula/isopod.rb` in the
   `homebrew-isopod` tap via `mislav/bump-homebrew-formula-action`.

**So the entire release process is: merge a version-bumping PR. Done.** This
includes a docs-only typo fix, because the version gate forces a bump on every PR
— the two policies are coupled by design.


The workflow is idempotent: it fires on every push to `master`, but the
`git ls-remote` tag check means a push that doesn't change the version (or a
re-run) just no-ops instead of re-tagging.

## One-time setup

These steps are done once; after that, releases need no manual action.

### 1. Create the tap

Create a GitHub repo named **`homebrew-isopod`** (the `homebrew-` prefix is what
makes `brew tap jonathanmcsweet/isopod` resolve), and seed it with a
`Formula/isopod.rb`:

```sh
git clone https://github.com/jonathanmcsweet/homebrew-isopod
cd homebrew-isopod && mkdir -p Formula
# Author Formula/isopod.rb. Need a starting point? Recover an earlier in-repo copy
# from this repo's history:
#   git -C /path/to/isopod log --all --full-history -- Formula/isopod.rb
#   git -C /path/to/isopod show <that-commit>:Formula/isopod.rb > Formula/isopod.rb
git add Formula/isopod.rb && git commit -m "isopod formula" && git push
```

`brew install --HEAD isopod` works immediately; stable installs work after the
first automated release.

Add a [`livecheck`](https://docs.brew.sh/Brew-Livecheck) block to the tap's
`Formula/isopod.rb` so `brew livecheck` (and any scheduled bump action) can detect
new versions from the GitHub Releases the workflow cuts:

```ruby
livecheck do
  url :stable
  strategy :github_latest
end
```

### 2. Add the `HOMEBREW_TAP_TOKEN` secret

`GITHUB_TOKEN` can only write to *this* repo, so the cross-repo commit to
`homebrew-isopod` needs a separate Personal Access Token:

1. Create a PAT (fine-grained, scoped to the `homebrew-isopod` repo, with
   **Contents: read & write**; or a classic token with the `repo` scope).
2. Add it to this repo as an Actions secret named **`HOMEBREW_TAP_TOKEN`**
   (Settings → Secrets and variables → Actions → New repository secret).

This is the only manual credential the automation needs.

### 3. Require up-to-date branches before merging

Turn on **"Require branches to be up to date before merging"** in branch
protection for `master`, and mark `version-bump` as a required status check.
Otherwise two PRs could both bump to the same version against a stale base and
collide — the up-to-date rule makes the version gate airtight. (Even without it,
the workflow won't double-tag; it just won't release the second one.)

## Manual fallback

If you ever need to release by hand (e.g. the Action is down):

```sh
# after the version-bumping PR is merged to master:
git checkout master && git pull
V=$(sed -n 's/^ISOPOD_VERSION="\(.*\)"/\1/p' isopod)
git tag -a "v$V" -m "isopod $V" && git push origin "v$V"
gh release create "v$V" --title "isopod $V" --generate-notes

# then bump the tap (computes the sha256 for you):
brew bump-formula-pr --tag="v$V" jonathanmcsweet/isopod/isopod
```

Smoke-test from the tap before announcing:

```sh
brew install jonathanmcsweet/isopod/isopod
brew test    jonathanmcsweet/isopod/isopod
brew audit --strict jonathanmcsweet/isopod/isopod
isopod doctor
```

## Updating the formula's install logic

Routine `url`/`sha256` bumps happen entirely in the tap (and are automated). The
one time you also touch the formula's `install`/`depends_on`/`caveats` blocks is
when this repo's layout changes — the formula installs `completions/`, `lib/`,
and `security/` and declares the runtime deps, so a rename or new artifact here
means a matching edit to the formula in the tap.

