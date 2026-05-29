# Google Play Data Safety prep (draft)

> **Draft for review.** This documents the **likely** answers for Google Play's
> **Data Safety** form, based on how Linthra behaves today. It has not been
> legally reviewed. Re-check every answer against the shipped build in the Play
> Console before submitting, and keep it consistent with
> [docs/privacy-policy.md](./privacy-policy.md). See
> [docs/play-store-readiness.md](./play-store-readiness.md).

## How to read this

Google Play's Data Safety form distinguishes:

- **Collected** — user data transmitted **off the device** to the developer or a
  third party the developer works with.
- **Shared** — user data transferred to a **third party**.

The key fact for Linthra: **the Linthra project operates no backend.** There is
no Linthra account and no Linthra server. The app only talks to sources **the
user** configures (their own Jellyfin or Subsonic/Navidrome server) and to the
user's own local files and local-network Cast devices. So the Linthra developer
does not receive any user data.

> **Nuance to confirm in the Console.** When a user connects their **own**
> Jellyfin or Subsonic/Navidrome server, data (credentials, library requests) is
> sent to **that server**, which the user controls and the developer has no
> access to. Whether
> Google's form treats "data sent to a user-designated server the developer
> can't access" as developer *collection* is a judgment call; the honest
> position is that **the developer collects nothing**. Decide the exact form
> answers in the Play Console using Google's current definitions, and make sure
> they match the privacy policy.

## Summary of likely disclosures

- **Ads:** none. Linthra contains **no advertising SDK** and shows no ads.
- **Third-party analytics / crash reporting:** **none present.** There is no
  analytics, telemetry, or crash-reporting SDK in the app. (Verify against
  `pubspec.yaml` at submission time — see the dependency list below.)
- **Data sold:** **no.** Linthra does not sell user data.
- **Data shared with third parties:** **no** (the developer has no backend; data
  the user sends to their own Jellyfin or Subsonic/Navidrome server is not shared
  with the developer or anyone else by Linthra).
