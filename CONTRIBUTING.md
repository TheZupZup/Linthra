# Contributing to Linthra

Hey, thanks for checking out Linthra.

The project is still growing, so even a small contribution can make a real
difference. Code is welcome, but testing the app, reporting bugs, improving docs,
or helping with tooling is useful too.

You also don't need to know Dart or Flutter. Linthra has a few different areas,
so if you know Kotlin, Rust, C++, Python, SQL, or just want to test things, there
is probably something you can help with.

If you don't know where to start, check the
[issue tracker](https://github.com/TheZupZup/Linthra/issues). `good first issue`
is a good place to start, and `help wanted` means I would really appreciate an
extra pair of hands there.

## Pick the area you know

I don't want languages in the repo just for the GitHub stats. Each one should
have a real reason to be there.

| Language | Good place to contribute |
| --- | --- |
| **Dart / Flutter** | UI, player logic, providers, onboarding, app features |
| **Kotlin** | Android APIs, SAF/MediaStore, media session, Android Auto, platform channels |
| **Rust** | large-library indexing/search and performance-heavy core work |
| **C++** | realtime audio DSP, EQ, limiting, audio processing |
| **Python** | developer tooling, fixtures, benchmarks, validation |
| **SQL** | SQLite indexes, query plans and large-library performance |

There is a more detailed map in
[Contributing by language](./docs/language-areas.md).

## Setting up the project

For normal Dart/Flutter/Android work, start with:

```bash
./scripts/setup_flutter.sh
./scripts/verify_android.sh
```

`setup_flutter.sh` installs or reuses the pinned Flutter version without sudo.
`verify_android.sh` runs the main Flutter checks and can build a debug APK when
an Android SDK is available.

If you came for the Rust core, the C++ DSP or the Python tooling instead, there
is one command that covers all three:

```bash
./scripts/verify_native.sh
```

It runs what CI runs, in CI's order: `cargo fmt --check`, Clippy with warnings
as errors, `cargo test` and the 200k-track benchmark for `native/linthra_core/`;
a CMake configure, build and `ctest` in both Release and Debug for
`native/linthra_audio/` and `native/linthra_desktop/`; then the Ruff checks and
the Python tooling tests. The output is split into Rust, C++ and Python
sections.

A toolchain you don't have installed is skipped with a note about what it needs,
so the script is still useful if you only have one of the three. Anything that
actually fails makes it exit non-zero. `./scripts/doctor.sh` reports what it
found without running any of it.

More setup details are in [docs/development.md](./docs/development.md), and the
[codebase tour](./docs/codebase-tour.md) is useful if you want to see where
things live before touching the code.

For the other areas:

- `native/linthra_core/` uses Cargo.
- `native/linthra_audio/` and `native/linthra_desktop/` use CMake.
- `linux/` is the native Linux desktop runner (C++/GTK/CMake). Its setup —
  required distribution packages, how to run Linthra on Linux from source, and
  what is still unsupported there — is in
  [docs/linux-desktop.md](./docs/linux-desktop.md); `./scripts/verify_linux.sh`
  is the desktop twin of `verify_android.sh`.
- `flatpak/` packages that Linux build as a Flatpak. Building, installing and
  debugging it locally — on Fedora Atomic (Kinoite/Silverblue) or anywhere
  else — is [docs/flatpak-development.md](./docs/flatpak-development.md).
- `tools/large_library/` contains the Python and SQLite large-library tooling.
- Python tooling (`scripts/`, `tool/`, `tools/`) is checked with
  [Ruff](https://docs.astral.sh/ruff/). Before pushing a Python change, run
  `ruff check scripts tool tools` and `ruff format --check scripts tool tools` —
  the same two commands, with the same paths, that CI runs.
  `verify_native.sh` runs both of them for you. Details are in
  [docs/development.md](./docs/development.md#python-tooling-checks-ruff).

## Before you start

If there is already an issue for what you want to fix, leave a comment first.
It helps avoid two people doing the same work without knowing it.

If you find several unrelated problems, I prefer separate small issues when they
can be fixed separately. They are easier to understand, review, assign, and
close that way.

If a few problems are really the same bug or the same flow, one issue with a
small checklist is completely fine.

You can also open a small PR for something that does not already have an issue.
Just explain what you changed and why.

## Pull requests

Please keep PRs focused. One job per PR is much easier for me to review and much
easier for someone else to understand later.

A good PR should:

- explain what changed and why
- link the issue it fixes when there is one
- add tests when the change needs them
- avoid unrelated refactors or formatting changes
- run the relevant checks before pushing

I am completely fine asking for a small correction during review. That is normal
and it does not mean the contribution is bad. If something looks good, I want to
get it merged.

## Code style

I mostly care that the code stays easy to understand and maintain.

- Prefer clear code over clever code.
- Keep files and functions focused.
- Don't create abstractions before there is a real reason for them.
- Comments should explain why something is weird or important, not repeat what
  the code already says.

## Privacy and security

These rules matter a lot for Linthra:

- Never log tokens, passwords, or secrets.
- Don't save authenticated stream URLs in logs, diagnostics, or long-term
  storage.
- Keep credentials encrypted at rest.
- No telemetry or phoning home unless the user explicitly chooses it.

If your change touches authentication, streaming, diagnostics, or stored
credentials, mention it in the PR so I know to review that part carefully.

Found a vulnerability? Don't open a public issue. Report it privately through
[GitHub Private Vulnerability Reporting](https://github.com/TheZupZup/Linthra/security/advisories/new);
[SECURITY.md](./SECURITY.md) has the details of what's in scope and what to
expect.

## Testing

Some bugs only show up on real hardware. If your change touches a real music
server, Cast, Android Auto, offline playback, or something device-specific and
you can test it for real, please say what you tested in the PR.

The [manual QA checklist](./docs/manual-test-checklist.md) covers the important
paths. You can also use **Settings → Report a bug** to build a secret-free report
before opening an issue.

## About contributor funding

Contributing to Linthra is voluntary. A contribution, merged pull request, or
other project participation does not create any entitlement to project revenue,
sponsorships, donations, ownership, equity, royalties, or future compensation.

Project funds remain under the stewardship and control of the project
maintainer and may be used for development, infrastructure, distribution,
testing, services, hardware, or other project needs.

Linthra may choose to reward contributors through bounties, grants, sponsorships,
or paid work when funding permits. Any compensation is discretionary unless it
has been explicitly agreed separately for specific paid work.

Open-source contribution and compensation are separate. Contributions remain
licensed under Linthra's project license, while financial arrangements, when
there are any, are handled separately and do not arise automatically from
contributing code or other work.

## License

Linthra is [AGPL-3.0-or-later](./LICENSE). By contributing, you agree that your
contribution is licensed under the same terms.

Thanks for helping Linthra. Even a small fix is appreciated.
