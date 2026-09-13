# Development

Linthra is a standard Flutter app. The **Android** (`android/`) and **Linux**
(`linux/`) platform scaffolds are both committed, so no `flutter create` step is
needed for either. Any other native platform folder (`windows/`, `macos/`, …)
would be generated locally, and none is a target today.

> Building for the Linux desktop? Start with
> [linux-desktop.md](linux-desktop.md) — required native packages, how to run
> from source, and what is intentionally unsupported so far (playback, most of
> all). Android is the platform Linthra ships on; Linux is not production-ready
> yet.

> New to the code itself? The [codebase tour](codebase-tour.md) maps where each
> feature lives and how the pieces fit together.

## Required toolchain versions

Every toolchain version lives in exactly one file. CI reads those files instead
of repeating the values, so a bump is a one-line edit:

| Tool | Pinned version | Source of truth |
| ---- | -------------- | --------------- |
| Flutter SDK | Flutter 3.44.7 (`stable`) | [`.flutter-version`](../.flutter-version) |
| JDK | JDK 17 (Temurin in CI) | [`.java-version`](../.java-version) |
| Gradle | Gradle 8.14.5 | [`android/gradle/wrapper/gradle-wrapper.properties`](../android/gradle/wrapper/gradle-wrapper.properties) |
| Android Gradle Plugin | AGP 8.10.1 | [`android/settings.gradle`](../android/settings.gradle) |
| Kotlin Gradle plugin | Kotlin 2.2.21 | [`android/settings.gradle`](../android/settings.gradle) |

`scripts/setup_flutter.sh` and the shared `.github/actions/setup-flutter` action
both install the Flutter version from `.flutter-version`; every workflow that
runs Gradle hands `.java-version` to `actions/setup-java`.

`test/tooling/toolchain_pins_test.dart` fails if a workflow, script or doc —
including the table above — names a version that disagrees with those files.
Bumping Flutter may also mean reformatting with the newer Dart and widening the
SDK constraint in `pubspec.yaml`, so keep them in sync to avoid spurious
`dart format` diffs.

## Quick setup

In most environments (including fresh remote agent sessions where Flutter is
missing) you only need two commands:

```bash
./scripts/setup_flutter.sh    # install the pinned Flutter (no sudo, cached locally)
./scripts/verify_android.sh   # run the same checks CI runs
```

`scripts/doctor.sh` prints a quick read-only report of what's pinned, which
Flutter would be used, and whether an Android SDK is present.

### What `setup_flutter.sh` does

- Reads the pinned version from `.flutter-version`.
- **Reuses an existing matching Flutter** — if a project-local SDK or a Flutter
  already on your `PATH` matches the pinned version, nothing is downloaded.
- Otherwise downloads the pinned Flutter into the git-ignored **`.tool/flutter`**
  directory (no `sudo`, no Android SDK required, safe to re-run).
- Prints the `PATH` export to use the local SDK directly:
  `export PATH="<repo>/.tool/flutter/bin:$PATH"`.

The verification script auto-detects `.tool/flutter`, so you don't have to
update `PATH` just to run it.

`scripts/verify_linux.sh` is the desktop twin: the same shared checks plus the
Linux runner configuration check, the native audio lifecycle smoke test, and
`flutter build linux --release`. See [linux-desktop.md](linux-desktop.md).

### What `verify_android.sh` does

Runs, in CI order, and exits non-zero if any real check fails:

1. `flutter pub get`
2. `dart format --set-exit-if-changed .`
3. `flutter analyze`
4. `flutter test`
5. `flutter build apk --debug` — **only if an Android SDK is detected**

If no Android SDK is found (`ANDROID_HOME`/`ANDROID_SDK_ROOT` unset and no
`adb`/`sdkmanager` on `PATH`), the APK build is **skipped with a warning** —
verification does **not** fail just because the Android SDK is missing. The
analyze/format/test steps still run and still fail the script if they fail.

### What `verify_native.sh` does

The same idea for the non-Flutter areas, so a Rust, C++ or Python contributor
has one command instead of three workflows to read. It runs, in CI's order, and
exits non-zero if any real check fails:

