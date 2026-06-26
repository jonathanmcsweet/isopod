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
> isn't found. Also note pre-commit needs `python3-venv` to build the hook
> environments (`sudo apt install python3-venv` on Debian/Ubuntu).

## What the hooks enforce

| Tool | Role | Scope | Stage |
|------|------|-------|-------|
| ShellCheck (`-S warning`) | static analysis / linting | `isopod`, `install.sh`, `verify-host-isolation.sh`, `test/*.sh` | commit |
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

Run `test/run.sh` and keep it green before committing. See the
[Testing section of the README](../README.md#testing) for the CI layout.

## Repo conventions

Project-specific rules — extracting long strings to `share/`, keeping helper
scripts in `lib/`, Conventional Commits — live in
[`CLAUDE.md`](../CLAUDE.md). Read it before making structural changes.
