# Development guide

How to set up a working copy of isopod for development: linting, formatting,
pre-commit hooks, and tests.

## One-time setup

isopod is a bash project linted with [ShellCheck](https://www.shellcheck.net/)
and formatted with [shfmt](https://github.com/mvdan/sh). Both run automatically
as [pre-commit](https://pre-commit.com/) hooks:

```sh
pip install pre-commit      # or: pipx install pre-commit, brew install pre-commit
pre-commit install          # wire the hook into .git/hooks
```

That's all you need — the hooks **self-provision** their own ShellCheck and shfmt
binaries, so you don't have to install those separately (no Docker or Go
toolchain required). Tool versions are pinned in
[`.pre-commit-config.yaml`](../.pre-commit-config.yaml).

> If you installed pre-commit with `pip install --user`, its binary lands in
> `~/.local/bin`, which may not be on your `PATH`. Add
> `export PATH="$HOME/.local/bin:$PATH"` to your shell profile if `pre-commit`
> isn't found. Also note pre-commit needs Python's `venv` module to build the
> hook environments — a separate package on Debian/Ubuntu
> (`sudo apt install python3-venv`), part of `python3` on Fedora, Arch, and
> Gentoo.

## What the hooks enforce

| Tool | Role | Scope | Stage |
|------|------|-------|-------|
| ShellCheck (`-S warning`) | static analysis / linting | `isopod`, `lib/isopod.d/*.sh`, `share/isopod-entrypoint`, `lib/find_box_repo.sh`, `install.sh`, `verify-host-isolation.sh`, `test/{run,packaging,egress-render,brew-formula,distro-install}.sh` | commit |
| shfmt (`-i 2 -ci`) | formatting | the above + `test/helper.bash`, `completions/isopod.bash` | commit |
| actionlint | lint GitHub Actions workflows | `.github/workflows/*` | commit |

`.bats` test files and the zsh completion (`completions/_isopod`) are excluded
from the bash hooks — neither tool can parse them.

### CI-file checks (only fire when that CI file changes)

The bash + actionlint hooks self-provision and run on every commit. Two heavier
hooks actually *run* the pipelines locally, so they're on the **pre-push** stage
and only trigger when their CI file is staged:

| Hook | Runs | When | Needs |
|------|------|------|-------|
| `act-github-ci` | `act -j lint` | `.github/workflows/*` changed | [act](https://github.com/nektos/act) + Docker |
| `gitlab-ci-local` | `gitlab-ci-local shellcheck unit-and-integration` | `.gitlab-ci.yml` changed | [gitlab-ci-local](https://github.com/firecow/gitlab-ci-local) (`npm i -g gitlab-ci-local`) + Docker |

These use tools you install yourself (pre-commit does **not** provision `act` or
`gitlab-ci-local`). To enable the pre-push stage:

```sh
pre-commit install --hook-type pre-push
```

The GitLab hook deliberately skips the `live-isolation` job (it needs privileged
podman-in-podman). `act` lints the GitHub `lint` job; expand the args if you want
more jobs run before pushing.

Formatting style (2-space indent, indented `case` branches) is declared once in
[`.editorconfig`](../.editorconfig) so editors with EditorConfig support match the
hook automatically. Keep the `.editorconfig` shell keys and the shfmt args in
`.pre-commit-config.yaml` in sync.

## Running checks by hand

```sh
pre-commit run --all-files          # run every hook against the whole repo
pre-commit run shfmt --all-files    # just the formatter (auto-fixes in place)
shfmt -i 2 -ci -w <files>           # format directly if you have shfmt installed
```

The same checks also run as the first step of the test suite (the `shellcheck`
and `shfmt` steps in [`test/run.sh`](../test/run.sh)), each gated on the tool
being present, so they're the same locally and in CI.

## Tests

```sh
test/run.sh              # lint + formatting + stubbed bats + interactive
RUN_LIVE=1 test/run.sh   # also runs live tests against real podman/docker
```

The suite lives under `test/`, using [bats-core](https://github.com/bats-core/bats-core)
and pexpect for the interactive prompts. Run `test/run.sh` and keep it green
before committing; `RUN_LIVE=1` adds the end-to-end tests against a real
podman/docker.

CI runs on both GitLab and GitHub with the same core jobs — lint (shellcheck +
bash syntax + python), test (stubbed + interactive, runs anywhere), and a manual
`live-isolation` job that needs a podman-capable runner. GitHub additionally runs
`macos` (BSD-userland lint + test), `brew-formula` (installs isopod through the
Homebrew tap formula built from the checkout), and `distro-install` (runs
`install.sh` for real on Fedora, immutable Fedora, Ubuntu, Arch, and Gentoo
images); job names differ slightly between the two systems, but the roles match.

Run one distro check locally against any image:

```sh
docker run --rm -v "$PWD:/src:ro" -w /src archlinux:latest \
  bash test/distro-install.sh pacman     # expected package-manager hint
```

- **GitLab CI/CD** (`.gitlab-ci.yml`) should run identically under
  [`gitlab-ci-local`](https://github.com/firecow/gitlab-ci-local) for debugging
  pipelines on your own machine before pushing.
- **GitHub Actions** (`.github/workflows/ci.yml`) runs locally with
  [`act`](https://github.com/nektos/act): `act -j lint`, `act -j test`. The
  `live-isolation` job needs container-in-container and is gated to manual
  dispatch, so run it the native way instead: `RUN_LIVE=1 test/run.sh`. Bare `act`
  also tries `macos`/`brew-formula`, which aren't expected to work under `act`'s
  runner. (An `.actrc` pins a runner image with the tooling the jobs expect.)

## Repo conventions

Project-specific rules — extracting long strings to `share/`, keeping helper
scripts in `lib/`, Conventional Commits — live in
[`CLAUDE.md`](../CLAUDE.md). Read it before making structural changes.

The CLI's functions live in sourced modules under `lib/isopod.d/` (one file per
domain: engine, ssh, hardening, egress, …). The `isopod` entry point keeps only
globals, the module source loop, and `main`.
