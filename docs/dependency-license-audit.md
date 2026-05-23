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

> The `http` and `flutter_secure_storage` entries were added with the Jellyfin
> source foundation and are the two newest runtime dependencies; both are
> permissive (BSD-3-Clause) Dart/Flutter-ecosystem packages.

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

## 6. Anti-features / non-free check

Mapped to F-Droid's [anti-features](https://f-droid.org/docs/Anti-Features/):

| Concern                    | Status | Notes |
| -------------------------- | ------ | ----- |
| Ads                        | None   | No advertising libraries or code. |
| Tracking / analytics       | None   | No telemetry, analytics, or crash-reporting SDK is present. |
| Proprietary dependencies   | None found in **direct** deps | All direct deps are MIT/BSD-3-Clause; transitive set still to be confirmed mechanically (§2). |
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
