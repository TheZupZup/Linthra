# Contributing to Linthra

Hey — thanks for being here. Linthra is a self-hosted Android music player, and
it's early alpha, which is honestly the best time to get involved: small changes
land fast and genuinely shape where the project goes.

You don't need to be a Flutter expert to help. Testing the app against your own
server, capturing a screenshot, or fixing a confusing line in the docs are all
real, useful contributions. If you're not sure where to start, the
[contributor roadmap](./docs/contributor-roadmap.md) lays out where help matters
most right now.

## Setting up the project

Linthra is a standard Flutter app with a committed Android scaffold, so there's
no `flutter create` step. In most environments you only need two commands:

```bash
./scripts/setup_flutter.sh    # installs the pinned Flutter (no sudo, cached locally)
./scripts/verify_android.sh   # runs the same checks CI runs
```

`setup_flutter.sh` reuses a matching Flutter if you already have one, or
downloads the pinned version into the git-ignored `.tool/flutter`.
`verify_android.sh` runs `flutter pub get`, `dart format`, `flutter analyze`,
`flutter test`, and an APK build (only if an Android SDK is present). Full
details, troubleshooting, and the manual path are in
[docs/development.md](./docs/development.md).

## Finding your way around the code

When you're ready to dig in, the [codebase tour](./docs/codebase-tour.md) is a
map of where each feature lives — playback, Cast, the Jellyfin/Subsonic
providers, downloads, diagnostics, settings — and how they're wired together.
[docs/architecture.md](./docs/architecture.md) covers the layering and the
extension points behind it.

## Picking something to work on

- Browse the [issue tracker](https://github.com/thezupzup/linthra/issues).
  Issues tagged **`good first issue`** are scoped to be approachable, and
  **`help wanted`** flags where an extra pair of hands would help most.
- Comment on an issue before you start so we don't double up.
- Opening a small PR for something not yet tracked is fine too — just explain
  what and why in the description.

### Good first contributions

A few that don't go too deep into the codebase:

- Test Linthra against your **Jellyfin** or **Navidrome / Subsonic** server and
  file a compatibility report.
- Try **Cast** or **Android Auto** on real hardware and tell us what happened.
- Capture **screenshots** of a running build for the README and store listing.
- Improve a doc — fix a step that tripped you up, add a setup gotcha.
- Add or improve **accessibility labels** so screen readers announce controls
  clearly.
- Polish an **empty state** so a blank screen explains what to do next.

## Pull requests

- **Keep PRs small and focused.** One change per PR is much easier to review and
  merge than a big bundle.
- **Write a clear description** — what changed and why. Link the issue it closes.
- **Add tests when it makes sense** — bug fixes and new logic especially.
- **No unrelated changes.** Resist the urge to reformat or refactor nearby code
  in the same PR; open a separate one if it's worth doing.
- Run `./scripts/verify_android.sh` (or the CI commands) before pushing — CI runs
  `dart format --set-exit-if-changed`, so unformatted code will fail.

## Code style

Nothing exotic here — just code that's easy to read and easy to maintain:

- **Readable over clever.** Clear names and straightforward control flow beat a
  one-liner that needs a comment to decode.
- **Modular.** Keep files and functions focused; split things up before they
  grow into a single huge file.
- **No premature abstraction.** Don't add a layer or a generic helper until
  there's a real second use for it. Three similar lines are fine.
- **Comment the why, not the what.** Most code shouldn't need a comment; when it
  does, explain the non-obvious reason.

## Privacy & security

Respecting the people who run Linthra is a core part of the project, so a few
rules are non-negotiable in any contribution:

- **Never log tokens, passwords, or secrets.** Linthra's own log lines are
  secret-free by design — keep them that way.
- **Don't persist authenticated URLs.** Stream URLs are minted on demand and
  must not be written to disk, logs, or diagnostics.
- **Keep credentials encrypted at rest.** A server password is used once to get
  a token, then discarded; the token is encrypted and never displayed.
- **No telemetry, no phoning home.** Nothing should leave the device unless the
  user explicitly chooses it.

If a change touches auth, streaming, or diagnostics, call out the security
implications in your PR description so they're easy to review.

## Testing on Android

Some behaviour only shows up on real hardware. If your change touches any of
these, please test on a device and note what you checked:

- **Jellyfin / Navidrome** — connect, sync, stream; confirm no secrets appear
  on screen or in logs.
- **Offline cache** — downloads stay user-initiated and Wi-Fi-only by default;
  pinned ("Keep offline") tracks aren't evicted.
- **Cast** — discovery, connect/disconnect, playback, volume; watch for
  duplicate local + Cast playback.
- **Android Auto** — sideloaded builds only appear after enabling Android Auto's
  developer **"Unknown sources"** toggle (see
  [docs/android-auto.md](./docs/android-auto.md)); check browsing and playback.

The [manual QA checklist](./docs/manual-test-checklist.md) walks through the
paths that matter most on a real phone.

## Reporting bugs

The friendliest way is right in the app: **Settings → Report a bug** builds a
secret-free report locally (versions, connection state, host, counts — no
tokens or passwords), which you can review and then open as a prefilled GitHub
issue. Details in [docs/reporting-bugs.md](./docs/reporting-bugs.md).

## License

Linthra is [MPL-2.0](./LICENSE). By contributing, you agree your contributions
are licensed under the same terms.

Thanks again — see you in the issues.