1. **Rust** (`native/linthra_core`, mirroring `rust-core.yml`): `cargo fmt
   --check`, `cargo clippy --all-targets` with `-D warnings`, `cargo test`, and
   the `benchmark_200k` binary, which asserts the large-library search budget.
2. **C++** (mirroring `cpp-audio-dsp.yml` and `cpp-desktop-window.yml`): a
   CMake configure, build and `ctest` for `native/linthra_audio` and
   `native/linthra_desktop`, in Release and Debug. Debug skips
   `linthra_audio_realtime_budget` exactly as CI does: an unoptimized build says
   nothing useful about the realtime budget of the build users actually get.
3. **Python** (mirroring `python-lint.yml`): `ruff check scripts tool tools`,
   `ruff format --check scripts tool tools`, and every `test/tooling/*_test.py`,
   which CI runs a file at a time across five workflows.

A toolchain that isn't installed **skips** that part with a message naming what
to install, the same way the APK build is skipped above, and the summary lists
everything skipped so a pass is never read as full coverage. If nothing at all
could be checked, that is an error rather than a pass. `scripts/doctor.sh`
reports the same toolchains without running anything.

Nothing it runs writes to a tracked file: Cargo builds into
`native/linthra_core/target/` and CMake into `build/`, both git-ignored, and
Ruff runs with `--check`. `test/tooling/verify_native_test.py` holds it to all
of that, using stub `cargo`/`cmake`/`ctest`/`ruff` binaries, so it needs none of
those toolchains itself.

### How this helps

Contributors and future Claude/agent sessions get a consistent toolchain in two
commands instead of rediscovering the CI Flutter version, hand-downloading
Flutter, and improvising verification commands. The pinned version is the single
source of truth, so docs, scripts, and CI don't drift.

## Getting started (manual)

If you already have the right Flutter on your `PATH`, you can skip the setup
script entirely:

```bash
# 1. Fetch dependencies
flutter pub get

# 2. Run on a connected Android device or emulator
flutter run

# Or run the native Linux desktop build (see linux-desktop.md for the
# native packages it needs first):
flutter run -d linux
```

> Do **not** re-run `flutter create` to "refresh" a platform folder. It
> regenerates template files — `lib/main.dart`, and for Linux the window
> identity and the offline SQLite seam in `linux/` — over Linthra's own edits.
> `.metadata` lists those files as unmanaged and
> `scripts/check_linux_runner.py` fails if they are ever reverted.

## What is intentionally not committed

The repo holds source and the committed `android/` and `linux/` scaffolds only
— the toolchain is installed per-environment:

- **The Flutter SDK** — downloaded into the git-ignored `.tool/flutter`.
- **The Android SDK** — provided by your machine/CI, never vendored here.
- **Dart/Flutter caches and build output** — `.dart_tool/`, `build/`,
  `linux/flutter/ephemeral/`, etc.
- **The Linux native toolchain** (clang/cmake/ninja/GTK/libsecret) — installed
  from your distribution; see [linux-desktop.md](linux-desktop.md).

CI installs Flutter via the `subosito/flutter-action` GitHub Action rather than
these scripts, but reads the **same** `.flutter-version` file to decide which
version that is (see `.github/actions/setup-flutter`). The scripts exist for
local and remote-agent environments where that Action isn't running; both paths
produce the same checks. APK builds (CI's separate workflows, or the local
`flutter build apk`) require an Android SDK; `flutter analyze` and `flutter test`
do not.

## Troubleshooting

- **`Flutter not found`** — run `./scripts/setup_flutter.sh`, then either re-run
  `./scripts/verify_android.sh` (it auto-detects `.tool/flutter`) or
  `export PATH="$(pwd)/.tool/flutter/bin:$PATH"` to use `flutter`/`dart`
  directly.
- **Android SDK missing** — expected on machines without the Android SDK; the
  APK build is skipped and verification still passes if analyze/format/tests
  pass. Install the Android SDK and set `ANDROID_HOME` to enable
  `flutter build apk --debug`.
- **Linux build/runtime dependencies missing** — `./scripts/verify_linux.sh`
  names the packages (including the libmpv runtime) it could not find and
  skips only the audio smoke test and the build step;
  [linux-desktop.md](linux-desktop.md) lists them per distribution.
