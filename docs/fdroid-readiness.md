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
| `http`                   | HTTP client for the optional Jellyfin source | BSD-3-Clause | OK (network is opt-in; see §5) |
| `flutter_secure_storage` | Encrypted Jellyfin session-token store   | BSD-3-Clause | OK (Android Keystore; AOSP, not GMS) |

Dev-only dependencies (`flutter_lints`, `flutter_test`, `drift_dev`,
`build_runner`) are not shipped in the APK.

The full per-package license breakdown, the native/bundled-component review, and
the methodology live in [docs/dependency-license-audit.md](./dependency-license-audit.md).
All direct dependencies are permissive (MIT / BSD-3-Clause) and MPL-2.0
compatible.

**Action items:**
- **Mechanical transitive audit still pending.** The direct-dependency license
  review is done (audit doc above); a tool-driven walk of the full transitive
  tree (`flutter pub deps`, license collector) confirming no Google Play
  Services / Firebase / proprietary pull-in has not yet been run. See
  [audit §6 & §9](./dependency-license-audit.md#6-anti-features--non-free-check).
- Verify each plugin builds cleanly on the F-Droid build server (some Flutter
  plugins need specific recipe tweaks).

## 5. Anti-features review

F-Droid labels apps with [anti-features](https://f-droid.org/docs/Anti-Features/)
where applicable. Current assessment:

| Anti-feature              | Present? | Notes |
| ------------------------- | -------- | ----- |
| Ads                       | **No**   | No advertising of any kind. |
| Tracking / analytics      | **No**   | No telemetry, analytics, or crash reporting SDKs. |
| Non-free network services | **No** (optional Jellyfin source — see below) | Local-first core needs no network. The optional Jellyfin source is user-configured and points at free software. |
| Non-free dependencies     | No (TBC) | Direct deps cleared (all MIT/BSD-3-Clause); transitive walk still to be confirmed by the audit above. |

> **Optional Jellyfin source.** A Jellyfin source foundation has landed (server
> settings, sign-in, encrypted session token, a library source). It is optional
> and entirely user-configured — no server is bundled, promoted, or required, and
> the local-first core works with no network at all. The Jellyfin server is
> itself free software, and Linthra only speaks HTTP(S) to it via the permissive
> `http` package, so it does not obviously warrant the `NonFreeNet`
> anti-feature. This is reviewed in detail in
> [dependency-license-audit.md §7](./dependency-license-audit.md#7-network-use--the-optional-jellyfin-source).
>
> **Future caveat:** any further online provider must be reviewed individually
> and may warrant `NonFreeNet` if it defaults to or promotes a non-free hosted
> service. The local-first core must remain fully functional without any remote
> source.

### Android storage / permissions status

- **No storage permissions are declared** in `AndroidManifest.xml`. Folder
  selection uses the Storage Access Framework via the system folder chooser
  (`file_picker`'s `ACTION_OPEN_DOCUMENT_TREE`), which needs no manifest
  permission.
- **`MANAGE_EXTERNAL_STORAGE` is intentionally not used.** It is an
  "all files access" permission Google restricts and F-Droid users distrust; it
  is the opposite of the scoped-storage approach this project prefers. It must
  not be added without an explicit, documented justification.
- **Known limitation:** a SAF folder is resolved to a filesystem path and walked
  with `dart:io`. On Android 11+ that path is frequently unreadable under scoped
  storage; the scanner now surfaces a clear in-app error in that case
  (`DirectoryReadability` probe + `FolderScanException`) rather than a silent
  empty library. Lifting the restriction needs content-resolver SAF traversal
  (native plugin); a narrow `READ_MEDIA_AUDIO` request is a separate future
  option. Neither permission is requested today.

## 6. Release / tagging plan

F-Droid builds from a git tag. Summary (the canonical, step-by-step process —
including the GitHub-Release flow — is in
[docs/release-process.md](./release-process.md)):

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

1. **Release signing.** Release signing can now be supplied via env vars /
   `android/key.properties`, with CI decoding a keystore from secrets; builds
   fall back to the debug key only when no signing material is present (see
   [docs/release-signing.md](./release-signing.md)). F-Droid signs its own
   builds, so this matters mainly for GitHub-Release artifacts. Remaining work:
   configure the actual release secrets and decide the GitHub-Release flow.
2. **No image assets.** Icon, feature graphic, and screenshots are missing (see
   [docs/listing-assets.md](./listing-assets.md)).
3. **Dependency audit (partly done).** The direct-dependency license review is
   complete — all MIT/BSD-3-Clause, MPL-2.0 compatible
   ([docs/dependency-license-audit.md](./dependency-license-audit.md)). Still
   open: a mechanical walk of the full transitive tree confirming no non-free /
   Google-only components.
4. **Reproducible build verification.** Confirm the app builds on F-Droid's
   build server, including Drift codegen as a prebuild step.
5. **No tagged release yet.** A `vX.Y.Z` tag must exist for F-Droid to build.
6. **Feature maturity (judgment call).** Decide whether to submit at the current
   early stage or wait until core playback ships.

## 9. Suggested order before F-Droid submission

1. Finish the dependency audit (§4): the direct-dep license review is done
   ([audit doc](./dependency-license-audit.md)); run the mechanical transitive
   walk and resolve any non-free findings.
2. Sort out release signing config (§8.1; see
   [docs/release-signing.md](./release-signing.md)).
3. Verify a clean release build, including codegen (§3, §8.4).
4. Capture and commit real image assets (§7; see
   [docs/listing-assets.md](./listing-assets.md)).
5. Finalize the version and cut a `vX.Y.Z` tag with a matching changelog (§6;
   full steps in [docs/release-process.md](./release-process.md)).
6. Prepare the F-Droid `metadata/<appid>.yml` build recipe and submit a merge
   request to [fdroiddata](https://gitlab.com/fdroid/fdroiddata).

The build recipe itself — expected metadata fields, build-source and toolchain
expectations, reproducibility notes, and a draft `metadata/<appid>.yml` snippet
— is planned in [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md).
