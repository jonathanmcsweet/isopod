# Guidance for AI agents working in this repo

## Your behavior
- Never modify this document without consulting the user first
- Explain things in concise, plain english free of technical jargon.
- Use technical terms accurate to the domain terms in the codebase
- When making technical decisions, do not give weight to development cost or development hours. Instead prefer readability, quality, simplicity, robustness, scalability, testability, and long term maintainability
- when writting code comments or commit messages, be extremely concise. Favor concision over proper grammar.
- never use em dash

## In-app text and user documentation
- Write as one person telling another something useful, not as a specification.
- Let related facts share a sentence with commas or appositives. Don't give each fact its own sentence.
- Say what a thing is and what it's good for, not what it isn't.
- Don't add a paragraph explaining how to interpret what you just said.
- Cut any detail that doesn't change what the reader thinks or does.
- Never end a paragraph on a short punchy line.

## What this repo is
Isopod is a CLI utility meant to make it easier for developers to use agents and LLMS in a safe manner via sandboxing. Isopod also contains an important key features that let developers copy files in or pull from a git repo, and fetch / copy them out. Another key feature is allowing them to rapidly launch an IDE (VSCodium for now) to connect to the sandbox via SSH. It has varying levels of sandboxing and security mitigations depending on the user's preferences and device capabilities. Our first most important users are Linux users, including all the distros mentioned in the README.md.

## Chores
- Always bump the ISOPOD_VERSION based on semantic versioning when commiting your final work to
  a branch
- SemVer reference: https://semver.org

## Documentation
- Keep text descriptions short without excessive details unless necessary to prevent confusion
- Refrain from using idiomatic language such as "clobber" or "belt and suspenders" which may be
  read differently by different people

## Branches and Commit messages — use Conventional Commits

Follow the spec: <https://www.conventionalcommits.org/en/v1.0.0/#specification>

```
<type>[optional scope][!]: <description>

[optional body]

[optional footer(s)]
```

- **Allowed types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`.
- **description:** imperative mood, lowercase, no trailing period.
- **Breaking changes:** add `!` after the type/scope (e.g. `feat(create)!:`) and/or
  a `BREAKING CHANGE:` footer.
- **Examples:**
  - `feat(security): add container fingerprint hardening`
  - `fix(create): bind sshd to loopback only`
  - `chore: adopt test/ and lib/ layout`
- End messages with the `Co-Authored-By:` trailer naming the AI model used.

## Before committing

- Run `bash test/run.sh` (lint + stubbed + interactive suites) and keep it green.
  `RUN_LIVE=1 bash test/run.sh` also runs real-container tests.
- Never commit items in `.gitignore`.

## No inline foreign-language code — extract to its own file

- NEVER embed another language (Python, etc.) inline in the `isopod` bash script
  Put it in its own file under  `lib/` and invoke that file.
- Mirror the existing pattern: reference the helper as `"$ISOPOD_LIB/<name>.py"`,
  guard it (`[ -f "$script" ] || die "missing helper: $script …"`), then run it
  (`python3 "$script"`, or `python3 - < "$script"` to stream it into a box).
  See `lib/apply_color.py` (runs in the box) and
  `lib/remap_identity_filter.py` (runs on the host) for the two cases.
- Give each helper a module docstring and keep it independently runnable/lintable.
  `install.sh` ships everything in `lib/`, so new helpers are picked up
  automatically.

## Repo structure rules

- `lib/` MUST sit beside the `isopod` script — it is streamed into the box.
- CLI functions live in sourced modules under `lib/isopod.d/*.sh` (one file per
  domain). The `isopod` entry script keeps only globals/constants (including
  `ISOPOD_VERSION` — release tooling reads it from there), the module source
  loop, and `main`. Helpers streamed into the box or executed as subprocesses
  stay directly in `lib/`, never in `lib/isopod.d/`. New modules must be added
  to the source loop in `isopod` and the lint lists in `test/run.sh`,
  `.pre-commit-config.yaml`, `.gitlab-ci.yml`, and `.github/workflows/ci.yml`
  cover them via the `lib/isopod.d/*.sh` glob.
- Container hardening settings live in `security/hardening.conf` (declarative),
  not inline in the `isopod` script. `security/compose.yaml` is reference-only and
  is NOT executed by the CLI.
- Long strings and constant lists/lookup tables MUST live as files under
  `share/`, NOT inline in the `isopod` script. This covers multi-line
  user-facing text (usage, the create/info/code messages, the ssh_config entry)
  AND data tables (e.g. the color palette in `share/colors`). When you add a new
  large string or constant list in the future, put it in `share/` — do not embed
  it as an inline heredoc or a hardcoded `case`/array.
- Render text templates with `render_tmpl <file>` — the file body is evaluated
  as a heredoc, so `$vars` and `$(...)` inside it still expand against the
  caller's scope. Keep `$var` references in templates in sync with the
  locals/globals available where `render_tmpl` is called. Read plain data tables
  with a `while read` loop (see `preset_color`).
