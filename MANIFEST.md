# isopod — repository structure

This is the canonical layout. If files are in the wrong place, compare against
this tree. The two structural rules that matter:

  1. `lib/` MUST sit beside the `isopod` script (isopod streams
     `lib/apply_color.py` into the container for color theming).
  2. `test/libs/` holds the vendored bats framework — keep it intact to run
     the test suite, but it is NOT needed to USE isopod. The installer excludes
     `test/` from installs.

```
isopod-project/
├── isopod                     # the CLI (bash)            [executable]
├── install.sh                # cross-platform installer  [executable]
├── README.md                 # docs (install, usage, security model)
├── MANIFEST.md               # this file
├── .gitattributes            # forces LF line endings (avoids CRLF breakage)
├── .gitignore
├── .gitlab-ci.yml            # GitLab CI (lint + test stages, manual live stage)
├── .github/workflows/ci.yml  # GitHub Actions (same jobs; run locally with `act`)
├── .actrc                    # default `act` flags (runner image for local runs)
├── lib/
│   └── apply_color.py        # window-color merge, run inside the box [executable]
├── security/
│   ├── hardening.conf        # anti-fingerprinting profile (Tier 1 masks + Tier 2 runtime)
│   └── compose.yaml          # reference Compose form of the same masks (not run by isopod)
└── test/
    ├── run.sh                # local test runner               [executable]
    ├── helper.bash           # shared bats setup + stubs
    ├── unit.bats             # pure-function unit tests
    ├── theming.bats          # color-merge + IDE-detection tests
    ├── integration.bats      # command-flow tests (engine stubbed)
    ├── live.bats             # real-container tests (RUN_LIVE=1)
    ├── interactive_test.py   # pexpect tests for the rm prompt   [executable]
    └── libs/                 # vendored bats-core/support/assert
        ├── bats-core/
        ├── bats-support/
        └── bats-assert/
```

## Execute bits

Downloads and copies often drop the executable bit. If you cloned/extracted and
scripts won't run, restore them with:

```sh
chmod +x isopod install.sh lib/apply_color.py \
         test/run.sh test/interactive_test.py \
         test/libs/bats-core/bin/bats
```

When committing to git, set them permanently so clones get runnable files:

```sh
git update-index --chmod=+x isopod install.sh lib/apply_color.py \
         test/run.sh test/interactive_test.py
```

## Quick verification

```sh
./install.sh --check   # prints what an install would do, changes nothing
bash test/run.sh       # runs lint + the stubbed/interactive test suites
```
