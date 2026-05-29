# Linthra Privacy Policy

> **Draft for review.** This is a draft privacy policy for Linthra. It is
> written to be honest about how the current app behaves, but it has **not** been
> legally reviewed. Review it for accuracy against the shipped build, and have it
> reviewed as appropriate, before publishing it at a public URL and linking it
> from a Google Play listing. See
> [docs/play-store-readiness.md](./play-store-readiness.md).

_Last updated: see this file's git history._

## Overview

Linthra is an **open-source Android music player**. It is licensed under the
Mozilla Public License 2.0 and its source code is public at
<https://github.com/thezupzup/linthra>.

In plain terms:

- Linthra **does not include ads**.
- Linthra **does not sell your data**.
- Linthra **does not intentionally track you**. There is no analytics,
  telemetry, or crash-reporting SDK in the app.
- Linthra **does not operate a central cloud service**. There is no Linthra
  account and no Linthra server. The app talks only to the music sources **you**
  configure (such as your own Jellyfin server) and to your own local files.

Because Linthra has no backend, most of your data simply never leaves your
device unless **you** point the app at a server you control.

## What data Linthra handles, and where it is stored

All of the following is stored **locally on your device**. None of it is sent to
the Linthra project or to any third party operated by us.

### Server connection details (only if you connect a server)

If you choose to connect Linthra to a self-hosted music server —
[Jellyfin](https://jellyfin.org/) or Navidrome / Subsonic — the app stores what
it needs to keep you signed in:

- the **server URL** you entered;
- your **username** (as returned by the server) and the server's identifying
  details;
- a **session credential**: a **session token** for Jellyfin, or a
  `salt`+`token` pair for Navidrome / Subsonic.

These are stored together in the device's **encrypted** secure storage
(Android Keystore-backed), so the session credential is not kept in plaintext.

Your **password is never stored.** How it is used depends on the server type:

- **Jellyfin:** the password is sent once to your server to obtain a session
  token, then discarded from memory.
- **Navidrome / Subsonic:** the password is used **only on your device** to
  compute a `salt`+`token` (`token = md5(password + salt)`); the plaintext
  password is not sent to the server and is then discarded.

This information is used **only** to talk to the server you configured. Linthra
does not transmit it anywhere else.

### Music library metadata

Metadata about your music (track, album, and artist information from your local
folders and/or your Jellyfin library) may be stored in a **local database on
your device** so the app can show your library quickly and work offline. This
data stays on the device.

### Offline cache and downloads

Tracks you explicitly download, and tracks the app pre-caches to play smoothly,
are stored as files in Linthra's **local storage on your device**, within a
size limit you control. Downloads are always **user-initiated** — Linthra does
not silently download your library. Downloads and pre-caching use **Wi-Fi only
by default**; an optional "Allow mobile data" setting lets them use mobile data
once you opt in.

### App settings

Your preferences (such as the selected local music folder, cache size limit, and
download settings) are stored locally on the device using standard Android
preference storage.

## Network activity

Linthra makes network connections only in these situations, all under your
control:

- **Talking to your music server.** When you have configured a server (Jellyfin
  or Navidrome / Subsonic), Linthra contacts **that server** (and only that
  server) to test the connection, sign in, sync your library, stream music, and
  download tracks you request. If your server uses **HTTPS**, this traffic is
  **encrypted in transit**; whether HTTPS is used is determined by **your**
  server configuration.
- **Casting to a device on your local network.** When you choose to cast,
  Linthra discovers and communicates with Cast/Chromecast-compatible devices on
  your **local network**. This uses a local-network protocol implementation and
  does **not** route your media through any Linthra or Google cloud service for
  this purpose.

Linthra does **not** phone home, upload your library, or send usage data
anywhere.

## Diagnostics and bug reports

Linthra can generate a diagnostic / bug report to help fix problems
(**Settings → Report a bug**, or **Settings → Diagnostics**). This is always on
your terms:

- The report is **generated on your device** and shown to you to review first.
- It is **secret-free by construction**: it never includes your password, a
  session token, or a full server URL — only app/OS versions, connection state,
  the server **host**, counts, feature flags, and (if you opt in) a few
  structural app events such as lifecycle transitions and playback-error kinds.
- **Nothing is sent automatically.** There is no backend and no upload to any
  third party or AI service (including Claude/OpenAI/Anthropic). You choose
  whether to copy it, save it, or open a prefilled GitHub issue.
- **"Open GitHub issue"** simply opens your browser at a prefilled — but
  **unsubmitted** — issue on the project's GitHub. Linthra uses **no GitHub
  token** and posts nothing on your behalf; you review and submit it yourself.

Please still review a report before sharing, and don't paste secrets into the
free-text fields.

## Permissions

Linthra requests a minimal set of Android permissions, each tied to a feature:

- **Internet** — to reach the Jellyfin server you configure and to run a Cast
  session. Without a configured server, the app does not need to use the
  network for its local-first features.
- **Foreground service / media playback** — to keep audio playing in the
  background and show media controls in the notification and on the lock screen.
- **Notifications** (Android 13+) — to show the media-playback notification and
  its controls. If you deny it, playback still works without the notification.
- **Local-network multicast** — to discover Cast/Chromecast devices on your
  local network when you choose to cast.

Linthra does **not** request broad storage ("all files") access. Access to your
local music folder uses Android's Storage Access Framework, where **you** pick
the folder to grant.

## Your choices and control

- You can **sign out** of a Jellyfin server in Settings, which clears the saved
  server details and session token from the device ("Sign out & clear").
- You can **clear the offline cache** (downloaded and pre-cached tracks) in
  Settings.
- You can **uninstall** Linthra, which removes the app's locally stored data
  from your device per Android's normal app-removal behavior.

## Children's privacy

Linthra is a general-purpose music player and is not directed at children. It
does not knowingly collect personal information from anyone, as it has no
backend that collects data.

## Changes to this policy

Because Linthra is open source, changes to data handling are visible in the
project's source history. If this policy changes, the updated version will be
published in the repository and at the URL linked from any store listing.

## Contact / reporting a security issue

Linthra is a community open-source project. For questions about this policy, or
to report a privacy or security issue, please open an issue (or use any security
reporting mechanism provided) on the project's GitHub repository:

- **GitHub:** <https://github.com/thezupzup/linthra/issues>

Please do not include secrets (such as passwords or tokens) in a public issue.
</content>
