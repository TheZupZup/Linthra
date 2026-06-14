# Manual Android QA checklist

Linthra's automated suite (`flutter test`) covers the logic seams — controllers,
repositories, resolvers, the cache policy, the media-browser tree, cast routing.
What it **can't** cover is the real device: the audio engine, the platform media
session, Chromecast on a LAN, Android Auto in a car/head-unit, and the SAF file
picker. This checklist is the human pass before cutting a sideloadable alpha.

Run it on a physical Android phone (not just an emulator) against a real Jellyfin
server and, where possible, a real Chromecast and an Android Auto head-unit (or
the Desktop Head Unit / Android Auto "developer" phone mode).

Legend: ☑ = verified on a real device for the current alpha · ☐ = re-verify each release.

---

## 0. Build & install

- ☐ `flutter build apk --debug` (or the release-signed APK) installs and launches.
- ☐ App icon and name (`Linthra`) appear correctly in the launcher.
- ☐ Settings ▸ About shows the **same** version as the installed build and the
  GitHub release tag (guarded by `app_info_version_test.dart`, but eyeball it).

## 1. Startup / lifecycle

- ☐ Cold start lands on the Library with no crash and no flash of error.
- ☐ Background the app during playback, return — playback continues, position is
  correct, the controller/engine were **not** recreated (audio doesn't restart).
- ☐ Kill the app from recents and reopen — it relaunches cleanly. *(Known
  limitation: the play queue/position is not restored across a kill — see
  "Known limitations".)*
- ☐ Returning to the foreground while casting re-syncs the shown position and
  never starts a second local stream.
- ☐ Screen-off / lock-screen playback survives a 5-minute screen-off for local,
  streaming, cached, and cast playback. See the dedicated checklist and battery
  troubleshooting in [background-playback.md](background-playback.md).

## 2. Library

- ☑ Local tracks appear after picking a folder (SAF) and a sync.
- ☑ Jellyfin tracks appear automatically after sign-in (no manual Sync needed).
- ☐ While that first sync runs, the empty Library shows "Your Jellyfin library
  is syncing" rather than the folder-pick prompt.
- ☐ Alphabet fast-scroller jumps to the right section and does not overlap rows
  or the overflow menu (narrow phones included).
- ☐ Row overflow menu (download / add to playlist / favorite / delete) works.
- ☐ Long titles/artists/albums ellipsize — no layout overflow on a narrow phone.
- ☐ Empty library shows the friendly empty state (not a spinner forever).
- ☐ A failed scan / sync shows a friendly, **token-free** error (no paths/SQL).

## 3. Playback

- ☑ Local file playback (play, pause, resume).
- ☑ Jellyfin direct streaming (first tap after launch streams without needing a
  prior download).
- ☐ Cached Jellyfin playback (download a track, go offline, it plays from cache).
- ☐ Switching tracks (tap another track replaces the queue from that point).
- ☐ Seek via the progress bar; position updates smoothly.
- ☑ Next / Previous (Previous restarts/steps back correctly).
- ☑ Shuffle on/off (current track keeps playing; up-next reorders).
- ☑ Repeat off → all → one (one loops without re-minting a stream each loop).
- ☐ Queue sheet (Now Playing → Queue) shows history, current, and live up-next;
  Clear empties up-next + history but keeps the current track playing.
- ☐ Play next / Add to queue (song ⋮ menu in Songs, Album, Artist, Playlist,
  Search) land in the right place and never restart the current track.
- ☐ Reorder an up-next track by its handle; remove one with ✕ (library + offline
  copy stay intact); tap an up-next/history row to jump there.
- ☐ Save queue as playlist creates a local playlist with the queue's songs.
- ☐ While casting, queue edits and "play now" never start audio on the phone.
- ☑ Mini-player shows on every tab, collapses when nothing is loaded, opens Now
  Playing on tap.
- ☑ Now Playing: artwork, metadata, source badge / casting indicator, controls.
- ☑ Background playback continues with the screen off.
- ☐ Media notification shows correct metadata + controls; lock-screen controls
  work; notification clears on stop.
- ☐ A failed stream shows a friendly error on Now Playing (not a raw exception).

## 3a. Bluetooth, wired & LE audio

Linthra drives all of this through the **standard Android `MediaSession` + audio
focus** (`audio_service` + `just_audio`) — there is no custom Bluetooth code (see
[audio-bluetooth-cpu-audit.md](audio-bluetooth-cpu-audit.md)). CI can't exercise a
real radio/headset/car, so verify on a device. Test what you have; mark the rest
N/A.

**Outputs — play/pause/next/previous/stop from the device's own buttons:**

- ☐ **Wired / no Bluetooth** (phone speaker or wired headset): play, pause, next,
  previous, stop all work; the wired in-line remote (if any) drives playback.
- ☐ **Classic Bluetooth headphones** (A2DP/AVRCP): connect, play; the headset's
  play/pause/next/previous work; track metadata (title/artist/album) shows on a
  headset/watch display that renders it.
- ☐ **Bluetooth speaker**: audio routes to the speaker; transport buttons (if the
  speaker has them) work.
- ☐ **Bluetooth car audio** *(if available)*: audio routes to the car; the head
  unit's Play/Pause/Next/Previous and steering-wheel buttons work; the car display
  shows title/artist/album (and artwork for Jellyfin tracks).
- ☐ **LE Audio device** *(if available, Android 13+/14+)*: pairs and plays as a
  media output; transport controls work the same as classic Bluetooth. (No
  LE-specific code — confirming standard routing is enough.)

**Metadata:**

- ☐ Title, artist, and album appear on the device/car where it renders them;
  **artwork** appears for Jellyfin tracks (token-free image URL) and is simply
  absent for local/Subsonic tracks (not a failure).
- ☐ Skipping a track updates the device's metadata to the new track (no stale
  title lingering).

