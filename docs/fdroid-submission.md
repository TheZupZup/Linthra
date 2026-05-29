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
| Source  | https://github.com/thezupzup/linthra |
| Issues  | https://github.com/thezupzup/linthra/issues |
| Category| Multimedia                    |

## 2. Target version: the latest working alpha

F-Droid builds from a git tag, and Linthra now has tags (`v0.1.0-alpha.1` …
`v0.1.0-alpha.29`, built by the Android Release Build workflow). The submission
targets the latest one that launches cleanly:

| Item            | Value                                   |
| --------------- | --------------------------------------- |
| Target tag      | `v0.1.0-alpha.29` (commit `ab0006b`)     |
| versionName     | `0.1.0-alpha.29`                        |
| versionCode     | `100029`                                |
| Changelog file  | `fastlane/metadata/android/en-US/changelogs/100029.txt` |

One thing to be careful about: don't target `v0.1.0-alpha.24`. Its GitHub
Release is marked "Broken release — do not install … startup regression," and
alpha.25 was the hotfix that reverted it. The target here is the latest working
alpha, `v0.1.0-alpha.29`, so the recipe's `commit:` and the
`CurrentVersion`/`CurrentVersionCode` all point at alpha.29.

### Why versionCode `100029` and not `15`

`pubspec.yaml` keeps a fixed dev version, `0.1.0-alpha.15+15`, that's the same at
every tagged commit (the release workflow overrides it per release, so it never
gets bumped). That has two consequences:

- A plain `flutter build apk` at any tag produces versionName `0.1.0-alpha.15`
  and versionCode `15`. Every F-Droid build would then look like the same
  version, which F-Droid can't work with — so this is a real blocker, not a
  detail.
- The upstream GitHub release build avoids that by deriving the version from the
  tag with `tool/version_from_tag.dart` (the single source of truth):
  `v0.1.0-alpha.29` → `0.1.0-alpha.29` / `100029`.

