# F-Droid readiness checklist

This document tracks what Linthra needs before it can be submitted to
[F-Droid](https://f-droid.org/). It is a planning aid, not a claim of
availability.

> **Linthra is _not_ on F-Droid, and no submission has been made.** This
> checklist exists so that a future submission is straightforward and accurate.

## 1. Current status

- **Stage:** early development. Library v1 (folder selection, scanning,
  persisted listing) works end to end; playback, playlists, and offline
  downloads are still planned.
- **Distribution:** none yet. No tagged release, no published APK, no F-Droid
  metadata submission.
- **Groundwork in place:** stable application ID, MPL-2.0 license, and
  Fastlane-style store metadata under `fastlane/metadata/android/en-US/`
  (text only — no image assets yet).
- **Not ready to submit.** See [Remaining blockers](#8-remaining-blockers-before-submission).

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

## 3. Build requirements

Linthra is a Flutter (Dart) application targeting Android.

- **Flutter SDK:** stable channel; Dart SDK `>=3.6.0 <4.0.0` (see
  `pubspec.yaml` / `.metadata`).
- **Build command:** `flutter build apk --release` (or split-per-ABI / appbundle
  as appropriate).
- **Native components:** `sqlite3_flutter_libs` bundles a native SQLite engine;
  the F-Droid build must be able to fetch/build it reproducibly.
- **Code generation:** Drift `*.g.dart` files are generated via
  `build_runner`. The F-Droid build recipe must either include committed
  generated files or run `dart run build_runner build` as a prebuild step.
- **F-Droid build server constraint:** all dependencies must be free software
  and buildable from source on F-Droid's infrastructure (no proprietary SDKs,
  no Google/Firebase binaries, no prebuilt closed blobs).

## 4. Dependencies review

Runtime dependencies (from `pubspec.yaml`), all open source and commonly
accepted on F-Droid:

| Package                  | Purpose                                  | Notes |
| ------------------------ | ---------------------------------------- | ----- |
| `flutter_riverpod`       | State management                         | OK |
| `go_router`              | Navigation                               | OK |
| `path`                   | Cross-platform path parsing              | OK |
| `drift`                  | Typed SQLite query layer                 | OK (codegen) |
| `sqlite3_flutter_libs`   | Native SQLite engine                     | OK (native build) |
| `path_provider`          | Locates on-device DB file                | OK |
| `just_audio`             | Local audio playback engine              | OK |
| `audio_service`          | Background playback / media session      | OK |
| `file_picker`            | Native folder chooser                    | OK |
| `shared_preferences`     | Persists selected folder                 | OK |

Dev-only dependencies (`flutter_lints`, `flutter_test`, `drift_dev`,
`build_runner`) are not shipped in the APK.

**Action items:**
- Confirm no transitive dependency pulls in Google Play Services, Firebase, or
  other non-free components (run an audit before submission).
- Verify each plugin builds cleanly on the F-Droid build server (some Flutter
  plugins need specific recipe tweaks).

## 5. Anti-features review

F-Droid labels apps with [anti-features](https://f-droid.org/docs/Anti-Features/)
where applicable. Current assessment:

| Anti-feature              | Present? | Notes |
| ------------------------- | -------- | ----- |
| Ads                       | **No**   | No advertising of any kind. |
| Tracking / analytics      | **No**   | No telemetry, analytics, or crash reporting SDKs. |
| Non-free network services | **No**   | Local-first; no required remote services today. |
| Non-free dependencies     | No (TBC) | To be confirmed by the dependency audit above. |

> **Future caveat:** if optional online providers (e.g. metadata lookup or
> streaming sources) are added later, each must be reviewed individually and may
> warrant the `NonFreeNet` anti-feature. The local-first core must remain fully
> functional without them.

## 6. Release / tagging plan

F-Droid builds from a git tag. Plan:

1. Keep version in `pubspec.yaml` as the single source of truth
   (`version: x.y.z+<versionCode>`; currently `0.1.0+1`).
2. Tag releases as `vX.Y.Z` (annotated tag) on the commit to be built.
3. Each release bumps both `versionName` (`x.y.z`) and `versionCode` (the
   integer after `+`); `versionCode` must increase monotonically.
4. Add a matching changelog file at
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.
5. The F-Droid recipe should use `AutoUpdateMode`/`UpdateCheckMode` tied to tags
   so new tagged releases are picked up.

## 7. Metadata checklist

Stored under `fastlane/metadata/android/en-US/`:

- [x] `title.txt` — app name.
- [x] `short_description.txt` — one-line summary (under F-Droid's 80-char limit).
- [x] `full_description.txt` — long description (separates shipped vs. planned).
- [x] `changelogs/1.txt` — placeholder notes for `versionCode` 1.
- [ ] `images/icon.png` — 512×512 real Linthra store icon (the launcher icons
  under `android/app/src/main/res/mipmap-*` are still the default Flutter
  placeholder and must not be reused here).
- [ ] `images/featureGraphic.png` — 1024×500.
- [ ] `images/phoneScreenshots/*.png` — 2–8 real screenshots from a device.
- [ ] `images/sevenInchScreenshots/*.png` / `images/tenInchScreenshots/*.png` —
  optional tablet screenshots (only if the larger layout is worth showing).

No placeholder/mock images are committed on purpose; `images/` currently holds
only `NEEDED-ASSETS.txt` documenting the expected layout. Exact sizes and
step-by-step capture instructions live in
[docs/listing-assets.md](./listing-assets.md); see also F-Droid's
[descriptions, graphics & screenshots guide](https://f-droid.org/docs/All_About_Descriptions_Graphics_and_Screenshots/).

## 8. Remaining blockers before submission

1. **Release signing.** `android/app/build.gradle` still signs release builds
   with the debug key (`signingConfig = signingConfigs.debug`). F-Droid signs
   its own builds, but the project should remove the debug-key fallback / set up
   a proper release signing story before publishing.
2. **No image assets.** Icon, feature graphic, and screenshots are missing.
3. **Dependency audit.** Confirm no non-free / Google-only transitive deps.
4. **Reproducible build verification.** Confirm the app builds on F-Droid's
   build server, including Drift codegen as a prebuild step.
5. **No tagged release yet.** A `vX.Y.Z` tag must exist for F-Droid to build.
6. **Feature maturity (judgment call).** Decide whether to submit at the current
   early stage or wait until core playback ships.

## 9. Suggested order before F-Droid submission

1. Run the dependency audit (§4) and resolve any non-free findings.
2. Sort out release signing config (§8.1).
3. Verify a clean release build, including codegen (§3, §8.4).
4. Capture and commit real image assets (§7).
5. Finalize the version and cut a `vX.Y.Z` tag with a matching changelog (§6).
6. Prepare the F-Droid `metadata/<appid>.yml` build recipe and submit a merge
   request to [fdroiddata](https://gitlab.com/fdroid/fdroiddata).
