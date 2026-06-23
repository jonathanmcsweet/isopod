# Releasing isopod

isopod is versioned with [Semantic Versioning](https://semver.org/). The version
string lives in one place — `ISOPOD_VERSION` near the top of the `isopod` script —
and is what `isopod version` prints.

The Homebrew formula lives in a **separate `homebrew-isopod` tap repository**

## One-time: create the tap

Create a GitHub repo named **`homebrew-isopod`** (the `homebrew-` prefix is what
makes `brew tap jonathanmcsweet/isopod` resolve), and seed it:

```sh
git clone https://github.com/jonathanmcsweet/homebrew-isopod
cd homebrew-isopod && mkdir -p Formula
# Author Formula/isopod.rb. Need a starting point? Recover the last in-repo copy
# from the main repo's history:
#   git -C /path/to/isopod log --all --full-history -- packaging/homebrew/isopod.rb
#   git -C /path/to/isopod show <that-commit>:packaging/homebrew/isopod.rb > Formula/isopod.rb
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
## Cut a release

1. **Bump the version.** Edit `ISOPOD_VERSION` in `isopod` (e.g. `0.3.0`) and land
   it on `master`. Use a Conventional Commit, e.g. `chore(release): 0.3.0`.

2. **Tag and push.** The tag must be `v<version>` so the Homebrew `url` resolves:

   ```sh
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

## Updating the formula's install logic

Routine `url`/`sha256` bumps happen entirely in the tap. The one time you also
touch the formula's `install`/`depends_on`/`caveats` blocks is when *this repo's
layout* changes — the formula installs `completions/`, `lib/`, and `security/` and
declares the runtime deps, so a rename or new artifact here means a matching edit
to the formula in the tap.
