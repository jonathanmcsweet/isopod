# Homebrew tap seed

`isopod.rb` here is the **source-of-truth seed** for isopod's Homebrew formula.
It is intentionally *not* consumed from this repository — the live formula lives
in a separate **`homebrew-isopod`** tap repo. Keeping it out of the main repo
means the per-PR version-bump check (`.github/workflows/version-bump.yml`) never
forces a version bump just to update a formula sha256, and it removes the
chicken-and-egg of needing a release tarball's sha256 before the release is
tagged.

## Create the tap (one time)

The `homebrew-` prefix is what makes `brew tap jonathanmcsweet/isopod` resolve to
the repo `jonathanmcsweet/homebrew-isopod`.

```sh
# create an empty GitHub repo named "homebrew-isopod", then:
git clone https://github.com/jonathanmcsweet/homebrew-isopod
cd homebrew-isopod
mkdir -p Formula
cp /path/to/isopod/packaging/homebrew/isopod.rb Formula/isopod.rb
git add Formula/isopod.rb
git commit -m "isopod formula"
git push
```

Users can then:

```sh
brew tap jonathanmcsweet/isopod
brew install isopod          # stable once the first release is tagged + sha set
brew install --HEAD isopod   # tracks master immediately
```

## Maintaining it

You bump the formula's `url` + `sha256` **in the tap repo**, not here, after each
release tag. See [`../../RELEASING.md`](../../RELEASING.md) for the full flow
(and `brew bump-formula-pr`, which automates it). Treat this seed as a template to
re-sync from only if the install logic (deps, completions, caveats) changes.
