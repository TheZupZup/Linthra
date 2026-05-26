# Development

Linthra is a standard Flutter app. The **Android** platform scaffold (`android/`)
is committed, so no `flutter create` step is needed. Other native platform
folders (`linux/`, …) are generated locally when you need them, so the repo stays
focused on the cross-platform Dart code.

## Getting started

```bash
# 1. Fetch dependencies
flutter pub get

# 2. Run on a connected Android device or emulator
flutter run

# (Optional) generate scaffolding for another platform, e.g. Linux desktop:
flutter create --platforms=linux .
```

> `flutter create` may regenerate template files such as `main.dart`. If
> prompted, keep the existing versions in this repo.

## Building a debug APK (Android)

You need a working Android SDK (`ANDROID_HOME` / `ANDROID_SDK_ROOT` set) and a
JDK that matches the bundled Gradle wrapper — **JDK 17** is the safe choice for
the Gradle 8.3 / Android Gradle Plugin 8.1 the scaffold ships with. Run
`flutter doctor` to confirm your toolchain.

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

CI pins **Flutter 3.27.x (stable)** for reproducible results; using a matching
SDK locally avoids spurious `dart format` diffs from formatter changes in newer
Dart releases. The automatic `ci.yml` workflow is **code-quality only**; native
builds and optional release signing live in separate workflows.

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
