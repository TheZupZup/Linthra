# Google Play readiness checklist

This document tracks what Linthra needs before it can go through **Google Play
closed testing** and, much later, production. It is a planning aid, **not** a
claim of availability.

> **Linthra is _not_ on Google Play, and no submission has been made.** This
> checklist exists so that a first **internal / closed testing** submission is
> straightforward and accurate. Linthra is still an **alpha** and must not be
> published to the production track yet.

For F-Droid the parallel document is
[docs/fdroid-readiness.md](./fdroid-readiness.md); the two stores share the same
identity, version source, and assets but differ on signing and submission.

## 1. Current status

- **Stage:** early alpha. Current version `0.1.0-alpha.9+9` (see `pubspec.yaml`).
- **Distribution:** sideloadable pre-release APK/AAB attached to GitHub
  Releases. **Not** on Google Play, **not** on F-Droid; nothing publishes
  automatically.
- **Groundwork in place:**
  - Stable application ID `io.github.thezupzup.linthra` and MPL-2.0 license.
  - A real Linthra app/launcher icon (adaptive + legacy) plus a 512×512 store
    icon and a 1024×500 feature graphic under
    `fastlane/metadata/android/en-US/images/`.
  - A release workflow that already builds an **AAB** (`flutter build appbundle
    --release`) as well as an APK — see
    [docs/release-process.md](./release-process.md) and
    `.github/workflows/android-release-build.yml`.
  - Release signing is **wired** (env vars / `android/key.properties`) but the
    real keystore/secrets are **not yet provisioned** — see
    [docs/release-signing.md](./release-signing.md).
  - Fastlane-style listing text (`title.txt`, `short_description.txt`,
    `full_description.txt`, per-`versionCode` changelogs).