So the F-Droid recipe does the same thing — it derives the version from the
checked-out tag and passes `--build-name`/`--build-number`. The APK then reports
`0.1.0-alpha.29` / `100029`, matching the metadata and the GitHub build. That
keeps each tag's versionCode distinct and increasing, keeps the F-Droid and
GitHub codes identical for the same tag, and stays correct under `AutoUpdateMode`
for future tags (since the version isn't hard-coded). The changelog file is
named by that derived code (`100029.txt`), in line with
[release-process.md §1](./release-process.md#1-versioning-model) (the older
`1.txt`/`9.txt`/`15.txt` stay as they are).

There's a cleaner long-term option — bump `pubspec.yaml` to the tag version at
each tagged commit, so a plain build is correct and the recipe needs no flags —
but that changes the release process, so it's out of scope here. The
derive-from-tag approach works for this submission without touching anything.

## 3. Build recipe status

The draft recipe is in
[`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml).
What makes it a good fit for building from source:

- It builds with no signing keys — F-Droid signs its own builds. Linthra's
  optional release signing only applies to the GitHub channel and is injected at
  build time (see [release-signing.md](./release-signing.md)); no keystore or
  secret is committed.
- The toolchain is pinned: Flutter `3.27.4` (stable), Dart `3.6.x`, JDK 17,
  Gradle 8.3 — the same versions as `.flutter-version` and CI.
- No codegen step: the Drift output
  `lib/data/database/linthra_database.g.dart` is committed, so there's no
  `build_runner` to run.
- One native component, SQLite via `sqlite3_flutter_libs`, built from source
  (public domain). No prebuilt closed blobs, and no Google Play Services or
  Firebase anywhere in the resolved tree (152 packages, all audited).
- No GitHub Actions secrets or Play signing are involved in the from-source
  build.

A few things still need checking against fdroiddata before submitting:

1. How Flutter gets provisioned. The draft clones `flutter/flutter` at the
   `3.27.4` tag in a `sudo:` step; fdroiddata may prefer its `flutter` srclib
   (`srclibs: [flutter@3.27.4]`, referenced as `$$flutter$$`). Either is fine —
   match the current convention. Flutter's engine artifacts are fetched at the
   pinned version, which is normal for Flutter on F-Droid and stays pinned and
   reproducible.
2. The `git describe --tags --exact-match HEAD` the build uses to find the tag —
   confirm F-Droid's checkout of `commit: v0.1.0-alpha.29` leaves the tag
   resolvable (it should, since F-Droid checks out the tag ref).
3. The output path. `build/app/outputs/flutter-apk/app-release.apk` is the
   single-APK output; adjust `output:` if you'd rather split per ABI.
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
| Metadata YAML parses (PyYAML) | Done here — valid YAML, fields and types as expected (Summary 57 chars, versionCode an integer, `100029`). This only checks the YAML, not F-Droid's schema (see below). |
| `flutter pub get` | Not run here (no toolchain). Run locally / in CI. |
| `dart format --set-exit-if-changed .` | Not run here. CI (`ci.yml`) runs it on every PR. |
| `flutter analyze` | Not run here. CI runs it on every PR. |
| `flutter test` | Not run here. CI runs it on every PR. |
| `flutter build apk --debug` | Not run here (no Android SDK). CI (`android-debug-apk.yml`) builds it on every PR. |
| `flutter build apk --release` | Not run here. The tag build (`android-release-build.yml`) produced the alpha.29 APK; re-confirm a clean from-source release build on a machine with the SDK. |
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
flutter build apk --release \
  --build-name=0.1.0-alpha.29 --build-number=100029   # what the recipe derives

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
4. Copy `metadata/io.github.thezupzup.linthra.yml` into fdroiddata's `metadata/`
   directory. In the real entry you'd normally drop the inline `Summary`/
   `Description` and let the Fastlane files provide them, unless you specifically
   want to override them.
5. Settle the Builds toolchain to fdroiddata's current Flutter convention
   (srclib vs. sudo-clone — §3), and run `fdroid lint` + `fdroid build -l` until
   they're green (§7).
6. Open the merge request using the text in §9. Be upfront that it's an
   early-alpha, pre-release submission, and ask the maintainers whether they're
   happy tracking an `-alpha` tag or would rather wait for a stable one.
7. Don't describe Linthra as being on F-Droid until the merge request is merged
   and the build publishes.

## 9. Merge-request description (ready to adapt)

Paste this into the fdroiddata merge request and adjust as needed.

---

**New app: Linthra — `io.github.thezupzup.linthra`**

Linthra is an open-source Android music player for people who keep their music on
their own devices or self-hosted servers. It plays local files and streams from
self-hosted servers such as Jellyfin and Navidrome/Subsonic. It's an unofficial
community client — not affiliated with Jellyfin, Navidrome, or Subsonic.

Why I think it's a good fit for F-Droid:

- **License:** MPL-2.0 (FSF/OSI-approved), in `LICENSE`.
- **Builds from source** with no signing keys — F-Droid signs its own builds.
- **No proprietary dependencies.** I audited the full transitive tree (152
  packages) and found only permissive licenses (BSD/MIT/Apache-2.0/MPL-2.0) and
  no Google Play Services, Firebase, analytics, ads, or crash-reporting. The one
  native component is SQLite (public domain, built from source); playback is
  AndroidX Media3 (Apache-2.0); casting is a pure-Dart implementation, not the
  GMS Cast SDK.
- **No anti-features.** No ads, no tracking, nothing phones home. The self-hosted
  sources are optional servers the user runs themselves, so I don't think
  `NonFreeNet` applies — happy to add it if you read it differently.
- **Minimal permissions.** No storage, location, contacts, camera, mic, or phone
  permission, and no `MANAGE_EXTERNAL_STORAGE` — folder access uses the Storage
  Access Framework.

Source and issues: https://github.com/thezupzup/linthra (issues at `/issues`).

**Build target:** tag `v0.1.0-alpha.29`, versionName `0.1.0-alpha.29`,
versionCode `100029`. The build derives the version from the tag (using the
project's `tool/version_from_tag.dart`), so the versionCode is distinct and
increasing per release and matches the upstream GitHub-release APK. (For context:
`v0.1.0-alpha.24` was a broken release that was withdrawn; alpha.25 was the
hotfix, and alpha.29 is the current working build.)

**On status — being honest about scope:** this is early-alpha, pre-release
software. It's usable for testing on a real device, but it isn't
production-stable and has some documented rough edges, and right now it's only
distributed as a sideloaded APK from GitHub Releases. I'd welcome your guidance
on whether you'd prefer to track this `-alpha` tag now or wait for a first stable
(`vX.Y.Z`) release.

**Build verification:** `flutter analyze`, `flutter test`, and formatting run
green in CI on every PR, and CI builds a debug APK per PR; the tagged release APK
builds via the release workflow. I'll also run `fdroid lint` and `fdroid build
-l` and confirm a clean from-source `flutter build apk --release`.

**Known limitations:** it's early alpha; local files show file names until tag
parsing lands; one Jellyfin server at a time; some Subsonic features (favourites,
lyrics, cover art) are still follow-ups.

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

The target is the latest alpha that launches, `v0.1.0-alpha.29` (versionCode
`100029`). The withdrawn, broken `v0.1.0-alpha.24` is skipped — alpha.25 was its
hotfix, and the target has since moved on to alpha.29.

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
and submission text are ready and point at `v0.1.0-alpha.29`. What's left before
the merge request: an SDK-machine release-build re-confirmation, and `fdroid lint`
/ `fdroid build` in an fdroiddata checkout.
