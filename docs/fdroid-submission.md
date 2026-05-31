# F-Droid submission package (draft)

This is the working material for proposing Linthra to F-Droid: a merge-request
description you can adapt for [fdroiddata](https://gitlab.com/fdroid/fdroiddata),
the build-recipe and version decisions, where verification stands, the remaining
blockers, and the steps to actually submit.

Linthra hasn't been submitted to F-Droid and isn't on it — this is the prep that
comes before someone opens the merge request. Nothing here publishes or submits
anything.

Related docs: [fdroid-readiness.md](./fdroid-readiness.md) (the overall
checklist), [fdroid-build-recipe.md](./fdroid-build-recipe.md) (recipe and
reproducibility), [dependency-license-audit.md](./dependency-license-audit.md)
(licensing), [listing-assets.md](./listing-assets.md) (icon, graphic,
screenshots), [release-process.md](./release-process.md) (versioning and
tagging), and the draft recipe at
[`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml).

## 1. App identity

| Field   | Value                         |
| ------- | ----------------------------- |
| Name    | Linthra                       |
| App ID  | `io.github.thezupzup.linthra` |
| License | `MPL-2.0` (SPDX)              |
| Source  | https://github.com/TheZupZup/Linthra |
| Issues  | https://github.com/TheZupZup/Linthra/issues |
| Category| Multimedia                    |

## 2. Target version and auto-update

F-Droid builds from a git tag, and Linthra now has tags (`v0.1.0-alpha.1` …
`v0.1.0-alpha.30`, built by the Android Release Build workflow). The submission
targets the latest one that launches cleanly:

| Item            | Value                                   |
| --------------- | --------------------------------------- |
| Target tag      | `v0.1.0-alpha.30`                        |
| versionName     | `0.1.0-alpha.30`                        |
| versionCode     | `100030`                                |
| Changelog file  | `fastlane/metadata/android/en-US/changelogs/100030.txt` |

Don't target `v0.1.0-alpha.24`: its GitHub Release is marked "Broken release — do
not install … startup regression," and alpha.25 was the hotfix that reverted it.

### Auto-update is enabled (versionName/versionCode come from `pubspec.yaml`)

`pubspec.yaml` now carries the release version in lockstep with the tag
(`version: 0.1.0-alpha.30+100030`; see
[release-process.md §1](./release-process.md#1-versioning-model)), so F-Droid
reads it at each tag and tracks new releases **automatically**. The fields that
enable this:

```yaml
AutoUpdateMode: Version
UpdateCheckMode: Tags
UpdateCheckData: pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 0.1.0-alpha.30
CurrentVersionCode: 100030
```

`UpdateCheckData` is **required** for a Flutter app: F-Droid's default `Tags`
path reads only `AndroidManifest.xml`/`build.gradle`, which carry no literal
version for Flutter, so it must be pointed at `pubspec.yaml`. It splits the
`version:` line on `+` — group 1 of the first regex is the `versionCode` (after
`+`), group 1 of the second is the `versionName` (before `+`). F-Droid picks the
highest `versionCode` across the tags, and `AutoUpdateMode: Version` adds a
**plain-build** entry (`flutter build apk --release`, no
`--build-name`/`--build-number`) using the tag as the commit. The changelog file
is named by that `versionCode` (`100030.txt`), in line with
[release-process.md §1](./release-process.md#1-versioning-model) (the older
`1.txt`/`9.txt`/`15.txt` stay as they are).

### One-time transition for the `v0.1.0-alpha.30` tag

`v0.1.0-alpha.30` was tagged **before** `pubspec.yaml` started tracking the
version, so at that exact commit `pubspec.yaml` is still `0.1.0-alpha.15+15` and a
plain build there would report `0.1.0-alpha.15` / `15`. So the single seed
`Builds` entry passes explicit
`--build-name=0.1.0-alpha.30 --build-number=100030 --dart-define=LINTHRA_VERSION_NAME=0.1.0-alpha.30`
to build it as `0.1.0-alpha.30` / `100030`. **From `v0.1.0-alpha.31` onward** the
committed `pubspec.yaml` matches the tag, so those flags are dropped and the build
is a plain `flutter build apk --release`; when `AutoUpdateMode` adds the first new
entry, remove the flags it inherits from the seed (a one-time edit). The draft
recipe at
[`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml)
carries exactly this, with the transition spelled out in comments.

## 3. Build recipe status

The draft recipe is in
[`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml).
What makes it a good fit for building from source:

- It builds with no signing keys — F-Droid signs its own builds. Linthra's
  optional release signing only applies to the GitHub channel and is injected at
  build time (see [release-signing.md](./release-signing.md)); no keystore or
  secret is committed.
- The toolchain is pinned: Flutter `3.27.4` (stable), Dart `3.6.x`, JDK 21,
  Gradle 8.7 — the same versions as `.flutter-version` and CI.
- No codegen step: the Drift output
  `lib/data/database/linthra_database.g.dart` is committed, so there's no
  `build_runner` to run.
- One native component, SQLite via `sqlite3_flutter_libs`, built from source
  (public domain). No prebuilt closed blobs, and no Google Play Services or
  Firebase anywhere in the resolved tree (152 packages, all audited).
- No GitHub Actions secrets or Play signing are involved in the from-source
  build.

A few things still need checking against fdroiddata before submitting:

1. How Flutter gets provisioned. The draft now uses the **`flutter` srclib**
   method from `templates/build-flutter.yml` (`srclibs: [flutter@stable]`,
   referenced as `$$flutter$$`), checking out the version from `.flutter-version`
   (3.27.4) in `prebuild`. No Flutter submodule is added upstream and no SDK is
   cloned by hand. Flutter's engine artifacts are fetched at the pinned version,
   which is normal for Flutter on F-Droid and stays pinned and reproducible.
2. Native toolchain. The only native component is SQLite (`sqlite3_flutter_libs`,
   built from source). If `fdroid build -l` reports a missing NDK/CMake, pin the
   build server's NDK with an `ndk:` field and/or install CMake in `prebuild`
   (`sudo sdkmanager 'cmake;<version>'`), as some Flutter recipes do.
3. The output path. F-Droid now builds **per-ABI APKs** (armeabi-v7a / arm64-v8a
   / x86_64) via `flutter build apk --release --split-per-abi`, with three
   `Builds` entries selecting one output each
   (`build/app/outputs/flutter-apk/app-<abi>-release.apk`) and a matching
   `VercodeOperation` block (`%c*10 + 1/2/3`) so auto-update keeps generating
   one entry per ABI per tag. The `versionCodeOverride` in
   `android/app/build.gradle` applies the same `base * 10 + abi` rule to each
   variant output, so the gradle build and the recipe's `versionCode` always
   agree. The GitHub-Release CI still produces the single universal APK at the
   base `versionCode` (no `--split-per-abi`), so the sideload URL is unchanged.
   This decoupled the recipe from the upstream `Binaries:` URL (which points at
   the universal APK and therefore cannot match per-ABI F-Droid builds), so the
   `Binaries:` field is no longer set; `AllowedAPKSigningKeys` stays as a
   sideload-source check.
4. The `pubspec.lock` policy — still git-ignored. Decide whether to commit it at
   the tagged commit for a fully pinned dependency set
   ([fdroid-build-recipe.md §4](./fdroid-build-recipe.md#4-reproducibility-notes)).
5. The Gradle wrapper jar isn't committed; F-Droid restores it, but confirm the
   recipe handles that (a `flutter build` provisions the wrapper).

## 4. Anti-features

The reasoning is in [fdroid-readiness.md §5](./fdroid-readiness.md#5-anti-features-review)
and [dependency-license-audit.md §6](./dependency-license-audit.md#6-anti-features--non-free-check).
The short version: there's nothing to declare.

| Anti-feature  | Apply? | Why |
| ------------- | ------ | --- |
| Ads           | No  | No ad libraries or code. |
| Tracking      | No  | No telemetry/analytics/crash SDK; on-device signals only; nothing is auto-sent. |
| NonFreeAdd    | No  | It promotes or installs no non-free add-ons. |
| NonFreeDep    | No  | All 152 resolved packages are permissive; playback is AndroidX Media3 (Apache-2.0); Cast is pure-Dart, not the GMS Cast SDK. |
| NonFreeNet    | No  | The local-first core needs no network; Jellyfin/Navidrome/Subsonic are optional, user-supplied, free-software servers — none bundled, promoted, or required. |
| UpstreamNonFree | No | The repo is entirely MPL-2.0; the icons are generated from a committed SVG. |
| KnownVuln     | No  | Nothing in the resolved tree was a known-vulnerable version at audit time; F-Droid's scanner re-checks. |
| NoSourceSince | No  | The source is fully published and builds from source. |

Worth revisiting if a future online provider ever defaults to or promotes a
non-free hosted service — that would need a fresh `NonFreeNet` look.

## 5. Permissions

Six permissions are declared in `AndroidManifest.xml`, and `ACCESS_NETWORK_STATE`
is merged in from the AndroidX Media3 AAR. The set is deliberately small — no
storage, location, contacts, camera, microphone, or phone permission, and no
`MANAGE_EXTERNAL_STORAGE` (folder access goes through the Storage Access
Framework). Each one is explained in
[fdroid-readiness.md §5 (Android permissions)](./fdroid-readiness.md#android-permissions):
`INTERNET`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `POST_NOTIFICATIONS`, `WAKE_LOCK`, and
`CHANGE_WIFI_MULTICAST_STATE` (mDNS for Cast discovery, via AOSP `NsdManager`,
not GMS). Re-confirm the merged set against a release build's manifest before
submitting.

## 6. Listing assets

Tracked in [listing-assets.md](./listing-assets.md). The app icon (512×512) and
feature graphic (1024×500) are committed, generated from
`tool/branding/linthra_icon.svg`. Eight real phone screenshots — captured from a
running build, not mocked — are now committed under
`fastlane/metadata/android/en-US/images/phoneScreenshots/` (Now Playing, the
Library Albums/Artists views, Smart mixes, both provider setup screens, the
diagnostics / bug-report screen, a library-syncing state, and Favorites). What
each shows and the privacy review are in
[listing-assets.md §6](./listing-assets.md). This is the core set tracked by
issue #77; optional extras (Downloads with tracks downloaded, Android Auto, Cast,
tablet layouts) remain nice-to-haves, none of them a merge-request blocker.

## 7. Verification status

What ran in this prep pass, and what didn't. This environment has no Flutter,
Dart, or Android SDK and no fdroidserver, so the app and build checks couldn't
run here — they run in CI and need re-running on a proper machine before
submitting.

| Check | Status |
| ----- | ------ |
| Metadata YAML parses (PyYAML) | Done here — valid YAML, fields and types as expected (no inline Summary/Description; F-Droid pulls them from Fastlane; versionCode an integer, `100030`; `UpdateCheckData` regexes extract `100030` / `0.1.0-alpha.30` from the `pubspec.yaml` `version:` line). This only checks the YAML, not F-Droid's schema (see below). |
| `flutter pub get` | Not run here (no toolchain). Run locally / in CI. |
| `dart format --set-exit-if-changed .` | Not run here. CI (`ci.yml`) runs it on every PR. |
| `flutter analyze` | Not run here. CI runs it on every PR. |
| `flutter test` | Not run here. CI runs it on every PR. |
| `flutter build apk --debug` | Not run here (no Android SDK). CI (`android-debug-apk.yml`) builds it on every PR. |
| `flutter build apk --release` | Not run here. The tag build (`android-release-build.yml`) produced the alpha.30 APK; re-confirm a clean from-source release build on a machine with the SDK. |
| `fdroid lint` / `fdroid build -l io.github.thezupzup.linthra` | Not run here (no fdroidserver). Run inside an fdroiddata checkout (§8). |

A note on that first row: a YAML parse isn't the same as F-Droid validation. The
real check is `fdroid lint` plus an actual `fdroid build` in an fdroiddata
checkout.

Commands to run locally and in an fdroiddata checkout:

```sh
# In the Linthra repo (pinned Flutter 3.27.4 — see scripts/setup_flutter.sh):
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --release    # reads versionName/versionCode from pubspec.yaml
# NOTE: at the pre-change v0.1.0-alpha.30 tag pubspec.yaml is still
# 0.1.0-alpha.15+15, so to reproduce that exact tag add (one-time, see §2):
#   --build-name=0.1.0-alpha.30 --build-number=100030 --dart-define=LINTHRA_VERSION_NAME=0.1.0-alpha.30

# In an fdroiddata checkout, once metadata/io.github.thezupzup.linthra.yml is in:
fdroid readmeta
fdroid lint io.github.thezupzup.linthra
fdroid build -v -l io.github.thezupzup.linthra        # full from-source build test
```

## 8. Steps to submit to fdroiddata

1. ✅ Screenshots committed (issue #77) — eight phone screenshots under
   `images/phoneScreenshots/` (see [listing-assets.md §6](./listing-assets.md)).
2. Re-confirm a clean `flutter build apk --release` from source on a machine with
   the Android SDK, and re-check the merged-manifest permission set.
3. Fork https://gitlab.com/fdroid/fdroiddata and make a branch.
4. Copy the non-comment content of `metadata/io.github.thezupzup.linthra.yml`
   into fdroiddata's `metadata/` directory. It deliberately has **no** inline
   `Summary`/`Description` — F-Droid pulls them from the Fastlane files (the
   fdroiddata maintainer's request on !39253). Then run `fdroid rewritemeta
   io.github.thezupzup.linthra` (it canonicalises the file and strips comments).
5. Run `fdroid lint io.github.thezupzup.linthra` and `fdroid build -v -l
   io.github.thezupzup.linthra` until green (§7). The draft uses the `flutter`
   srclib method (§3); if the native build needs an NDK/CMake, add it as noted
   there.
6. Open or update the merge request using fdroiddata's **"App inclusion"**
   merge-request template (§9) and check the boxes that apply. Be upfront that
   it's an early-alpha, pre-release submission, and that auto-update is enabled
   (pubspec.yaml tracks the tags) with a one-time explicit-flag entry for the
   pre-change `v0.1.0-alpha.30` tag (§2).
7. Don't describe Linthra as being on F-Droid until the merge request is merged
   and the build publishes.

## 9. Merge-request description — use fdroiddata's "App inclusion" template

Edit the existing merge request (!39253 — do **not** open a new one) and select
fdroiddata's **"App inclusion"** merge-request template, delete the instruction
lines it tells you to remove, then check the boxes that apply. A short intro plus
the filled checklist below works. The app's summary/description are **not**
restated here — F-Droid takes them from the Fastlane files (§6), which is what
the maintainer asked for.

---

Adds Linthra, an open-source, local-first Android music player for local files
and self-hosted servers (Jellyfin, Navidrome/Subsonic). Unofficial community
client — not affiliated with Jellyfin, Navidrome, or Subsonic. MPL-2.0; no ads,
tracking, analytics, crash-reporting SDK, or Google Play Services. Initial
target: `v0.1.0-alpha.30` (versionCode `100030`); the broken `v0.1.0-alpha.24`
is skipped. Early alpha, usable for testing.

### Required

- [x] The app complies with the [inclusion criteria](https://f-droid.org/docs/Inclusion_Policy)
- [x] The original app author has been notified (and does not oppose the inclusion) — I am the upstream author/maintainer.
- [ ] All related fdroiddata and RFP issues have been referenced — there is no existing RFP or fdroiddata issue.
- [ ] Builds with `fdroid build` and all pipelines pass — pending CI / `fdroid build -l`.
- [x] There is an issue tracker and contact info of the author — https://github.com/TheZupZup/Linthra/issues

### Strongly Recommended

- [x] The upstream repo contains the app metadata (summary/description/images/changelog) in a Fastlane structure — `fastlane/metadata/android/en-US/` (short_description, full_description, title, changelogs, icon, feature graphic, 8 screenshots). Summary/Description are intentionally **not** set in fdroiddata; F-Droid pulls them from Fastlane.
- [x] Releases are tagged and auto update is enabled — releases are tagged (`v0.1.0-alpha.30`), and auto-update is **enabled**: `AutoUpdateMode: Version`, `UpdateCheckMode: Tags`, and `UpdateCheckData` reading `versionName`/`versionCode` from `pubspec.yaml` (which now tracks the tags). The single seed `Builds` entry passes explicit `versionName`/`versionCode` only because the pre-change `v0.1.0-alpha.30` tag predates pubspec tracking; new tags build plainly (§2).

### Suggested

- [ ] External repos are added as git submodules instead of srclibs — this recipe uses the `flutter` srclib (per `templates/build-flutter.yml`); no Flutter submodule is added upstream.
- [ ] Enable Reproducible Builds — not enabled yet (early alpha); the APK is signed with F-Droid's key.
- [x] Multiple apks for native code — per-ABI APKs (armeabi-v7a / arm64-v8a / x86_64) via `flutter build apk --release --split-per-abi`, three `Builds` entries, and a `VercodeOperation` mirroring the `versionCodeOverride` in `android/app/build.gradle`. Added in response to maintainer feedback on MR !39329; the GitHub-Release CI keeps the universal APK for sideload.

No RFP or fdroiddata issue to close.

`/label ~"New App"`

---

## 10. GitHub issue draft — "Submit Linthra to F-Droid"

This is a draft body for a tracking issue in this repo. It isn't created
automatically — file it if/when it's useful. A readiness issue (#87) and a
screenshots issue (#77) already exist; this one would track the submission
itself. Suggested labels: `documentation`, `f-droid`.

**Title:** Submit Linthra to F-Droid

**Body:**

### Overview

Tracks the actual submission of Linthra to
[fdroiddata](https://gitlab.com/fdroid/fdroiddata). This isn't a claim that
Linthra is on F-Droid — it's the submission work itself. The readiness
groundwork is done (#87); this covers cutting the merge request.

The target is the latest alpha that launches, `v0.1.0-alpha.30` (versionCode
`100030`). The withdrawn, broken `v0.1.0-alpha.24` is skipped — alpha.25 was its
hotfix, and the target has since moved on to alpha.30.

### Checklist

- [x] Screenshots committed (#77) — eight phone screenshots under
      `images/phoneScreenshots/`.
- [ ] Re-confirm a clean from-source `flutter build apk --release` on a machine
      with the SDK; re-check the merged-manifest permissions.
- [ ] Decide the `pubspec.lock` policy for the tagged commit.
- [ ] Fork fdroiddata; copy in `metadata/io.github.thezupzup.linthra.yml`.
- [ ] Settle the Builds toolchain to fdroiddata's Flutter convention (srclib vs.
      sudo-clone).
- [ ] `fdroid readmeta` + `fdroid lint` + `fdroid build -l` all green.
- [ ] Open the merge request (text in `docs/fdroid-submission.md` §9); mention
      the early-alpha status and ask about tracking an `-alpha` tag.

### Open questions

- Whether F-Droid will track a pre-release `-alpha` CurrentVersion, or would
  rather wait for a stable tag — one to raise with the maintainers.
- The exact Flutter-on-F-Droid build setup, to be confirmed in an fdroiddata
  checkout.

### Links

- Metadata draft: `metadata/io.github.thezupzup.linthra.yml`
- Submission package: `docs/fdroid-submission.md`
- Readiness checklist: `docs/fdroid-readiness.md`
- Build recipe notes: `docs/fdroid-build-recipe.md`
- Dependency/license audit: `docs/dependency-license-audit.md`
- Listing assets: `docs/listing-assets.md`

### Status

The metadata, audit, permissions, anti-feature review, build recipe, screenshots,
and submission text are ready and point at `v0.1.0-alpha.30`. What's left before
the merge request: an SDK-machine release-build re-confirmation, and `fdroid lint`
/ `fdroid build` in an fdroiddata checkout.