- **Data collected by the developer:** **none** (no Linthra backend; see nuance
  above for the user's own server).
- **App functionality / local app activity:** stored **on the device** for the
  app to work (library, settings, cache).
- **Encryption in transit:** traffic to a Jellyfin server is encrypted **when
  the user's server uses HTTPS** (the user controls this).
- **Data deletion:** the user can sign out/clear settings, clear the cache, or
  uninstall to remove locally stored data.

## Data types handled (and where)

Everything below is stored **locally on the device**. None of it is sent to the
Linthra developer (there is no developer backend).

| Data | Purpose | Where stored | Leaves device? |
| ---- | ------- | ------------ | -------------- |
| **Server URL** (Jellyfin or Subsonic/Navidrome) | Connect to the user's chosen server | Encrypted secure storage (Android Keystore-backed) | Only to the user's own server, only if configured |
| **Username** + server identity | Display the signed-in account; auth | Encrypted secure storage | Sent to the user's own server during auth |
| **Session credential** — a Jellyfin session token, or a Subsonic/Navidrome `salt`+`token` (`token = md5(password + salt)`) | Keep the user signed in | Encrypted secure storage (never plaintext, never logged) | Sent to the user's own server as the auth header/params |
| **Password** | One-time sign-in only | **Not stored** — used once to derive the token/credential, then discarded | Sent once to the user's own server (Jellyfin), or used only locally to derive the Subsonic token, to authenticate |
| **Music library metadata** (track/album/artist) | Browse/play, work offline | Local SQLite database on device | No |
| **Offline cache / downloaded tracks** | User-requested offline playback | Local app file storage on device | No (downloaded *from* the user's server on request) |
| **App settings** (selected folder, cache size, download prefs) | App functionality | Local Android preference storage | No |

Notes for the form:

- The **server URL, username, and session credential** (a Jellyfin token, or a
  Subsonic/Navidrome salt+token) are the only account/credential-style data, and
  they live in **encrypted** on-device storage. The **password is never
  stored** — for Subsonic/Navidrome it is only used locally to compute the
  `md5(password + salt)` token, then discarded.
- The user-selected **music folder** uses Android's Storage Access Framework
  grant; Linthra requests **no** broad storage / "all files" permission.

## Security practices (Data Safety "Security practices" section)

- **Encrypted in transit:** traffic to a Jellyfin or Subsonic/Navidrome server is
  encrypted **when the user's server uses HTTPS**. Because the user supplies the
  server URL, Linthra cannot guarantee HTTPS for every user — answer this
  question honestly ("encrypted in transit when the configured server uses
  HTTPS") rather than an unqualified "yes."
- **Encrypted at rest:** the server session (URL, username, and the Jellyfin
  token or Subsonic/Navidrome salt+token) is stored in Android Keystore-backed
  encrypted storage.
- **Data deletion mechanism:** users can **sign out & clear** the server session
  (Jellyfin or Subsonic/Navidrome), **clear the offline cache**, and
  **uninstall** the app to remove locally stored data. There is no server-side
  data to request deletion of, because there is no Linthra server.

## Casting / Google dependencies — implications

- Casting uses a **pure-Dart Cast v2 protocol** implementation (`cast`) with
  **mDNS** discovery (`bonsoir`, via AOSP `NsdManager`). It does **not** use
  Google Play Services or the proprietary Google Cast SDK, so casting introduces
  **no Google data-collection SDK**.
- Cast traffic goes to a device on the user's **local network** that the user
  selects — not through any Linthra or Google cloud service.
- The `AndroidManifest.xml` entry `com.google.android.gms.car.application` is a
  **metadata declaration** that lets Android Auto recognize Linthra as a media
  app (it points at `automotive_app_desc.xml`). It does **not** link the GMS
  Cast/Car SDK and does not collect data.
- See [docs/dependency-license-audit.md](./dependency-license-audit.md) for the
  full dependency/anti-feature review.

## Dependencies relevant to Data Safety

For verifying "no analytics / no ads" at submission time, the shipped runtime
dependencies (from `pubspec.yaml`) are: `flutter_riverpod`, `go_router`, `path`,
`drift`, `sqlite3_flutter_libs`, `path_provider`, `just_audio`, `audio_service`,
`file_picker`, `shared_preferences`, `http`, `crypto`, `permission_handler`,
`flutter_secure_storage`, `cast`, `bonsoir`, `url_launcher`. **None** is an ads,
analytics, telemetry, or crash-reporting SDK. Two are worth a one-line note for
reviewers:

- `crypto` computes the Subsonic/Navidrome `md5(password + salt)` token
  **locally on the device** — it has no network access of its own and sends
  nothing anywhere.
- `url_launcher` only opens an **external browser**, and only when the user
  explicitly taps "Open GitHub issue" in the bug-report flow. It collects
  nothing and auto-opens nothing.

If any future dependency adds ads/analytics/telemetry behavior, the Data Safety
form (and the privacy policy) must be updated.

## Before submitting — checklist

- [ ] Re-confirm no ads / analytics / crash SDK was added since this was
      written (check `pubspec.yaml`).
- [ ] Decide the "collection vs. user's own server" framing per Google's current
      definitions, and keep it consistent with the privacy policy.
- [ ] Answer "encrypted in transit" with the HTTPS qualification, not an
      unqualified yes.
- [ ] Describe the data-deletion options (sign out & clear, clear cache,
      uninstall).
- [ ] Provide the published **privacy policy URL** in the listing.

## Related docs

- [docs/privacy-policy.md](./privacy-policy.md) — must stay consistent with this
  form.
- [docs/play-store-readiness.md](./play-store-readiness.md) — overall readiness.
- [docs/dependency-license-audit.md](./dependency-license-audit.md) — dependency
  and anti-feature review.
</content>
