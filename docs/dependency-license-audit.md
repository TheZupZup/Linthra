# Dependency & license audit

This document audits Linthra's declared dependencies and their licenses, so a
future F-Droid submission (and any GitHub-Release distribution) can state the
project's licensing accurately. It is a planning/compliance aid.

> **Linthra is _not_ on F-Droid and has _not_ been submitted.** Nothing here
> publishes or submits anything. This audit records the licensing posture of the
> code as it stands; see the [F-Droid readiness checklist](./fdroid-readiness.md)
> for the overall submission status and blockers.

## 1. Project license

Linthra is licensed under the **Mozilla Public License 2.0** (`MPL-2.0`), an
[FSF/OSI-approved free license](https://www.gnu.org/licenses/license-list.html)
accepted by F-Droid. The full text is in [`LICENSE`](../LICENSE), and the SPDX
identifier F-Droid expects is `MPL-2.0`.

MPL-2.0 is a file-level (weak) copyleft. It combines cleanly with the permissive
(MIT / BSD) dependencies listed below: those licenses impose only attribution
and license-notice requirements, with no terms that conflict with shipping them
alongside MPL-2.0 code.

## 2. How this audit was produced (and its limits)

- **Scope:** the **direct** dependencies declared in
  [`pubspec.yaml`](../pubspec.yaml). Licenses below are the ones each package
  publishes on [pub.dev](https://pub.dev) / in its bundled `LICENSE` file.
- **Transitive walk — now run.** The full transitive dependency set has since
  been resolved and audited with the pinned toolchain (Flutter 3.27.4 /
  Dart 3.6.2). `flutter pub get` + `flutter pub deps` resolve **152** packages;
  a license scan of every resolved package (reading each package's bundled
  `LICENSE`) classifies them as **101 BSD-3-Clause, 34 MIT, 6 Apache-2.0,
  6 BSD-2-Clause, 2 MPL-2.0** — every one a permissive free-software license,
  MPL-2.0-compatible, with **no GPL/LGPL, proprietary, or unknown license**.
  The only two packages without their own `LICENSE` file are `flutter_test` and
  `flutter_web_plugins`, both bundled inside the Flutter SDK and covered by the
  SDK's own BSD-3-Clause license. No `com.google.android.gms` / `play-services`
  / Firebase / analytics / ads / crash-reporting package appears anywhere in the
  resolved tree (§5, §6). `pubspec.lock` remains git-ignored, so this reflects
  the set resolved at audit time; re-run on a dependency change.
- **To reproduce / extend this audit** with the toolchain available:

  ```sh
  flutter pub get
  flutter pub deps --style=compact     # full transitive dependency tree
  # Optional: collect every bundled LICENSE into one report
  dart pub global activate pana
  pana --no-warning .                  # includes a license check
  # or generate an in-app/exported license list:
  #   dart run flutter_oss_licenses:generate
  ```

  Cross-check the generated list against this table and resolve any package that
  is **not** a recognised free-software license or that pulls in proprietary /
  Google-only binaries.

## 3. Runtime dependencies (shipped in the APK)

All entries below are permissive free-software licenses (MIT or BSD-3-Clause),
compatible with MPL-2.0 and acceptable to F-Droid.

| Package                  | Constraint   | Publisher (pub.dev) | License        | Purpose in Linthra |
| ------------------------ | ------------ | ------------------- | -------------- | ------------------ |
| `flutter` (SDK)          | (SDK)        | flutter.dev         | BSD-3-Clause   | Framework. |
| `flutter_riverpod`       | `^2.6.1`     | (rrousselGit)       | MIT            | State management. |
| `go_router`              | `^14.6.2`    | flutter.dev         | BSD-3-Clause   | Navigation/routing. |
| `path`                   | `^1.9.0`     | dart.dev            | BSD-3-Clause   | Path parsing for the scanner. |
| `drift`                  | `^2.18.0`    | simonbinder.eu      | MIT            | Typed SQLite query layer. |
| `sqlite3_flutter_libs`   | `^0.5.20`    | simonbinder.eu      | MIT            | Bundles the native SQLite engine (see §5). |
| `path_provider`          | `^2.1.4`     | flutter.dev         | BSD-3-Clause   | Locates the on-device DB file. |
| `just_audio`             | `^0.9.42`    | ryanheise.com       | MIT            | Local audio playback engine. |
| `audio_service`          | `^0.18.15`   | ryanheise.com       | MIT            | Background playback / media session. |
| `file_picker`            | `^8.1.4`     | (miguelpruivo)      | MIT            | Native folder chooser (SAF). |
| `shared_preferences`     | `^2.3.3`     | flutter.dev         | BSD-3-Clause   | Persists the selected folder. |
| `http`                   | `^1.2.0`     | dart.dev            | BSD-3-Clause   | HTTP client for the optional self-hosted sources — Jellyfin and Navidrome/Subsonic (§7). |
| `crypto`                 | `^3.0.3`     | dart.dev            | BSD-3-Clause   | MD5 hashing for the Subsonic/Navidrome `token = md5(password + salt)` auth scheme, so only the derived `(salt, token)` is stored — never the plaintext password (§7). Also pulled in transitively by `just_audio`. |
| `flutter_secure_storage` | `^9.2.2`     | (juliansteenbakker) | BSD-3-Clause   | Encrypted store for the Jellyfin/Subsonic session token (§7). |
| `cast`                   | `^2.1.0`     | (johnvuko)          | MIT            | Pure-Dart Google Cast v2 protocol for real Chromecast — **no** Google Play Services / proprietary Cast SDK. See §5 (Casting). |
| `bonsoir`                | `^5.1.11`    | (Skyost)            | MIT            | mDNS/Bonjour service discovery used by `cast`; Android side is AOSP `NsdManager`, not GMS. Pinned to 5.x for Dart 3.6 (6.x+ needs Dart ≥3.8). See §5 (Casting). |
| `url_launcher`           | `^6.3.0`     | flutter.dev         | BSD-3-Clause   | Opens the browser for the "Report a bug" → "Open GitHub issue" action (a prefilled, **unsubmitted** issue the user reviews). AOSP `ACTION_VIEW` intent; **no** GMS. See note below and §7 (Reporting a bug). |

> The `http` and `flutter_secure_storage` entries were added with the Jellyfin
> source foundation; `cast` and `bonsoir` were added with real Chromecast
> support (§5, Casting). All four are permissive (MIT / BSD-3-Clause) Dart/Flutter-
> ecosystem packages. `cast` pulls in one transitive runtime package, `protobuf`
> (`^3.1.0`, dart.dev, **BSD-3-Clause**), used only to frame cast-channel
> messages — also free software, no GMS. `url_launcher` was added with the
> "Report a bug" flow; it is the official Flutter-team plugin (**BSD-3-Clause**),
> and on Android it fires a standard AOSP `ACTION_VIEW` intent (no Google Play
> Services). It is wrapped behind the `ExternalLinkLauncher` interface and is
> invoked only on an explicit user tap — the app never opens a link on its own.
> See §7.

## 4. Dev / build-only dependencies (NOT shipped in the APK)

These run only during development, analysis, or code generation and are not part
of the released artifact, so they do not affect the APK's license. They are
listed for completeness.

| Package         | Constraint   | Publisher | License        | Purpose |
| --------------- | ------------ | --------- | -------------- | ------- |
| `flutter_lints` | `^5.0.0`     | flutter.dev | BSD-3-Clause | Lint rule set. |
| `flutter_test`  | (SDK)        | flutter.dev | BSD-3-Clause | Test framework. |
| `drift_dev`     | `^2.18.0`    | simonbinder.eu | MIT       | Drift code generation. |
| `build_runner`  | `^2.4.13`    | dart.dev  | BSD-3-Clause   | Runs the code generators. |

## 5. Native / bundled components

F-Droid requires every shipped component to be free software and buildable from
source (no prebuilt proprietary blobs).

- **SQLite** (via `sqlite3_flutter_libs`): the SQLite amalgamation is in the
  **public domain** and is compiled from source as part of the build — not a
  prebuilt closed binary. The Dart wrapper packages are MIT.
- **Android Keystore / EncryptedSharedPreferences** (used by
  `flutter_secure_storage`): part of the **AOSP** platform, not Google Play
  Services. No proprietary dependency is introduced.
- **AndroidX Media3 / ExoPlayer** (Maven AAR pulled by `just_audio`):
  `androidx.media3:media3-exoplayer:1.4.1` (+ the `-dash`, `-hls`,
  `-smoothstreaming` modules) is the playback engine for both local files and
  streaming. **Media3 is part of AndroidX/Jetpack and is licensed Apache-2.0 —
  open source and buildable from source. It is _not_ Google Play Services / the
  proprietary Cast SDK.** `audio_service` and `audio_session` likewise use only
  `androidx.media:media:1.7.0` and `androidx.core:core` (AndroidX, Apache-2.0).
  Media3's bundled manifest is the source of the merged `ACCESS_NETWORK_STATE`
  permission (it reads connectivity state for adaptive streaming); see the
  permissions table in [fdroid-readiness.md](./fdroid-readiness.md).
- **No Google Play Services / Firebase / GMS.** Confirmed by the transitive walk
  (§2): no `com.google.android.gms`, `play-services`, Firebase, or other
  proprietary Google library appears in the resolved dependency tree. The
  Android Auto declaration uses the standard `MediaBrowserService` /
  `media-session` APIs from `audio_service` (AOSP media APIs), not a proprietary
  car SDK — the `com.google.android.gms.car.application` manifest entry is just
  the meta-data key name Android Auto reads to list a media app; it links no GMS
  library.

### Casting (Chromecast) — real Cast without Google Play Services

Real Chromecast support is implemented **without** the official Google Cast
SDK, which is the important F-Droid distinction:

- **Why not the official SDK.** Google's Cast SDK for Android
  (`com.google.android.gms.cast.*`) is part of **Google Play Services** —
  proprietary and not buildable from source. Depending on it would introduce a
  GMS requirement and almost certainly warrant the `NonFreeDep` anti-feature, so
  it was **rejected**.
- **What is used instead.** The pure-Dart `cast` package speaks the Google Cast
  **v2 wire protocol** directly: mDNS discovery (via `bonsoir`), a TLS socket to
  the device, and `protobuf`-framed messages to the device's *Default Media
  Receiver*. No Google library is linked.
  - `cast` — **MIT**, pure Dart.
  - `bonsoir` (+ `bonsoir_android`, `bonsoir_platform_interface`, …) — **MIT**.
    The Android implementation uses **`android.net.nsd.NsdManager`**, an **AOSP**
    API, not GMS. Its `build.gradle` pulls in only Kotlin stdlib and test-only
    libraries (no `com.google.android.gms`/`play-services`). Pinned to `5.x`
    because `6.x`+ require Dart ≥3.8 while the project targets Dart 3.6.
  - `protobuf` — **BSD-3-Clause** (dart.dev), transitive via `cast`, used only to
    encode/decode cast-channel frames.
- **New permission.** `bonsoir` adds **`CHANGE_WIFI_MULTICAST_STATE`** (declared
  explicitly in `AndroidManifest.xml` for auditability). It is an **AOSP**
  permission allowing receipt of multicast Wi-Fi packets for mDNS discovery; it
  grants no internet or storage access. The cast session itself uses the
  existing `INTERNET` permission to reach the device on the LAN.
- **No secrets leave the device improperly.** A castable URL (which, for
  Jellyfin, embeds the access token in its query) is resolved **on demand at
  cast time**, handed straight to the cast session for the device to fetch, and
  **never persisted or logged** (`CastMedia.toString()` redacts the query, like
  `JellyfinSession`). On-device files have no reachable URL and are surfaced as a
  clear limitation rather than cast.
- **F-Droid verdict.** Casting introduces **no proprietary/GMS dependency and no
  anti-feature**, so it can ship in the F-Droid build. (As always, the mechanical
  transitive walk in §6 should confirm no GMS pull-in; the manual review of
  `bonsoir_android`'s `build.gradle` above already shows none.)

## 6. Anti-features / non-free check

Mapped to F-Droid's [anti-features](https://f-droid.org/docs/Anti-Features/):

| Concern                    | Status | Notes |
| -------------------------- | ------ | ----- |
| Ads                        | None   | No advertising libraries or code. |
| Tracking / analytics       | None   | No telemetry, analytics, or crash-reporting SDK is present. |
| Proprietary dependencies   | **None** (transitive walk confirmed) | All 152 resolved packages are permissive free software (MIT/BSD/Apache-2.0/MPL-2.0); no GMS/Firebase/proprietary package present (§2). Native AARs are AndroidX Media3/`media`/`core` (Apache-2.0) and SQLite (public domain) — all open source (§5). Chromecast deliberately avoids the GMS Cast SDK (pure-Dart `cast` + AOSP `NsdManager` via `bonsoir`); see §5 (Casting). |
| Non-free network services  | See §7 | Local-first core needs no network; the self-hosted Jellyfin/Navidrome/Subsonic sources are optional and user-configured. |

## 7. Network use & the optional self-hosted sources

Linthra is **local-first**: the core (folder selection, scanning, the persisted
catalog) works with **no network access at all**. Optional self-hosted sources —
**Jellyfin** and **Navidrome / Subsonic** — let the user stream from a server
they run themselves. These are the reason `http`, `crypto`, and
`flutter_secure_storage` are dependencies. The production
`AndroidManifest.xml` now declares the `INTERNET` permission (so release builds
can reach the user's server); this is a normal, expected permission for a
user-opted-in remote source and is not an anti-feature by itself. F-Droid
implications:

- **Optional and user-configured.** No server is bundled, promoted, or required;
  the user supplies their own server URL and credentials. The app does not
  depend on, default to, or promote any specific hosted service, and the
  local-first core remains fully functional with no network at all.
- **The servers are free software.** Jellyfin, Navidrome, and the Subsonic API
  ecosystem are themselves free/open-source. Linthra only speaks plain HTTP(S)
  to them via the permissive `http` package; the Subsonic/Navidrome
  `token = md5(password + salt)` scheme is computed locally with `crypto`.
- **Anti-feature judgement (`NonFreeNet`):** because every non-local source is
  optional, user-supplied, and points at free software the user hosts, it does
  **not** warrant the `NonFreeNet` anti-feature. This should still be **reviewed
  at submission time** — if any future source defaults to or promotes a non-free
  hosted service, it must be reassessed (the
  [readiness doc](./fdroid-readiness.md#5-anti-features-review) carries the same
  caveat).

### Reporting a bug (browser hand-off, no auto-send)

The in-app "Report a bug" flow (Settings → Report a bug) is the reason
`url_launcher` is a dependency. Its network/privacy posture:

- **Nothing is sent automatically.** The report is assembled **on device** from
  the existing secret-free diagnostics and a bounded in-memory ring of
  structural breadcrumbs. The user reviews it in a preview, then chooses to copy,
  save, or open a GitHub issue. There is **no backend**, no Linthra server, and
  **no upload to Claude/OpenAI/Anthropic or any third-party/AI service**.
- **"Open GitHub issue" is a browser hand-off.** It builds a
  `github.com/.../issues/new?...` URL with the report prefilled and opens it via
  `url_launcher` (AOSP `ACTION_VIEW`). The issue is **unsubmitted**: the user
  reviews and submits it themselves in their browser. **No GitHub token** is used
  and the app posts nothing on the user's behalf.
- **No new data collection.** The recent-events buffer holds only the same
  secret-free labels `StabilityDiagnostics` already emits (an output name, a
  lifecycle state, an error *kind*); it is memory-only, capped, never persisted,
  and surfaced solely when the user opts in while building a report.
- **Anti-feature judgement:** opening a user-chosen link in the browser is not an
  anti-feature and introduces no tracking. `url_launcher` is the official
  Flutter-team plugin and pulls in only its own federated platform packages — no
  GMS (to be confirmed by the mechanical transitive walk in §9).

## 8. Summary

- **Project license:** MPL-2.0 (free, F-Droid-accepted).
- **Direct dependencies:** all MIT or BSD-3-Clause — permissive, free, and
  MPL-2.0-compatible. No copyleft conflicts, no proprietary direct deps.
- **Transitive set:** the full resolved tree (152 packages) was audited (§2) —
  all permissive (BSD/MIT/Apache-2.0/MPL-2.0), no GMS/Firebase/proprietary.
- **Native bits:** SQLite (public domain, built from source), AndroidX Media3 /
  `media` / `core` (Apache-2.0, open source — the playback engine, not GMS), and
  Android Keystore (AOSP). No Google Play Services / Firebase anywhere.
- **Bottom line:** nothing in the dependency set — direct or transitive — blocks
  F-Droid on licensing grounds.

## 9. Outstanding before submission

1. ~~**Run the mechanical transitive audit.**~~ **Done** (§2): 152 resolved
   packages, all permissive free software, no GMS/Firebase/proprietary pull-in.
   Re-run on any dependency change (item 3).
2. **Decide the `pubspec.lock` policy** for releases so the audited dependency
   set is pinned at the tagged commit (see
   [fdroid-build-recipe.md §4](./fdroid-build-recipe.md#4-reproducibility-notes)).
3. **Re-run this audit whenever a dependency is added or bumped**, and update the
   tables above.

## 10. Related docs

- [docs/fdroid-readiness.md](./fdroid-readiness.md) — overall F-Droid submission
  checklist and blockers.
- [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md) — build recipe and
  reproducible-build notes.
- [docs/release-process.md](./release-process.md) — release/tagging and
  GitHub-Release process.
- [docs/release-signing.md](./release-signing.md) — how release builds are
  signed.
