# F-Droid readiness checklist

This document tracks what Linthra needs before it can be submitted to
[F-Droid](https://f-droid.org/). It is a planning aid, not a claim of
availability.

> Linthra isn't on F-Droid, and nothing has been submitted yet. This checklist is
> here so that when we do submit, it's accurate and goes smoothly.

## 1. Current status

- **Stage:** early alpha, usable for testing on a real device. Working today:
  local-folder library (SAF scan and browse), streaming from Jellyfin and
  Navidrome/Subsonic, a smart offline cache, queue, playlists and favourites,
  smart mixes, background playback (media notification / lock screen /
  Bluetooth), Android Auto, and Cast (pure-Dart, no Google Play Services). It
  isn't production-stable, and the rough edges are documented.
- **Distribution:** GitHub Releases only, as a sideloaded APK (Obtainium works
  too). No F-Droid metadata has been submitted, and Linthra isn't on F-Droid.
- **Tagged releases now exist:** `v0.1.0-alpha.1` … `v0.1.0-alpha.29`, each built
  by `.github/workflows/android-release-build.yml`. The F-Droid target is the
  latest one that launches, `v0.1.0-alpha.29` (versionName `0.1.0-alpha.29`,
  tag-derived versionCode `100029`). Skip `v0.1.0-alpha.24`: its GitHub Release
  is marked "Broken release — do not install … startup regression"; alpha.25 was
  the hotfix that reverted it, and the target has since moved on to alpha.29.
- **Groundwork in place:** a stable application ID, the MPL-2.0 license, a real
  app/launcher icon, Fastlane-style store metadata under
  `fastlane/metadata/android/en-US/` (text plus the real icon, feature graphic,
  and eight real phone screenshots), a finished dependency/license audit, the
  draft recipe at [`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml)
  (pinned to `v0.1.0-alpha.29`), and the submission package at
  [`docs/fdroid-submission.md`](./fdroid-submission.md).
- **Not submitted yet.** See [Remaining blockers](#8-remaining-blockers-before-submission).

## 2. App identity

| Field    | Value                            |
| -------- | -------------------------------- |
| Name     | Linthra                          |
| App ID   | `io.github.thezupzup.linthra`    |
| License  | MPL-2.0                          |

- App ID is set as both the Android `namespace` and `applicationId` in
  `android/app/build.gradle` and must remain stable across releases.
- License is declared in [`LICENSE`](../LICENSE) (Mozilla Public License 2.0),
  an [FSF/OSI-approved free license](https://www.gnu.org/licenses/license-list.html)
  accepted by F-Droid.

## 3. Build-from-source requirements

Linthra is a Flutter (Dart) application targeting Android. The toolchain is
pinned and matches CI (`.github/workflows/ci.yml`, `android-debug-apk.yml`).

| Question | Answer |
| -------- | ------ |
| **Flutter version required?** | **3.27.4**, `stable` channel — pinned in [`.flutter-version`](../.flutter-version) and both CI workflows. `scripts/setup_flutter.sh` installs exactly this version locally. |
| **Dart SDK?** | `>=3.6.0 <4.0.0` (`pubspec.yaml`); satisfied by Flutter 3.27.4 (Dart 3.6.2). |
| **JDK / Gradle?** | JDK 21 (Temurin in CI), Gradle 8.7, Android Gradle Plugin 8.2.1, Kotlin 1.9.24. |
| **Android SDK required?** | **Yes.** A standard Android SDK (`platform-tools`, `platforms;android-35`, `build-tools;35.0.0`) plus the NDK + CMake are needed to compile the one native component (SQLite, below). `compileSdk`/`minSdk`/`targetSdk` come from Flutter, not hard-coded. |
| **Signing keys required to build?** | **No.** A from-source build needs no signing material; F-Droid signs its own builds. Linthra's release signing is optional and supplied at build time via env vars / `android/key.properties`, falling back to the debug key when absent (see [release-signing.md](./release-signing.md)). No keystore or secret is committed. |
| **Build commands** | `flutter pub get` then `flutter build apk --release` (or `--debug`; split-per-ABI is fine — appbundle is for Play, not F-Droid). |
| **Generated files: committed or generated?** | **Committed.** The Drift output `lib/data/database/linthra_database.g.dart` is committed, so **no `build_runner`/codegen prebuild step is required** for the F-Droid build. It must be kept in sync with the schema on the tagged commit (regenerate with the `generate-drift.yml` workflow or `dart run build_runner build`). |
| **How version tags work** | A `v*` git tag is the source of truth; `tool/version_from_tag.dart` derives `versionName`/`versionCode` for GitHub-Release builds. F-Droid builds from source and runs a plain `flutter build`, which takes the version from `pubspec.yaml` — see §6 for the reconciliation caveat. |
| **Native components** | Only SQLite, via `sqlite3_flutter_libs` — compiled **from source** (the SQLite amalgamation is public domain) using the NDK + CMake; no prebuilt closed blob. The playback engine is AndroidX Media3 (Apache-2.0 Maven AAR), not GMS. |
| **F-Droid build-server constraint** | All dependencies must be free software and buildable from source (no proprietary SDKs, no Google/Firebase binaries, no prebuilt closed blobs). The dependency/license audit confirms this for the full resolved tree — see §4. |

**Repository & build hygiene** (audited for this pass):

- **No proprietary binary blobs committed.** The only committed binaries are PNG
  image assets (launcher icons under `android/app/src/main/res/mipmap-*` and the
  store `icon.png`/`featureGraphic.png`), all generated deterministically from
  the committed source SVG via `tool/branding/generate_icons.py` (regenerate with
  `python3 tool/branding/generate_icons.py`). No `.so`/`.jar`/`.aar`/`.keystore`
  or other closed binary is tracked.
- **No secrets or API keys committed.** No keystore, token, password, or API key
  is in the repository; release signing material is git-ignored and injected at
  build time only (see [release-signing.md](./release-signing.md)).
- **No build step needs private credentials.** Building from source is
  `flutter pub get` + `flutter build apk` — the CI debug-APK build runs with
  read-only repo access and no secrets (`android-debug-apk.yml`).

## 4. Dependencies review

Runtime dependencies (from `pubspec.yaml`), all open source and commonly
accepted on F-Droid:

| Package                  | Purpose                                  | License | Notes |
| ------------------------ | ---------------------------------------- | ------- | ----- |
| `flutter_riverpod`       | State management                         | MIT | OK |
| `go_router`              | Navigation                               | BSD-3-Clause | OK |
| `path`                   | Cross-platform path parsing              | BSD-3-Clause | OK |
| `drift`                  | Typed SQLite query layer                 | MIT | OK (codegen) |
| `sqlite3_flutter_libs`   | Native SQLite engine                     | MIT | OK (native build; SQLite is public domain) |
| `path_provider`          | Locates on-device DB file                | BSD-3-Clause | OK |
| `just_audio`             | Local audio playback engine              | MIT | OK |
| `audio_service`          | Background playback / media session      | MIT | OK |
| `file_picker`            | Native folder chooser                    | MIT | OK |
| `shared_preferences`     | Persists selected folder                 | BSD-3-Clause | OK |
| `http`                   | HTTP client for the optional self-hosted sources | BSD-3-Clause | OK (network is opt-in; see §5) |
| `crypto`                 | MD5 for the Subsonic/Navidrome token auth | BSD-3-Clause | OK (Dart-team package; hashing only) |
| `flutter_secure_storage` | Encrypted Jellyfin/Subsonic session-token store | BSD-3-Clause | OK (Android Keystore; AOSP, not GMS) |
| `cast`                   | Real Chromecast (pure-Dart Cast v2 protocol) | MIT | OK — **no** GMS / Google Cast SDK; see [audit §5 (Casting)](./dependency-license-audit.md#casting-chromecast--real-cast-without-google-play-services) |
| `bonsoir`                | mDNS discovery used by `cast`            | MIT | OK — Android side is AOSP `NsdManager`, not GMS; pinned to 5.x for Dart 3.6 |
| `url_launcher`           | Opens the browser for "Report a bug" → "Open GitHub issue" | BSD-3-Clause | OK — official Flutter plugin; AOSP `ACTION_VIEW` intent, no GMS; fired only on an explicit user tap. See [audit §7 (Reporting a bug)](./dependency-license-audit.md#reporting-a-bug-browser-hand-off-no-auto-send) |

Dev-only dependencies (`flutter_lints`, `flutter_test`, `drift_dev`,
`build_runner`) are not shipped in the APK.

The full per-package license breakdown, the native/bundled-component review, and
the methodology live in [docs/dependency-license-audit.md](./dependency-license-audit.md).
All direct dependencies are permissive (MIT / BSD-3-Clause) and MPL-2.0
compatible.

**Transitive audit — done.** The full resolved tree was walked with the pinned
toolchain (`flutter pub get` + `flutter pub deps`): **152 packages**, every one a
permissive free-software license (101 BSD-3-Clause, 34 MIT, 6 Apache-2.0,
6 BSD-2-Clause, 2 MPL-2.0), with **no Google Play Services / Firebase / analytics
/ ads / crash-reporting package anywhere** in the tree. The only native AAR is
AndroidX Media3 (Apache-2.0, the playback engine — not GMS). Full results and
methodology in [dependency-license-audit.md §2 & §5](./dependency-license-audit.md#2-how-this-audit-was-produced-and-its-limits).

**Action items:**
- Verify each plugin builds cleanly on the F-Droid build server (some Flutter
  plugins need specific recipe tweaks); confirm the NDK/CMake native build of
  `sqlite3_flutter_libs` works there.
- Decide the `pubspec.lock` policy (still git-ignored) so the audited set is
  pinned at the tagged commit (see [build-recipe §4](./fdroid-build-recipe.md#4-reproducibility-notes)).

## 5. Anti-features review

F-Droid labels apps with [anti-features](https://f-droid.org/docs/Anti-Features/)
where applicable. Current assessment:

| Anti-feature (F-Droid flag) | Apply? | Reasoning |
| --------------------------- | ------ | --------- |
| `Ads`              | **No** | No advertising libraries or code of any kind; no ad SDK in the resolved tree (§4). |
| `Tracking`         | **No** | No telemetry, analytics, or crash-reporting SDK. Play history, smart-mix signals, and the "Report a bug" breadcrumb buffer all stay on-device; nothing is auto-sent. Confirmed by the transitive audit (no analytics/crash package). |
| `NonFreeAdd`       | **No** | The app promotes/installs no non-free add-ons. |
| `NonFreeDep`       | **No** | Every resolved dependency is permissive free software (§4 transitive audit); the playback AAR is AndroidX Media3 (Apache-2.0), and Cast is the pure-Dart `cast` package — **not** the GMS Cast SDK. |
| `NonFreeNet`       | **No** (see note) | The local-first core needs no network. The optional Jellyfin / Navidrome / Subsonic sources are user-supplied and point at free-software servers the user hosts — not a mandatory or promoted proprietary service. |
| `UpstreamNonFree`  | **No** | The upstream project (this repo) is entirely MPL-2.0 free software; no non-free build inputs or assets (icons are generated from a committed SVG — §7). |
| `KnownVuln`        | **No (as of this audit)** | No dependency in the resolved tree is a known-vulnerable version at audit time; re-check on dependency bumps. F-Droid's own scanner will flag any `KnownVuln` at submission. |
| `NoSourceSince`    | **No** | Source is fully published and builds are from source. |

> **Optional self-hosted sources (`NonFreeNet` reasoning).** Linthra can stream
> from a user's own **Jellyfin** or **Navidrome / Subsonic** server (server
> settings, sign-in, encrypted session token, a library source behind an
> interface). These are **optional and entirely user-configured** — no server is
> bundled, promoted, defaulted-to, or required, and the local-first core works
> with no network at all. Jellyfin, Navidrome, and the Subsonic API ecosystem are
> themselves free/open-source, and Linthra only speaks plain HTTP(S) to them. So
> the optional remote sources do **not** warrant the `NonFreeNet` anti-feature.
> Reviewed in detail in
> [dependency-license-audit.md §7](./dependency-license-audit.md#7-network-use--the-optional-self-hosted-sources).
>
> **Future caveat:** any further online provider must be reviewed individually
> and may warrant `NonFreeNet` if it defaults to or promotes a non-free hosted
> service. The local-first core must remain fully functional without any remote
> source.

### Android permissions

Every permission Linthra ships is justified below. Six are declared explicitly
in [`android/app/src/main/AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml)
(each with an inline comment); `ACCESS_NETWORK_STATE` is contributed by a
dependency's bundled manifest at merge time. The set is deliberately minimal:
**no storage, location, contacts, camera, microphone, or phone permission**, and
crucially **no broad-storage `MANAGE_EXTERNAL_STORAGE`**.

| Permission | Source | Why it is needed |
| ---------- | ------ | ---------------- |
| `INTERNET` | App manifest (also `bonsoir`, Media3, others) | Reach the user's self-hosted Jellyfin/Navidrome/Subsonic server (connection test, sign-in, sync, streaming) and carry the Cast session to a device on the LAN. The local-first core works without it. |
| `ACCESS_NETWORK_STATE` | Merged from AndroidX **Media3** (`just_audio`'s playback engine) | Lets the player read connectivity *state* (e.g. for adaptive streaming / recovery). It grants **no** network access of its own and is a standard AOSP/AndroidX permission. Not declared by Linthra directly. |
| `FOREGROUND_SERVICE` | App manifest (also `audio_service`) | Run the `audio_service` playback service in the foreground so audio keeps playing when the app is backgrounded. |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | App manifest | The typed foreground-service grant required on Android 14+ (API 34) for a service of type `mediaPlayback`; without it the playback service cannot start on new devices. |
| `POST_NOTIFICATIONS` | App manifest | Android 13+ (API 33) runtime permission for the media notification and its lock-screen/transport controls to appear; requested once on first launch. Playback still works if denied, just without the notification. |
| `WAKE_LOCK` | App manifest (also `audio_service` / Media3) | Keep the CPU (and, via the foreground media service, the Wi-Fi radio) awake while audio plays so playback and streaming survive the screen turning off. Held only while the service reports `playing`. |
| `CHANGE_WIFI_MULTICAST_STATE` | App manifest (merged from `bonsoir_android`) | Receive multicast Wi-Fi packets for mDNS (`_googlecast._tcp`) Chromecast discovery. An **AOSP** permission (Android `NsdManager`) for local-network discovery only — no internet or storage access. Cast uses **no** Google Play Services / Cast SDK. |
| _storage_ | — (none) | **No storage permission is declared.** Folder selection uses the Storage Access Framework (`ACTION_OPEN_DOCUMENT_TREE` via `file_picker`), which needs none. |

> **Verification note.** The six explicit permissions are read directly from the
> committed manifest. `ACCESS_NETWORK_STATE` is contributed by the Media3 AAR at
> Gradle manifest-merge time; the exact merged set should be re-confirmed against
> the merged manifest of a release build (`flutter build apk --release`) at
> submission time — this preparation pass could not run the Android build locally
> (see [§11 Verification](#11-verification-status) and
> §8.2). No permission is requested speculatively in code.

- **`MANAGE_EXTERNAL_STORAGE` is intentionally not used.** It is an "all files
  access" permission Google restricts and F-Droid users distrust; it is the
  opposite of the scoped-storage approach this project prefers. It must not be
  added without an explicit, documented justification.
- **Known SAF limitation:** a SAF folder is resolved to a filesystem path and
  walked with `dart:io`. On Android 11+ that path is frequently unreadable under
  scoped storage; the scanner surfaces a clear in-app error in that case
  (`DirectoryReadability` probe + `FolderScanException`) rather than a silent
  empty library. Lifting the restriction needs content-resolver SAF traversal (a
  native plugin); a narrow `READ_MEDIA_AUDIO` request is a separate future
  option. Neither is requested today.

## 6. Release / tagging plan

F-Droid builds from a git tag. Summary (the canonical, step-by-step process —
including the GitHub-Release flow — is in
[docs/release-process.md](./release-process.md)):

1. The **git tag** is the source of truth for a release's version; the build
   derives `versionName`/`versionCode` from it (see
   [release-process.md §1](./release-process.md#1-versioning-model)).
   `pubspec.yaml` only sets the version for local/dev builds.
2. Tag releases as `vX.Y.Z[-suffix]` (annotated tag) on the commit to be built.
3. `versionCode` is derived to be **strictly monotonic** automatically (encoded
   from the version); never reuse or decrease it.
4. Add a matching changelog file at
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`, named by the
   **derived** code (e.g. `100016.txt` for `v0.1.0-alpha.16`).
5. The F-Droid recipe should use `AutoUpdateMode`/`UpdateCheckMode` tied to tags
   so new tagged releases are picked up.

> **How the F-Droid build gets the right version.** F-Droid builds from source at
> the tag and doesn't run our release workflow, so a plain `flutter build` there
> would read the version from `pubspec.yaml` (`0.1.0-alpha.15+15`) and label every
> tag as versionCode 15 — which F-Droid can't tell apart. The draft recipe avoids
> that by deriving the version from the checked-out tag with
> `tool/version_from_tag.dart` and passing `--build-name`/`--build-number`, so
> `v0.1.0-alpha.29` builds to `0.1.0-alpha.29` / `100029` — the same value the
> GitHub release build uses, distinct and increasing per tag, and still correct
> under `AutoUpdateMode` for future tags. (Bumping `pubspec.yaml` at each tagged
> commit would also work and is cleaner long-term, but it changes the release
> process; see [docs/fdroid-submission.md §2](./fdroid-submission.md).)

## 7. Metadata checklist

Stored under `fastlane/metadata/android/en-US/`:

- [x] `title.txt` — app name.
- [x] `short_description.txt` — one-line summary (under F-Droid's 80-char limit).
- [x] `full_description.txt` — long description. **Refreshed** to match the
  current alpha (shipped features no longer listed as "planned") and now carries
  the "unofficial / not affiliated" framing. F-Droid uses this as the listing
  Description.
- [x] `changelogs/1.txt`, `9.txt`, `15.txt` — legacy per-version notes (named by
  the old hand-numbered `versionCode`); kept as-is.
- [x] `changelogs/100025.txt` — notes for the earlier alpha.25 target, named by
  its derived versionCode `100025`; kept as history now that the target has moved
  on to alpha.29.
- [x] `changelogs/100029.txt` — notes for the current F-Droid target
  `v0.1.0-alpha.29`, named by the **derived** versionCode `100029` (the
  convention going forward — see
  [release-process.md §1](./release-process.md#1-versioning-model)). Keep new
  changelog filenames in lockstep with the built APK's derived `versionCode`.
- [x] `images/icon.png` — 512×512 real Linthra store icon. The launcher icons
  under `android/app/src/main/res/mipmap-*` are now the same real mark (adaptive
  + legacy), generated from `tool/branding/` — no longer the default Flutter
  placeholder.
- [x] `images/featureGraphic.png` — 1024×500, the Linthra brand banner.
- [x] `images/phoneScreenshots/*.png` — eight real phone screenshots from a
  running build (see [docs/listing-assets.md §6](./listing-assets.md)).
- [ ] `images/sevenInchScreenshots/*.png` / `images/tenInchScreenshots/*.png` —
  optional tablet screenshots (only if the larger layout is worth showing).

The icon and feature graphic are committed (generated deterministically from
`tool/branding/linthra_icon.svg`), and eight real phone screenshots — captured
from a running build, not mocked — are committed under `images/phoneScreenshots/`.
What each one shows, plus the privacy review and the still-optional extras, is in
[docs/listing-assets.md §6](./listing-assets.md); see also F-Droid's
[descriptions, graphics & screenshots guide](https://f-droid.org/docs/All_About_Descriptions_Graphics_and_Screenshots/).

## 8. Remaining blockers before submission

1. **Reproducible build verification.** CI runs `dart format`, `flutter analyze`,
   and `flutter test` green on every PR (`ci.yml`) and builds a debug APK per PR
   (`android-debug-apk.yml`, JDK 21 + Flutter 3.27.4); the tagged release APK is
   built by `android-release-build.yml`. This preparation pass could only
   validate the **metadata YAML** (no Flutter/Android SDK / fdroidserver in the
   environment). Before submitting, re-confirm a clean from-source
   `flutter build apk --release` (incl. the NDK/CMake native build of
   `sqlite3_flutter_libs`) on an SDK-equipped machine, and run `fdroid lint` +
   `fdroid build -l` in an fdroiddata checkout (commands in
   [docs/fdroid-submission.md §7](./fdroid-submission.md)).
2. **Toolchain provisioning in the recipe** must be matched to fdroiddata's
   current Flutter convention (sudo git-clone vs. the `flutter` srclib) and
   validated by an actual `fdroid build` — see
   [docs/fdroid-submission.md §3](./fdroid-submission.md) and
   [fdroid-build-recipe.md](./fdroid-build-recipe.md).
3. **Feature maturity / pre-release tag (judgment call).** Decide whether to
   submit at the current early-alpha stage or wait for a stable (non-pre-release)
   tag — and confirm whether F-Droid will track/suggest an `-alpha`
   CurrentVersion at all.
4. **Release signing (GitHub channel only).** Not an F-Droid blocker (F-Droid
   signs its own builds), but the debug-key fallback should be replaced with real
   release signing for GitHub-Release artifacts (see
   [docs/release-signing.md](./release-signing.md)).
5. **`pubspec.lock` policy** for reproducibility — still git-ignored; decide
   whether to commit it at the tagged commit (§4 action items).

**Resolved since the previous passes:**

- **Screenshots landed.** Eight real phone screenshots, captured from a running
  build (not mocked), are committed under `images/phoneScreenshots/` — the core
  set tracked by **issue #77**. What each shows and the privacy review are in
  [docs/listing-assets.md §6](./listing-assets.md). Optional extras
  (Downloads-with-tracks, Android Auto, Cast, tablet) remain nice-to-haves, not
  blockers.
- **A tagged release now exists.** `v0.1.0-alpha.29` is the latest **working**
  alpha and is the recipe's `commit:`. The withdrawn, broken `v0.1.0-alpha.24` is
  explicitly **not** targeted.
- **versionCode reconciliation decided.** The recipe derives the version from the
  tag (→ `0.1.0-alpha.29` / `100029`), matching the GitHub channel and staying
  monotonic/AutoUpdate-safe (§6).
- **Fastlane description refreshed** to match the current alpha, with the
  "unofficial / not affiliated" framing (§7).
- Full transitive dependency/license audit complete (§4 — 152 packages, all
  permissive, no GMS); Drift generated files committed so no codegen prebuild is
  needed; full permission set documented (§5).

## 9. Submission checklist (suggested order)

The full step-by-step submission flow and the ready-to-adapt MR text live in
[docs/fdroid-submission.md](./fdroid-submission.md). Summary:

1. ✅ **Dependency/license audit** — done (§4;
   [audit doc](./dependency-license-audit.md)). Re-run on any dependency change.
2. ✅ **Fastlane `full_description.txt` refreshed** to match the current alpha,
   with the "unofficial / not affiliated" framing (§7).
3. ✅ **Target tag + versionCode decided** — `v0.1.0-alpha.29` / `100029`, with a
   matching `changelogs/100029.txt`; the recipe derives the version from the tag
   (§6). The broken `v0.1.0-alpha.24` is excluded.
4. ✅ **Screenshots committed** — eight real phone screenshots under
   `images/phoneScreenshots/` (§7; see [docs/listing-assets.md §6](./listing-assets.md);
   the core set for #77). Optional extras (Downloads-with-tracks, Android Auto,
   Cast, tablet) remain.
5. **Verify a clean `flutter build apk --release`** on a machine with the Android
   SDK + NDK (the from-source path F-Droid uses), and re-confirm the merged
   manifest permission set (§5 verification note).
6. **Finalize the recipe** from the draft
   [`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml)
   (match fdroiddata's Flutter convention, run `fdroid lint`/`fdroid build -l`),
   then submit a merge request to
   [fdroiddata](https://gitlab.com/fdroid/fdroiddata) using the text in
   [docs/fdroid-submission.md §9](./fdroid-submission.md).

The metadata field reference, build-source/toolchain expectations, and
reproducibility notes are in
[docs/fdroid-build-recipe.md](./fdroid-build-recipe.md); a runnable draft recipe
now lives at
[`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml).

## 10. Manual test checklist before submission

F-Droid builds and signs the APK itself, so the build it ships is **not** the one
tested during development. Before (and after) submission, smoke-test a
**release** build from the tagged commit on a real device using the full
[docs/manual-test-checklist.md](./manual-test-checklist.md). The F-Droid-specific
must-pass items:

- [ ] App installs and launches from a clean `flutter build apk --release`
      (no debug key, no dev tooling).
- [ ] Local-folder library: pick a folder (SAF), scan, browse, and play — with
      **no** storage permission prompt.
- [ ] Self-hosted source: add a Jellyfin and a Navidrome/Subsonic server, sign
      in, sync, and stream over HTTPS.
- [ ] Background playback: media notification + lock-screen controls appear
      (grant `POST_NOTIFICATIONS`) and survive backgrounding.
- [ ] Cast discovery finds a device on the LAN (multicast permission works) and
      playback hands off — confirming the pure-Dart Cast path needs no GMS.
- [ ] Android Auto lists the app and loads the browse tree (DHU or head unit).
- [ ] No crash/telemetry network traffic at rest (verify with a network monitor:
      nothing leaves the device unless the user configures a server).

## 11. Verification status

**This submission-prep pass had no Flutter/Dart/Android SDK and no fdroidserver
in the environment**, so it validated only the metadata YAML. The Flutter checks
below run **green in CI on every PR** (`ci.yml`) and were green in the earlier
readiness pass with the pinned toolchain (Flutter 3.27.4 / Dart 3.6.2); they are
**not** re-asserted as run here.

| Check | Result |
| ----- | ------ |
| Metadata YAML parses (PyYAML) | ✅ this pass — valid YAML; fields/types as expected (Summary 57 ≤ 80 chars; versionCode integer `100029`). Not a full `fdroid lint`. |
| `dart format` / `flutter analyze` / `flutter test` | ✅ green in CI (`ci.yml`) on every PR. Not re-run in this pass (no toolchain). |
| transitive license audit | ✅ all permissive, no GMS (§4). |
| `flutter build apk --debug` | ✅ built by CI per PR (`android-debug-apk.yml`). |
| `flutter build apk --release` (from source) | ⏳ re-confirm on an SDK-equipped machine before submitting (§8.2). The tagged release APK is built by `android-release-build.yml`. |
| `fdroid lint` / `fdroid build -l` | ⏳ run in an fdroiddata checkout (commands in [docs/fdroid-submission.md §7](./fdroid-submission.md)). |
