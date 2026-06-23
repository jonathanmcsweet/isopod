# Releasing isopod

isopod is versioned with [Semantic Versioning](https://semver.org/). The version
string lives in one place — `ISOPOD_VERSION` near the top of the `isopod` script —
and is what `isopod version` prints.

## Cut a release

1. **Bump the version.** Edit `ISOPOD_VERSION` in `isopod` (e.g. `0.3.0`) and land
   it on `master`. Use a Conventional Commit, e.g. `chore(release): 0.3.0`.

2. **Tag and push.** The tag must be `v<version>` so the Homebrew `url` resolves:

   ```sh
   git tag -a v0.3.0 -m "isopod 0.3.0"
   git push origin v0.3.0
   ```

   GitHub auto-generates a source tarball at:

   ```
   https://github.com/jonathanmcsweet/isopod/archive/refs/tags/v0.3.0.tar.gz
   ```

3. **Compute the tarball SHA-256** and put it in `Formula/isopod.rb`:

   ```sh
   curl -fsSL https://github.com/jonathanmcsweet/isopod/archive/refs/tags/v0.3.0.tar.gz \
     | shasum -a 256
   # (Linux: sha256sum)
   ```

   Or let Homebrew print it for you:

   ```sh
   brew fetch --build-from-source ./Formula/isopod.rb   # prints the SHA-256 it downloaded
   ```

   Replace both `url` (the version) and `sha256` in `Formula/isopod.rb`, commit as
   `chore(brew): isopod 0.3.0`.

4. **Smoke-test the formula** locally before announcing:

   ```sh
   brew install --build-from-source ./Formula/isopod.rb
   brew test isopod
   brew audit --strict --formula ./Formula/isopod.rb   # tap-level audit
   isopod doctor
   ```

## Before the first tagged release

Until `v0.3.0` is tagged and the `sha256` is filled in, the stable formula won't
install — use the HEAD spec, which tracks `master` directly:

```sh
brew install --HEAD ./Formula/isopod.rb
```

## Publishing as a tap (optional)

For `brew tap jonathanmcsweet/isopod && brew install isopod`, put `isopod.rb` in a
repo named `homebrew-isopod` (Homebrew maps `<user>/isopod` → `<user>/homebrew-isopod`).
You can keep this `Formula/isopod.rb` as the source of truth and mirror it there on
each release.
