# Google Play review notes (app access)

> **Draft for review.** This document helps fill Google Play's **App access**
> section and gives a reviewer everything they need to evaluate Linthra
> **without** any account or server we operate. It makes **no** claim that
> Linthra is on Google Play (it is not, and no submission has been made). See
> [docs/play-store-readiness.md](./play-store-readiness.md), especially
> [§13 App access](./play-store-readiness.md#13-play-console-declarations-to-prepare-category-target-audience-app-access).

## The one thing to know first

**Linthra has no Linthra account and no Linthra login gate.** There is no
sign-up, no "create account," and no server operated by the Linthra project. The
core app — pick a music folder, scan it, browse, play, queue, background
playback, Android Auto, cast — works with **no login at all**.

So in the Play Console **App access** section, the honest answer is:

> **All functionality is available without special access.**

The optional server connection (below) is a sign-in to **the user's own**
self-hosted server, not to anything we run, so it is not an access restriction a
reviewer needs credentials from us to get past.

## Testing Linthra with no server (recommended for review)

This exercises the local-first core and needs **no network and no account**:

1. Install and open the app.
2. When prompted (Android 13+), allow the **notification** permission so the
   media notification can appear. (Denying it still lets playback work, just
   without the notification.)
3. Go to the library / folder picker and **choose a folder that contains audio
   files** using the system folder picker (Android's Storage Access Framework —
   Linthra requests **no** broad "all files" storage permission; the reviewer
   grants access to one folder).
   - If the test device has no music on it, copy a few audio files (e.g. some
     Creative Commons MP3s) to the device first, then pick that folder.
4. Linthra **scans** the folder and lists **Songs / Albums / Artists**; use the
   search field to filter.
5. Tap a track to play. Verify:
   - playback, the **Now Playing** screen, and transport controls;
   - the **media notification** and lock-screen controls;
   - **background playback** continues with the app backgrounded / screen off;
   - queue / Up Next actions (play next, add to queue, reorder).

> **Note on local files (current alpha behaviour):** local tracks currently
> display by **file name**; reading embedded tags and album art from local files
> is still on the roadmap. This is expected, not a bug.

## What the optional server login is (and is not)

Linthra can **optionally** connect to a **self-hosted music server that the user
already runs** — **Jellyfin** or **Navidrome / Subsonic**. When a user connects
one:

- They enter **their own** server URL and sign in with **their own** account on
  **that** server.
- This is **not** a Linthra account. Linthra operates no server and issues no
  credentials. It is the same idea as a generic mail app signing in to a mail
  server the user chose.
- The password is used **once** to obtain a session token (Jellyfin) or to
  derive a Subsonic/Navidrome `salt`+`token` locally; the password is **not
  stored**, and the session credential is kept in encrypted on-device storage.
  See [docs/privacy-policy.md](./privacy-policy.md) and
  [docs/play-store-data-safety.md](./play-store-data-safety.md).

Features that **require** a configured self-hosted server (because they stream
from / sync with it): server library browsing, server streaming, server-backed
playlists/favourites sync, and downloading tracks from the server for offline
play. **None of these are needed to review the app** — the local-first flow
above covers installation, playback, notification, background playback, and
Android Auto.

## Do reviewers need demo credentials?

**No demo credentials are required to review Linthra**, because the full
local-playback experience works without any server. **The Linthra project does
not run a public demo server**, and we do not ship credentials in the app or this
repository.

If a reviewer wants to additionally evaluate **server streaming/sync**, the app
maintainer can provide a **disposable test account on a server they control**, in
the Play Console **App access instructions** field only (never committed to the
repo). A suitable template to paste there:

```
Linthra works fully with LOCAL files and needs no account to review:
  1. Open the app, allow the notification permission.
  2. Pick a folder containing audio files (system folder picker / SAF).
  3. The library lists Songs/Albums/Artists; tap a track to play.
  4. Verify the media notification, lock-screen controls, and background
     playback (screen off).

OPTIONAL — server streaming (not required to review):
  Settings -> connect a server -> Jellyfin (or Navidrome/Subsonic).
  This signs in to the USER'S OWN self-hosted server; there is no Linthra
  account. Test server URL / username / password (disposable, throwaway):
    URL:      <fill in here, in the Console only>
    Username: <fill in here, in the Console only>
    Password: <fill in here, in the Console only>
```

> **Never** put a real server URL, username, password, or token in this repo or
> any doc. Use a throwaway test account on a server you control, entered only in
> the Play Console. If you cannot or do not want to stand up a test server,
> that is fine — say so in the App-access notes and point the reviewer at the
> local-file flow above.

## Permissions a reviewer will see (and why)

A short rationale; the full table is in
[docs/play-store-readiness.md §12](./play-store-readiness.md#12-permissions-review).

| Permission | Why |
| ---------- | --- |
| Notifications (Android 13+) | Show the media-playback notification and controls. Optional — denial only hides the notification. |
| Foreground service / media playback | Keep audio playing in the background. |
| Internet | Reach the **user-configured** server and run a Cast session. Not used for the local-first features. |
| Local-network multicast | Discover Cast/Chromecast devices on the local network when the user chooses to cast. |

No storage/media permission is requested — local folder access uses the Storage
Access Framework folder the user picks. Cast uses a pure-Dart implementation, not
Google Play Services. See
[docs/play-store-data-safety.md](./play-store-data-safety.md).

## Related docs

- [docs/play-store-readiness.md](./play-store-readiness.md) — overall readiness,
  app-access declaration, permissions.
- [docs/play-store-listing.md](./play-store-listing.md) — store listing copy.
- [docs/play-store-data-safety.md](./play-store-data-safety.md) — Data Safety
  form prep.
- [docs/privacy-policy.md](./privacy-policy.md) — privacy policy draft.
