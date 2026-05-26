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
- **Not yet run mechanically:** a full **transitive** dependency walk was not
  generated for this document (the Dart/Flutter toolchain and a resolved
  `pubspec.lock` were not available in the environment that produced it, and
  `pubspec.lock` is currently git-ignored — see
  [reproducibility notes](./fdroid-build-recipe.md#4-reproducibility-notes)).
  Confirming the complete transitive set is still an open item (§6).
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
| `http`                   | `^1.2.0`     | dart.dev            | BSD-3-Clause   | HTTP client for the optional Jellyfin source (§7). |
| `flutter_secure_storage` | `^9.2.2`     | (juliansteenbakker) | BSD-3-Clause   | Encrypted store for the Jellyfin session token (§7). |
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
- **No Google Play Services / Firebase / GMS.** None of the direct dependencies
  require Google Play Services, Firebase, or other proprietary Google libraries.
  The Android Auto declaration uses the standard `MediaBrowserService` /
  `media-session` APIs from `audio_service` (AOSP media APIs), not a proprietary
  car SDK. _(Confirm there is no transitive GMS pull-in as part of §6.)_

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
| Proprietary dependencies   | None found in **direct** deps | All direct deps are MIT/BSD-3-Clause; transitive set still to be confirmed mechanically (§2). Chromecast deliberately avoids the GMS Cast SDK (pure-Dart `cast` + AOSP `NsdManager` via `bonsoir`); see §5 (Casting). |
| Non-free network services  | See §7 | Local-first core needs no network; Jellyfin is optional and user-configured. |

## 7. Network use & the optional Jellyfin source

Linthra is **local-first**: the core (folder selection, scanning, the persisted
catalog) works with **no network access at all**. The production
`AndroidManifest.xml` declares no `INTERNET` permission of its own; `INTERNET`
appears only in the debug/profile manifests (for Flutter hot reload).

A **Jellyfin** source foundation has since landed (server settings, sign-in,
encrypted session token, a library source behind an interface). It is the reason
`http` and `flutter_secure_storage` are dependencies. F-Droid implications:

- **Optional and user-configured.** No Jellyfin server is bundled, promoted, or
  required; the user supplies their own server URL and credentials. The app does
  not depend on any specific hosted service.
- **Jellyfin is free software.** The Jellyfin server is itself
  free/open-source, and Linthra only speaks plain HTTP(S) to it via the
  permissive `http` package.
- **Anti-feature judgement:** because the non-local source is optional,
  user-supplied, and points at free software, it does not obviously warrant the
  `NonFreeNet` anti-feature. This should still be **reviewed at submission time**
  — if any future source defaults to or promotes a non-free hosted service, it
  must be reassessed (the [readiness doc](./fdroid-readiness.md#5-anti-features-review)
  carries the same caveat).
- When the Jellyfin client begins making real network calls, the production
  manifest will need an `INTERNET` permission; that is a normal, expected
  permission for a user-opted-in remote source and is not an anti-feature by
  itself.

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
- **Native bits:** SQLite (public domain, built from source) and Android Keystore
  (AOSP). No Google Play Services / Firebase in the direct dependency set.
- **Bottom line:** nothing in the **declared** dependency set blocks F-Droid on
  licensing grounds. The remaining work is mechanical verification of the full
  transitive tree (§6 below).

## 9. Outstanding before submission

1. **Run the mechanical transitive audit** (§2 commands) and confirm every
   transitive package is free software with no Google-only / proprietary binary
   pull-in. This is the last open piece of the dependency blocker tracked in
   [fdroid-readiness.md §8](./fdroid-readiness.md#8-remaining-blockers-before-submission).
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