- **`dart format` mismatch** — run `dart format .` to apply the formatter, then
  commit the result. CI uses `--set-exit-if-changed`, so unformatted code fails.
  Make sure you're on the pinned Flutter — a newer Dart can reformat differently.
- **Tests fail** — re-run a single suite with `flutter test path/to/test.dart`
  to iterate; `verify_android.sh` runs the full `flutter test` and reports which
  steps failed at the end.
- **Download/extract fails in `setup_flutter.sh`** — the script needs `curl` or
  `wget` plus `tar`/`unzip` and exits with a clear error if a step fails. Check
  network access, then re-run (it's safe to run repeatedly).

## Building a debug APK (Android)

You need a working Android SDK (`ANDROID_HOME` / `ANDROID_SDK_ROOT` set) and a
JDK that matches the bundled Gradle wrapper — use the pinned **JDK 17** from
[`.java-version`](../.java-version), the same one CI installs for the Gradle
8.14.5 / Android Gradle Plugin 8.10.1 the project pins. Run `flutter doctor` to
confirm your toolchain.

```bash
flutter pub get

# Build an unsigned debug APK
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk

# Or build and install straight onto a connected device
flutter run --debug          # hot-reloadable dev session
flutter install              # installs the last debug build
```

The debug APK is unsigned and meant for local testing only.

### Downloading a debug APK from CI

If you don't have a local Flutter/Android toolchain, the **Android Debug APK**
workflow (`.github/workflows/android-debug-apk.yml`) builds the same
`flutter build apk --debug` output on GitHub and attaches it as a downloadable
artifact (`linthra-debug-apk`, containing `app-debug.apk`).

- **Run it:** repo **Actions** tab → **Android Debug APK** → **Run workflow**
  (`workflow_dispatch`). It also runs automatically on pull requests.
- **Install:** download the artifact (GitHub serves it as a `.zip`; unzip to get
  `app-debug.apk`), then copy it to a device and open it (allow "install from
  unknown sources"), or `adb install -r app-debug.apk`.

This artifact is an **unsigned debug build for testing only** — not signed for
release, not published to any store or F-Droid.

## Building release artifacts (Android)

The **Android Release Build** workflow
(`.github/workflows/android-release-build.yml`) builds the Android **release**
artifacts. It runs **manually** for test builds and **automatically on version
tags** (`v*`). It never publishes to a store or F-Droid and never writes
production release notes.

```bash
flutter pub get
flutter build apk --release        # → build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release  # → build/app/outputs/bundle/release/app-release.aab
```

Artifacts are named with both the version (tag) and the signing label, so a
debug-signed preview can never be mistaken for a production release
(e.g. `linthra-v0.1.0-alpha.1-debug-signed.apk`). Pre-release tags
(`alpha`/`beta`/`rc`) attach to a GitHub **pre-release** (created if absent);
stable tags **require release signing** and only attach to a Release you created
manually. Full versioning/tagging flow is in
[release-process.md](release-process.md).

### Versioning

Local `flutter build`/`flutter run` use the `pubspec.yaml` version, and so does
the in-app **Settings ▸ About** version (`AppInfo.version`). A **tagged** release
build instead derives the version from the tag and bakes it into both the
APK/AAB metadata and the in-app display, so they always match — see
[release-process.md §1](release-process.md#1-versioning-model).

Preview what a tag maps to, or reproduce a tag build locally:

```bash
# What versionName/versionCode does a tag produce?
dart run tool/version_from_tag.dart v0.1.0-alpha.16
# LINTHRA_VERSION_NAME=0.1.0-alpha.16
# LINTHRA_VERSION_CODE=100016

# Build exactly as a tag build would (version baked into metadata + in-app UI):
flutter build apk --release \
  --build-name=0.1.0-alpha.16 --build-number=100016 \
  --dart-define=LINTHRA_VERSION_NAME=0.1.0-alpha.16
```

### Signing status

Release signing is **wired up but not yet provisioned**. `android/app/build.gradle`
resolves a release signing config from environment variables (CI) or a
git-ignored `android/key.properties` (local). Only if complete signing material
is present does it sign with the release key; otherwise it falls back to the
**debug** key so `flutter run --release` still works. **No signing keys or
secrets are committed.** Required secrets, keystore generation/rotation, and how
this relates to F-Droid (which signs its own builds) are in
[release-signing.md](release-signing.md).

## Continuous integration

Every pull request and every push to `main` runs a small Flutter workflow
(`.github/workflows/ci.yml`). Run the exact same checks locally before opening a
PR:

```bash
flutter pub get                      # resolve dependencies
dart format --set-exit-if-changed .  # code must already match `dart format`
flutter analyze                      # static analysis + lints
flutter test                         # widget/unit tests
```

CI pins **Flutter 3.44.x (stable)** for reproducible results; using a matching
SDK locally avoids spurious `dart format` diffs from formatter changes in newer
Dart releases. The automatic `ci.yml` workflow is **code-quality only**; native
builds and optional release signing live in separate workflows.

### Python tooling checks (Ruff)

Linthra's Python — the release/toolchain scripts in `scripts/`, icon generation
in `tool/branding/`, and the large-library fixtures and benchmarks in
`tools/large_library/` — is linted and format-checked by
[Ruff](https://docs.astral.sh/ruff/) in the **Python lint** workflow
(`.github/workflows/python-lint.yml`), which runs on every PR that touches those
files. Run the same two checks locally:

```bash
pip install 'ruff==0.15.8'                  # the version CI pins
ruff check scripts tool tools              # lint
ruff format --check scripts tool tools     # formatting (drop --check to apply)
```

Pass those three paths — they are what CI passes, and they are what defines the
linted scope. `ruff.toml` at the repository root holds the rules and a few
excludes, but it does not restrict Ruff to those trees, so a bare `ruff check .`
is a *different* check: it would also report a Python file added elsewhere in the
repository, which this workflow never looks at.

CI pins the Ruff version for the same reason it pins Flutter: a new release can
add rules or change formatter output, and that should land as its own reviewable
bump rather than turning an unrelated PR red.

### Generating Drift files in CI

Drift/SQLite persistence relies on `build_runner` code generation, which can be
unreliable to run locally. The **Generate Drift files** workflow
(`.github/workflows/generate-drift.yml`) runs that generation in CI and commits
the result back to the chosen branch. It is **manual only**
(`workflow_dispatch`). Run it on your **PR branch** (not `main`): Actions →
**Generate Drift files** → **Run workflow** → choose the branch, then let the bot
push the generated commit before normal CI runs.

## Android identity & permissions

The app ships with a stable application ID **`io.github.thezupzup.linthra`** (also
the Kotlin/Gradle `namespace`) and the display name **Linthra**. The production
manifest declares only:

- **`FOREGROUND_SERVICE`** / **`FOREGROUND_SERVICE_MEDIA_PLAYBACK`** — so
  `audio_service` can keep playing while backgrounded (Android 14+ requires the
  typed `mediaPlayback` grant).
- **`POST_NOTIFICATIONS`** — required on Android 13+ for the media notification;
  a *runtime* permission requested once on first launch.
- **`INTERNET`** — to reach a self-hosted Jellyfin / Subsonic server.

**No storage permission is requested** — folder access uses the Storage Access
Framework grant the user picks (see [architecture.md](architecture.md#android-folder-selection-saf)).

### Native media-session setup (applied)

The committed scaffold wires `audio_service` so the media session runs as a
foreground service and is visible to Android Auto: the manifest declares the
`com.ryanheise.audioservice.AudioService` playback service (with the
`MediaBrowserService` action and `mediaPlayback` foreground type), the
`MediaButtonReceiver`, and the `com.google.android.gms.car.application` Android
Auto media-app meta-data; `MainActivity` extends `AudioServiceActivity`. The
notification channel id/name are set in `connectMediaSession` (`com.linthra.audio`
/ "Linthra playback"). See [android-auto.md](android-auto.md) for the browse tree
and testing.

## Manual smoke test on a real Android phone

After installing the debug APK on a physical device (most useful on **Android
13+**, where the runtime notification permission applies), walk the
[manual QA checklist](manual-test-checklist.md). It covers the paths that only
behave correctly on real hardware: first-launch notification prompt, folder
pick & scan, local playback, background playback & lock-screen controls, Jellyfin
connect/sync/stream, friendly playback errors, offline downloads, the mobile-data
gate, Cast, and Android Auto — plus a security spot-check that no token ever
appears on screen.