**Disconnect / reconnect:**

- ☐ **Disconnect while playing** (turn the headset off / walk out of range):
  playback **pauses** (it must **not** keep blasting from the phone speaker) and the
  app does **not** crash.
- ☐ **Reconnect while paused**: reconnecting does **not** auto-start playback; the
  queue/current track/position are unchanged; pressing play resumes the same track.
- ☐ A phone call (or another media app) **pauses/ducks** Linthra and it resumes
  afterwards only if it was playing — it never double-starts.

**Lock screen / notification / Android Auto:**

- ☐ **Lock-screen controls** (play/pause/next/previous/seek) work; metadata +
  artwork show.
- ☐ **Notification controls** work; the notification clears on stop; Previous is
  hidden with no history and Next is hidden with nothing queued (no dead buttons).
- ☐ **Android Auto** *(if available)* — see §5 for the full pass; in particular
  confirm Bluetooth/steering-wheel Next/Previous reach the same session.

**Long-idle CPU / wake-ups** (the battery-relevant part — pairs with the cast
check in §4 #14b):

- ☐ **Screen-off playback ≥ 30 min** over Bluetooth (and again wired): music keeps
  playing without dropouts; afterwards *Settings → Battery → Linthra* (or
  `adb shell dumpsys batterystats`) shows CPU in line with audio decoding, with no
  excess background wake-ups.
- ☐ **Paused ≥ 30 min** (Bluetooth connected, screen off): Linthra's background CPU
  is **negligible** — confirming the position flush stopped on pause and nothing
  polls while idle. This is the key "no unnecessary polling/wake-ups" check.

## 3b. Server playback reporting (Now Playing on your server)

While a remote track plays, Linthra reports its playback to the server that
owns it — Plex timelines, Jellyfin play sessions, Subsonic/Navidrome
now-playing + scrobble. Reporting is best-effort: it must never affect
playback.

- ☐ Play a **Plex** track: the PMS dashboard shows Linthra under Now Playing;
  pause/resume update the entry; stop/skip clears it (unchanged from before).
- ☐ Play a **Jellyfin** track: the server dashboard shows Linthra as an active
  session with the playing item; pause shows paused; position advances on the
  ~10 s heartbeat; stop/skip clears the session.
- ☐ Play a **Navidrome (or other Subsonic)** track: the server's activity /
  `getNowPlaying` shows Linthra as the client; letting the track run past
  half (or 4 minutes) bumps its play count when it ends; skipping early does
  **not** count a play.
- ☐ Play a **local** track: no server traffic, nothing appears on any
  dashboard.
- ☐ Pause / resume / skip / stop across providers (including a queue mixing
  providers): each server only ever shows its own track, and the outgoing
  track's session closes on a cross-provider skip.
- ☐ Reporting failure is invisible: play a remote track, then cut the server
  off (stop the server or drop the tunnel) — playback of the already-started
  stream continues, pause/skip/stop still work, and no error surfaces. No log
  line contains a token (`adb logcat | grep -i linthra` spot-check).

## 4. Cast / Chromecast

Run the end-to-end pass in this order (a streamed track is required — local
files can't cast):

1. ☐ Start a **Jellyfin** (or Subsonic) track playing on the phone.
2. ☐ Open the cast sheet, discover, and **connect** to a real Chromecast.
3. ☐ Audio plays **on the receiver**.
4. ☐ Phone audio does **not** duplicate (no double sound).
5. ☐ The receiver (TV/display) shows **title, artist, and album** where the
   receiver renders them; the seek bar reflects the track **duration**.
6. ☐ **Artwork** appears for Jellyfin tracks (its cover art is a token-free URL);
   Subsonic tracks show no artwork by design (see the cast doc) — neither leaks a
   token.
7. ☐ Receiver **app branding**: with the *default* media receiver the device
   shows "Default Media Receiver" / the cast device name, **not** a Linthra
   name/logo. This is expected — true app branding needs a custom receiver app
   (see [cast.md](cast.md#receiver-app-name--logo-branding)). Do **not** fail the
   pass on this.
8. ☐ **Skip to next** track.
9. ☐ The receiver's metadata (title/artist/album/artwork/duration) **updates** to
   the new track, and position resets to 0 (no flash of the old track's
   progress).
10. ☐ **Background the app for ~5 minutes** while casting.
11. ☐ Cast **keeps playing** on the receiver throughout.
12. ☐ **Reopen** the app.
13. ☐ Now Playing/mini-player are **still in sync** with the receiver (position,
    track, casting indicator); no second local stream started.
14. ☐ Adjust the **Cast volume** slider / mute — it drives the *device* volume and
    follows the receiver's reported level; a fixed-volume device shows an honest
    disabled state.
14b.☐ **Cast-paused battery check**: start a track casting, then pause it. Turn
    the screen off for ≥ 5 minutes. Verify via *Settings → Battery → Linthra*
    (or `adb shell dumpsys batterystats`) that Linthra's background CPU use is
    negligible — confirming the 1 Hz poll stopped when paused (it must not
    wake the CPU every second while the session is idle).
15. ☐ **Disconnect** cast.
16. ☐ Local playback returns **paused** at the receiver's last position (never
    surprise-starts audio).
17. ☐ Throughout, **no token / authenticated URL** appears in the UI, in
    `adb logcat | grep -iE "api_key|AccessToken|Bearer"`, or in a saved
    diagnostics snapshot.

Additional cast checks:

- ☐ Play / pause / seek route to the receiver while connected.
- ☑ Cast icon/status is consistent between mini-player, Now Playing, and sheet.
- ☐ Casting a **local** file shows the friendly "streamed tracks only"
  limitation, leaving local playback untouched.
- ☐ Cast failure (Wi-Fi off, receiver gone) shows a friendly, token-free error.
- ☐ A dropped receiver (power it off mid-stream) returns the phone to a clear,
  **paused** state — it never restarts unexpectedly.
- ☐ Reconnecting after a disconnect re-casts the current track once (no duplicate
  local + cast audio).

## 5. Android Auto

- ☑ App appears in Android Auto after enabling "Unknown sources" in Android
  Auto developer settings.
- ☑ Browse tree is not empty (Library + Queue always present).
- ☐ Library node lists tracks; selecting one plays it.
- ☐ Queue node reflects the live queue.
- ☐ Playlists / Favorites nodes appear only when the user has some, and play.
- ☐ Play / pause / next / previous from the car controls work.
- ☐ **No token leaks**: with `adb logcat | grep Linthra.AndroidAuto`, only
  category labels + counts are logged — never a track id, URI, or token. Media
  ids/extras carry no token.
- ☐ No duplicate local playback if a Cast session is active.

## 6. Downloads / offline cache

- ☐ Manual download of a Jellyfin track shows progress, then "Downloaded".
- ☐ **Cancel mid-download** removes it and leaves no file (does not reappear as
  "Downloaded"). *(Regression-fixed this release.)*
- ☐ Remove offline copy deletes the managed file and updates usage.
- ☐ Cache limit: lots of downloads stay under the configured limit; a single
  track larger than the limit is refused with a friendly message.
- ☐ Cache usage display ("used of max") is plausible.
- ☐ "Keep offline" (pin) survives "Clear unpinned"; "Clear all" removes pinned
  too (after confirmation).
- ☐ Clear cache while a download is in flight leaves nothing resurrected.
  *(Regression-fixed this release.)*
- ☐ **Local source files are never deleted** by any cache action.
- ☐ Tokens / authenticated URLs never appear in the downloads UI or progress.
- ☐ **Wi-Fi only by default**: with **Allow mobile data** off, a download on
  mobile data is queued with a friendly "limited to Wi-Fi" message.
- ☐ Enabling **Allow mobile data** shows the confirmation dialog; allowing it
  lets the same download run over mobile data; cancelling leaves it off.
- ☐ The toggle persists across restart and stays in sync between the Downloads
  tab and **Settings → Downloads & network**.
- ☐ With mobile data allowed, the **cache size limit still applies** over LTE.

## 7. Smart pre-cache

- ☐ Disabled: nothing is pre-fetched as playback advances.
- ☐ Enabled: only the next small window (1/3/5/10) is warmed; not the whole
  library.
- ☐ Respects shuffle order and stays quiet under repeat-one.
- ☐ Respects the cache limit and the "Allow mobile data" setting.
- ☐ Never blocks or stutters what's playing.

## 7a. Remote prebuffer (in-memory stream-URL warming)

The remote playback cache warms the current + next remote stream URL into memory
so skips start faster (see [remote-playback-cache.md](remote-playback-cache.md)).
It is **not** the offline cache — no audio bytes and no stream URLs are written
to disk. A durable, credential-free **index** (`remote_cache/index.json`) does
persist *which* tracks were prepared (opaque key + timestamps only), so the
cache's knowledge survives a restart; it never holds a URL or token.

- ☐ Play a **Jellyfin** track; let it settle, then skip to the next — the next
  track starts quickly (no fresh buffering spinner before it begins).
- ☐ **Skip Jellyfin tracks quickly** (several in a row) — no crash, no audible
  stall on the track that finally lands, no doubled playback.
- ☐ Play a **Plex** track, then skip — same fast start (Plex benefits most: its
  resolution is a two-step metadata lookup).
- ☐ **Skip Plex tracks quickly** — stable.
- ☐ Play a **Subsonic/Navidrome** track, then skip — fast start.
- ☐ **Skip Subsonic/Navidrome tracks quickly** — stable.
- ☐ Play a **local file** and skip between local tracks — unaffected; local
  playback never uses the remote cache.
- ☐ Background / app-switch during remote playback, then return — playback
  continues; the controller/engine were not recreated.
- ☐ Lock-screen playback of a remote track behaves normally.
- ☐ Let a track sit paused past the warm TTL (~2 min) then resume/skip — it
  resolves a **fresh** URL (no failure from a stale/expired stream URL).
- ☐ Pull the network briefly during a skip — the skip may buffer, but playback
  never **fails because of** prebuffering, and recovers when the network returns.
- ☐ `adb logcat` during all of the above shows **no token / api_key / stream URL**
  from the prebuffer path (see §12).
- ☐ Play a remote track, then fully **kill and relaunch** the app — playback
  still works and the first remote play resolves a **fresh** URL (the index never
  replays a stored one, because it stores none).
- ☐ Pull the on-device manifest and confirm it is credential-free:
  `adb exec-out run-as io.github.thezupzup.linthra cat files/remote_cache/index.json`
  — it lists only opaque keys (`jellyfin:…` / `subsonic:…` / `plex:…`) and
  timestamps; **no token, api_key, stream URL, or artwork URL**.
- ☐ Play only **local** files across a restart — no `remote_cache/index.json` is
  created for them (local/`content://` tracks never touch the remote cache).
- ☐ With two remote providers connected (e.g. Jellyfin + Plex), play a few
  tracks from each, then **disconnect one** (Settings → that provider →
  disconnect / sign out). The manifest keeps the *other* provider's keys and
  drops the disconnected one's — `cat files/remote_cache/index.json` shows no
  `jellyfin:`/`subsonic:`/`plex:` keys for the provider you just disconnected.
- ☐ Disconnecting returns to the signed-out card immediately (the index cleanup
  never blocks or breaks sign-out).

## 8. Favorites

- ☐ Favorite / unfavorite a local track (persists across restart).
- ☐ Favorite / unfavorite a Jellyfin track (syncs to the server; heart matches
  the server after a refresh).
- ☐ Heart state is consistent between Library, Now Playing, and Favorites view.
- ☐ A failed server push keeps the optimistic local state.
- ☐ **Sign out of Jellyfin clears that account's synced hearts** (they don't
  linger, and don't cross over if you sign into a different account). On-device
  favorites are kept. *(Regression-fixed this release.)*

## 9. Lyrics

- ☐ Lyrics button opens the lyrics sheet without restarting playback.
- ☐ No-lyrics tracks show the calm empty state.
- ☐ Lyrics follow the current track (skipping reloads them; no stale lines).
- ☐ Synced lyrics highlight + auto-scroll with playback position.
- ☐ While casting, lyrics follow the **cast** position.

## 10. Playlists

- ☐ Create a playlist (local, and Jellyfin-synced when signed in).
- ☐ Add / remove tracks; "Add to playlist" reports the **actual** number added
  (duplicates already present are not counted). *(Fixed this release.)*
- ☐ Play a playlist (right tracks, right order, right start index).
- ☐ Delete a playlist asks for confirmation.
- ☐ Jellyfin playlist sync: create/add/remove propagate; offline edits show an
  honest "sync failed" status rather than a false success.
- ☐ Opening a deleted/missing playlist shows "Playlist not found", not a crash.

## 11. Settings

- ☐ Jellyfin connect: test, sign in, sign out & clear.
- ☐ **Auto-sync on connect**: signing in starts a sync on its own (card shows
  "Syncing your Jellyfin library…", then a summary). *(New this release.)*
- ☐ Closing/reopening Settings, or relaunching the app, does **not** start
  another full sync for the same account. *(New this release.)*
- ☐ Connecting a **different** server/user starts a fresh first sync.
- ☐ A failed first sync shows "Connected, but the library sync didn't finish."
  with a **Retry** that works. *(New this release.)*
- ☐ Subsonic/Navidrome connect: test, sign in, sign out & clear.
- ☐ Sign out resets the sync status line (no stale "Synced N tracks" after
  signing back in). *(Fixed this release.)*
- ☐ "Copy Jellyfin diagnostics" after a **failed** test of a different address
  does not report the previously-seen server. *(Fixed this release.)*
- ☐ **Diagnostics card**: "Copy diagnostics" copies the app snapshot to the
  clipboard and shows the "no passwords, tokens, or URLs" confirmation; pasting
  it shows app version, connection state, server **host only**, counts, and
  feature status — and **no** token, password, `Authorization` header, or full
  authenticated URL (see §12).
- ☐ "Save diagnostics" writes the same snapshot and confirms with a **redacted**
  location (basename only, never the private app directory path).
- ☐ Cache settings: change the limit (persists); clear cache (confirms first).
- ☐ Pre-cache settings: toggle + count persist.
- ☐ Version display matches the build; about/privacy links present.
- ☐ No dead buttons; no misleading status.

## 12. Security / privacy (spot-check)

- ☐ `adb logcat | grep -iE "api_key|AccessToken|Bearer"` during sign-in, sync,
  streaming, downloading, casting, and Android Auto browsing shows **no token**.
- ☐ Playback errors and UI status lines never show a token or full stream URL.
- ☐ No local source file is removed by any cache cleanup.

## 13. UI / UX consistency

- ☐ No layout overflow on a narrow phone (≤360dp wide).
- ☐ Bottom nav + mini-player never overlap content.
- ☐ Keyboard screens (server URL / sign-in) are usable; fields scroll into view.
- ☐ Dark theme is consistent; the violet + warm-orange palette is consistent.
- ☐ Loading / error / empty states are friendly everywhere.
- ☐ Destructive actions (delete playlist, clear cache) confirm first.

---

## Reporting a bug (for testers and users)

When something goes wrong, attach a diagnostics snapshot so it can be triaged
without a back-and-forth — and without you having to share anything sensitive.

**How to copy diagnostics**

1. Open **Settings ▸ Diagnostics**.
2. Tap **Copy diagnostics** (or **Save diagnostics** to write a
   `linthra-diagnostics.txt` file). A confirmation appears.
3. Paste it into your bug report.

The snapshot is **secret-free by design**: it carries the app version, Android
version and device model (when available), the Jellyfin/Subsonic connection
state and **server host only**, the library track count, cache used/limit, the
current playback output, the last safe error kind, and feature status (Cast,
Android Auto, offline cache, smart pre-cache). It **never** includes your
password, any token, an `Authorization` header, or a full authenticated URL — so
it is safe to paste into a public issue.

**What to include in a bug report**

- The pasted **diagnostics** snapshot (above).
- **What you did** — the exact steps to reproduce, in order.
- **What you expected** vs. **what happened**.
- **How often** it happens (every time / sometimes / once).
- Your **server type** (Jellyfin / Navidrome / Subsonic) if it's connection-,
  sync-, streaming-, or cast-related.
- A screenshot or screen recording if it's a UI/layout issue.

Please **do not** paste raw `logcat` output, your server URL with credentials,
or any token — the diagnostics snapshot already has the safe details needed.

---

## Known limitations (not bugs to fail the pass on)

- **Playback state is not restored after the app is killed** — reopening starts
  with an empty queue. (Background/return *is* preserved.)
- **Playlist rename/reorder are local-only** for Jellyfin-synced playlists; a
  later server refresh re-adopts the server's name/order.
- **A deleted Jellyfin-synced playlist can reappear** if the server delete failed
  (offline) and the server still has it — see the follow-up issues in the PR.
- **Lowering the cache limit doesn't immediately reclaim space**; usage settles
  as new downloads arrive. The "used of max" header can read over 100% until then.

See the PR description for the current list of fixed bugs and tracked follow-ups.
