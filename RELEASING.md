# Releasing isopod

isopod is versioned with [Semantic Versioning](https://semver.org/). The version
string lives in one place — `ISOPOD_VERSION` near the top of the `isopod` script —
and is what `isopod version` prints.

The Homebrew formula lives in a **separate `homebrew-isopod` tap repository**, not
in this repo. That's deliberate:

- **No chicken-and-egg.** A formula's `sha256` can't exist until the release is
  tagged, and the tag comes after the merge — so the main-repo PR never carries a
  sha256 at all. You tag the merge, then bump the formula in the tap.
- **No gate friction.** This repo requires a version bump on *every* PR
  (`.github/workflows/version-bump.yml`). A formula-only sha bump would otherwise
  be forced to invent a version. The tap has no such rule.

A seed copy of the formula lives at [`packaging/homebrew/isopod.rb`](packaging/homebrew/isopod.rb);
use it to create the tap once (see [`packaging/homebrew/README.md`](packaging/homebrew/README.md)).

> **Tagging is not publishing.** A git tag just makes GitHub generate a source
> tarball; nobody installs the stable formula until the tap is bumped. So the tag
> always comes *after* the PR merges — you never tag before merge.

## One-time: create the tap

Create a GitHub repo named **`homebrew-isopod`** (the `homebrew-` prefix is what
makes `brew tap jonathanmcsweet/isopod` resolve), and seed it:

```sh
git clone https://github.com/jonathanmcsweet/homebrew-isopod
cd homebrew-isopod && mkdir -p Formula
cp /path/to/isopod/packaging/homebrew/isopod.rb Formula/isopod.rb
git add Formula/isopod.rb && git commit -m "isopod formula" && git push
```

`brew install --HEAD isopod` works immediately; stable installs work after the
first release below.

## Cut a release

1. **Bump the version.** Edit `ISOPOD_VERSION` in `isopod` (e.g. `0.3.0`) and land
   it on `master` via a normal PR (the version-bump check passes because you
   bumped it). Use a Conventional Commit, e.g. `chore(release): 0.3.0`.

2. **Tag and push — _after_ the PR is merged.** The tag must be `v<version>` so
   the formula `url` resolves:

   ```sh
   git checkout master && git pull
   git tag -a v0.3.0 -m "isopod 0.3.0"
   git push origin v0.3.0
   ```

   GitHub now serves the source tarball at:

   ```
   https://github.com/jonathanmcsweet/isopod/archive/refs/tags/v0.3.0.tar.gz
   ```

3. **Bump the formula IN THE TAP repo** (`homebrew-isopod`), not here. Set `url`
   to the new tag and `sha256` to the tarball digest:

   ```sh
   curl -fsSL https://github.com/jonathanmcsweet/isopod/archive/refs/tags/v0.3.0.tar.gz \
     | shasum -a 256          # Linux: sha256sum
   ```

   Commit & push the tap. Or automate the whole step:

   ```sh
   brew bump-formula-pr --tag=v0.3.0 jonathanmcsweet/isopod/isopod
   ```

4. **Smoke-test from the tap** before announcing:

   ```sh
   brew install jonathanmcsweet/isopod/isopod
   brew test    jonathanmcsweet/isopod/isopod
   brew audit --strict jonathanmcsweet/isopod/isopod
   isopod doctor
   ```

## Keeping the seed in sync

You normally edit the tap formula directly. Only re-sync
[`packaging/homebrew/isopod.rb`](packaging/homebrew/isopod.rb) → the tap when the
*install logic itself* changes (deps, completions, caveats) — not for routine
`url`/`sha256` bumps.
