# CLAUDE.md — guidance for AI agents working in this repo

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