- **Not ready for production.** See
  [§9 Known blockers before production](#9-known-blockers-before-production).

## 2. App identity

| Field            | Value                            |
| ---------------- | -------------------------------- |
| Name             | Linthra                          |
| App ID           | `io.github.thezupzup.linthra`    |
| License          | MPL-2.0                          |

- The App ID is set as both the Android `namespace` and `applicationId` in
  `android/app/build.gradle`. On Google Play the **package name is permanent**
  once an app is created — it can never be changed for that listing, so it must
  be correct at first upload. It already matches the F-Droid plan and the
  GitHub-Release artifacts.
- License is declared in [`LICENSE`](../LICENSE) (Mozilla Public License 2.0).
  Play does not require a specific license, but Linthra remains open source.

## 3. Release artifact

| Artifact | Built by                              | Use on Play                          |
| -------- | ------------------------------------- | ------------------------------------ |
| **AAB**  | `flutter build appbundle --release`   | **Required.** Google Play accepts only Android App Bundles for new apps; Play generates per-device APKs from it. |
| APK      | `flutter build apk --release`         | **Not** uploaded to Play. Useful for GitHub Releases / direct sideload testing and for quick on-device checks. |

The release workflow already produces both and labels them with the version and
signing mode (e.g. `linthra-v0.1.0-alpha.9-release-signed.aab`). For Play, take
the **release-signed `.aab`** from a `v*` tag build (or a `signed = true` manual
run) and upload it to the chosen testing track.

## 4. Signing

Two distinct keys are involved once Play App Signing is used. Do not confuse
them.

### Google Play App Signing (recommended)

- When you enrol an app in **Play App Signing**, Google holds the **app signing
  key** (the key end users' installs are signed with) in its own infrastructure.
  You never see it and cannot lose it.
- You sign each upload with your **upload key** and submit that. Google
  re-signs with the app signing key before distributing.
- For the **first** app you can either let Google generate the app signing key,
  or upload one you generated. Letting Google generate it is the low-risk
  default for a new listing.
- The **upload key** is exactly the release keystore this repo already supports
  (see below). If the upload key is ever lost, Google can reset it — unlike the
  app signing key, which is permanent.

### Release keystore (the upload key)

- Linthra's release build reads signing material from environment variables or a
  git-ignored `android/key.properties`, falling back to the **debug** key when
  none is present. Full details, secret names, and `keytool` generation steps
  are in [docs/release-signing.md](./release-signing.md).
- For Play, generate a release keystore (see release-signing.md §4) and use it
  as the **upload key**. Keep it backed up; reuse it for every upload.
- **Debug-signed builds must never be uploaded to Play**, not even to internal
  testing — they are clearly labeled `-debug-signed` by CI precisely so they
  are not mistaken for a real build.

### Do not commit secrets

- Keystores (`*.keystore`, `*.jks`) and `android/key.properties` are
  git-ignored. **Never** commit a keystore, a password, or `key.properties`, and
  never paste a real password into code, CI YAML, a commit message, or this doc.
- In CI the keystore is provided base64-encoded via the `LINTHRA_KEYSTORE_BASE64`
  secret and decoded to a temp file at runtime (release-signing.md §2).

## 5. Testing tracks

Google Play offers a ladder of tracks. Use them in order; do not jump to
production.

| Track                | Audience                                  | Use for Linthra |
| -------------------- | ----------------------------------------- | --------------- |
| **Internal testing** | Up to 100 testers you list by email; fastest review/propagation. | **Start here.** Smoke-test the uploaded AAB, store listing, and Data Safety form end to end. |
| **Closed testing**   | Invited testers via email lists or Google Groups. | **The goal of this prep.** Gather real feedback from a small trusted group on real devices. |
| **Open testing**     | Anyone with the opt-in link; public.      | Optional, later — only once closed testing is stable and feedback is addressed. |
| **Production**       | Public on the Play Store.                 | **Not yet.** Only after real closed/open feedback and the blockers in §9 are cleared. |

> **Newer-account testing requirement.** Personal Google Play developer
> accounts created after Nov 2023 must run a **closed test with at least 12
> testers opted in for 14+ days** before they can apply for production access.
> If this account is subject to that rule, closed testing is not optional — it
> is the path to production. Verify the exact current requirement in the Play
> Console before planning timelines.

## 6. Required assets

Google Play listing assets (managed in the Play Console; the repo already holds
reusable copies under `fastlane/metadata/android/en-US/images/`):

| Asset                 | Play requirement                                   | Status  |
| --------------------- | -------------------------------------------------- | ------- |
| **App icon**          | 512×512 PNG, 32-bit with alpha.                    | Present (`images/icon.png`). |
| **Feature graphic**   | 1024×500 PNG/JPG. Required to publish on any track.| Present (`images/featureGraphic.png`). |
| **Phone screenshots** | 2–8, each side 320–3840 px, long side ≤ 2× short.  | Real captures exist for F-Droid (`images/phoneScreenshots/`), but at 1008×2244 (≈9:20) they exceed Play's 2:1 limit — **crop before using on Play**. |
| **7-inch tablet**     | Optional.                                          | Missing (optional). |
| **10-inch tablet**    | Optional.                                          | Missing (optional). |

- Phone screenshots **exist for F-Droid / GitHub** — eight real captures under
  `images/phoneScreenshots/` — but they're full-height 1008×2244 (≈9:20), which
  exceeds Play's "long side ≤ 2× short side" rule, so they must be **cropped**
  before reuse on a Play listing (still the main image to-do for Play). Always
  from a **real** running build, never mockups or upscaled placeholders. Sizes
  and `adb` capture steps are in [docs/listing-assets.md](./listing-assets.md).
- The icon and feature graphic are generated deterministically from one source
  design (`tool/branding/`), so the Play and F-Droid copies never drift.

## 7. Data Safety checklist

Google Play requires a **Data Safety** form for every app. A Linthra-specific
draft of the likely answers lives in
[docs/google-play-data-safety.md](./google-play-data-safety.md). Before
submission:

- [ ] Confirm **no ads** SDK is present (none today).
- [ ] Confirm **no third-party analytics / crash-reporting** SDK is present
      (none today — verify against `pubspec.yaml` at submission time).
- [ ] Declare the Jellyfin **server URL + credentials/session token** as data
      stored **on the device** (encrypted), not collected by us — Linthra runs
      no server of its own.
- [ ] Declare **no data sold** and **no data shared** with third parties.
- [ ] State that traffic to a Jellyfin server is **encrypted in transit when the
      user's server uses HTTPS** (the user controls this).
- [ ] Re-check the form whenever a dependency is added (a new SDK can change the
      honest answers).

## 8. Privacy policy checklist

Google Play requires a **privacy policy URL** for the listing (and always for
apps that handle account/credential data). A draft is in
[docs/privacy-policy.md](./privacy-policy.md). Before submission:

- [ ] Review the draft for accuracy against the current build.
- [ ] Publish it at a **stable public URL** (e.g. GitHub Pages, the repo's
      rendered Markdown, or a project site) and paste that URL into the Play
      Console listing.
- [ ] Keep the policy and the Data Safety form **consistent** — Play checks that
      they do not contradict each other.
- [ ] Update the policy if data handling changes.

## 9. Known blockers before production

These do **not** all block *closed testing*, but they block a *production*
launch. Items marked **(closed-testing blocker)** must be done before even
internal/closed testing.

1. **Play-ratio screenshots** **(closed-testing blocker)** — real captures exist
   for F-Droid (`images/phoneScreenshots/`), but Play needs them cropped to its
   ≤ 2:1 ratio; see [docs/listing-assets.md](./listing-assets.md).
2. **Release/upload keystore provisioned** and Play App Signing enrolled
   **(closed-testing blocker)** — see
   [docs/release-signing.md](./release-signing.md). A debug-signed build cannot
   be uploaded to any track.
3. **Privacy policy published at a public URL** **(closed-testing blocker)** —
   draft in [docs/privacy-policy.md](./privacy-policy.md).
4. **Data Safety form completed** in the Play Console **(closed-testing
   blocker)** — draft in [docs/google-play-data-safety.md](./google-play-data-safety.md).
5. **Target API level** meets Play's current minimum. Linthra inherits
   `targetSdk` from `flutter.targetSdkVersion` (`android/app/build.gradle`), so
   the effective value depends on the pinned Flutter SDK. Play raises the
   minimum target each year — **verify the built AAB's `targetSdkVersion` meets
   the current Play requirement** before upload, and bump the Flutter SDK if
   needed.
6. **Alpha feature maturity.** Tag parsing/artwork, artist/album browse, search,
   playlists, and batch downloads are still planned (see the README roadmap).
   This is fine for closed testing but is a judgment-call blocker for a
   production launch.
7. **Closed-test tester count / duration**, if the account is subject to the
   newer testing requirement (§5).
8. **Content rating questionnaire** completed in the Play Console (Play requires
   it before publishing on any public track).

## 10. Recommended first submission path

1. **Internal testing first.** Upload the release-signed AAB, complete the store
   listing, Data Safety form, content rating, and privacy-policy URL. Add
   yourself and a few trusted emails as internal testers and verify the whole
   flow on a real device — install, sign in to a Jellyfin server, play, cache,
   cast.
2. **Closed testing next.** Promote the build to a closed track, invite a small
   trusted group, and gather real feedback. If the account is subject to the
   newer rule (§5), run this for the required tester count / duration.
3. **Open testing (optional).** Only once closed testing is stable.
4. **Production only after real feedback.** Do not promote to production until
   the §9 blockers are cleared and closed/open testing has surfaced and resolved
   real-world issues. Linthra is alpha software; ship it as such.

## 11. Versioning for Play uploads

Play enforces a **strictly increasing `versionCode`** per package: an upload
with an equal or lower code than any previous upload (on any track) is rejected.
Linthra's versioning model supports this safely:

- **The Git tag is the source of truth for a release.** The release build derives
  `versionName`/`versionCode` from the tag and bakes them in — the strictly
  monotonic, fully-encoded `versionCode` (e.g. `v0.1.0-alpha.16` → `100016`)
  satisfies Play's strictly-increasing requirement by construction. `pubspec.yaml`
  only sets the version for local/dev builds. See
  [release-process.md §1](./release-process.md#1-versioning-model).
- The in-app About/Settings string (`AppInfo.version` in
  `lib/core/app_info.dart`) shows the **effective** version: the tag-derived value
  on a release build (via `--dart-define`), or a `const` mirror of `pubspec.yaml`
  on dev builds that a CI test (`test/core/app_info_version_test.dart`) **fails
  the build if it drifts**. Either way the displayed version matches the shipped
  one. **No manual versioning edits are needed for Play.**

**Per-upload checklist (in addition to
[release-process.md §3](./release-process.md#3-pre-tag-checklist)):**

- [ ] The upload is built from a `vX.Y.Z[-suffix]` tag, so `versionName`,
      `versionCode`, and the in-app `AppInfo.version` are all tag-derived and
      consistent — no manual version edits.
- [ ] `versionCode` is **strictly greater** than every code ever uploaded to
      Play — across **all** tracks, not just the current one (the encoded scheme
      guarantees this for increasing tags). Once a code is consumed by an upload
      it can never be reused, even if that upload is discarded.
- [ ] A matching changelog exists at
      `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.

## 12. Permissions review

Linthra's `AndroidManifest.xml` declares a deliberately small permission set.
Play's Data Safety and review process expects each to be justified.

| Permission | Why Linthra needs it |
| ---------- | -------------------- |
| `INTERNET` | Reach the **user-configured** Jellyfin server (connection test, sign-in, library sync, streaming) and run the Cast session to a chosen device. No server is bundled or contacted unless the user configures one. |
| `FOREGROUND_SERVICE` | Run the `audio_service` playback service in the foreground so audio keeps playing while the app is backgrounded. |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | The typed-foreground-service grant required on Android 14+ (API 34) for a `mediaPlayback` service; without it the playback service cannot start on new devices. |
| `POST_NOTIFICATIONS` | Android 13+ runtime permission for the media notification and its lock-screen / transport controls. Requested once on first launch; denial only suppresses the notification, playback still works. |
| `CHANGE_WIFI_MULTICAST_STATE` | Receive multicast Wi-Fi packets for **mDNS** (`_googlecast._tcp`) so Chromecast devices on the **local network** can be discovered. Grants no internet or storage access of its own. |

Notes:

- **No storage/media permissions are declared.** Local folder access uses the
  Storage Access Framework folder grant the user picks — no
  `READ_MEDIA_AUDIO`, no `MANAGE_EXTERNAL_STORAGE`. This keeps the Play "all
  files access" declaration unnecessary.
- **Cast uses no Google Play Services / Google Cast SDK.** It is a pure-Dart
  Cast v2 implementation (`cast` + `bonsoir` over AOSP `NsdManager`). The
  manifest's `com.google.android.gms.car.application` entry is **only a
  metadata declaration** that tells Android Auto Linthra is a media app
  (pointing at `automotive_app_desc.xml`); it does **not** link the GMS Cast or
  Car SDK. See [docs/dependency-license-audit.md](./dependency-license-audit.md).
- The same permission rationale, with more F-Droid framing, is in
  [docs/fdroid-readiness.md §5](./fdroid-readiness.md#5-anti-features-review).

## 13. Related docs

- [docs/privacy-policy.md](./privacy-policy.md) — privacy policy draft.
- [docs/google-play-listing.md](./google-play-listing.md) — store listing draft.
- [docs/google-play-data-safety.md](./google-play-data-safety.md) — Data Safety
  form prep.
- [docs/release-process.md](./release-process.md) — versioning, tagging, and the
  release-build workflow.
- [docs/release-signing.md](./release-signing.md) — keystore, CI secrets,
  rotation, and Play App Signing notes.
- [docs/listing-assets.md](./listing-assets.md) — icon, feature graphic, and
  screenshot capture.
- [docs/fdroid-readiness.md](./fdroid-readiness.md) — the parallel F-Droid
  checklist.
</content>
</invoke>
