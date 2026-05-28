# Android Auto

How Linthra integrates with Android Auto, why a sideloaded build may not appear
at first, how to test it on a real head unit or the Desktop Head Unit, and how to
troubleshoot.

> TL;DR — the most common reason Linthra "doesn't show up in Android Auto" is
> **not a bug in Linthra**: Android Auto hides media apps that were not installed
> from the Play Store until you enable **Developer mode → Add unknown sources**
> in the Android Auto settings. Linthra ships via F-Droid / GitHub Releases, so
> a sideloaded build is invisible to Android Auto until that toggle is on. See
> [Troubleshooting → "Linthra doesn't appear"](#linthra-doesnt-appear).

## Current status

| Capability | Status |
| --- | --- |
| Listed as an Android Auto **media app** | ✅ (manifest + automotive descriptor; needs "unknown sources" for sideloaded builds — see below) |
| Browsable tree (Library / Queue / Playlists / Favorites) | ✅ |
| Play a track from the car; queue the rest | ✅ |
| Transport controls (play / pause / next / previous / seek) | ✅ |
| Hardware / steering-wheel / Bluetooth Next / Previous | ✅ (same media session) |
| Lock-screen / notification Next / Previous | ✅ |
| Now-playing **queue / Up Next** on the head unit | ✅ (mirrors the app's queue) |
| Tap a row in the car's Up Next list (skip-to-queue-item) | ✅ |
| Shuffle / repeat from the car | ✅ |
| Now-playing metadata (title / artist / album / artwork) | ✅ (artwork depends on `Track.artworkUri`) |
| Cast-safe (no duplicate local playback while casting) | ✅ |
| Search from Android Auto | ❌ (not implemented) |
| Album / artist / folder grouping in the car | ❌ (flat lists) |
| Custom car screens / content-style hints | ❌ (intentionally — safe browsing only) |

Linthra exposes a **standard `MediaBrowserService` + media session** via the
[`audio_service`](https://pub.dev/packages/audio_service) plugin. There is no
custom car UI and no driving-distraction surface: Android Auto renders the
browse tree and the now-playing card from the media session, which is the safe,
recommended model for a media app.

## How it works (architecture)

- `android/app/src/main/AndroidManifest.xml` declares:
  - the `com.ryanheise.audioservice.AudioService` service with
    `foregroundServiceType="mediaPlayback"`, `android:exported="true"`, and the
    `android.media.browse.MediaBrowserService` intent-filter that Android Auto
    binds to;
  - the `com.ryanheise.audioservice.MediaButtonReceiver` for hardware /
    Bluetooth / Android Auto media-button intents;
  - the `com.google.android.gms.car.application` meta-data pointing at
    `res/xml/automotive_app_desc.xml`, which declares `<uses name="media" />` —
    this is what makes Android Auto treat Linthra as a media app.
- `android/app/.../MainActivity.kt` extends `AudioServiceActivity` (not the
  plain `FlutterActivity`) so the Flutter activity binds to the session.
- `lib/main.dart` calls `connectMediaSession(...)` **before** `runApp(...)`, so
  the handler registers as the app's `main()` runs. When Android Auto starts the
  service cold (app never opened in this process), the same `main()` runs and the
  browse tree is answerable from the persisted catalog/playlists/favourites — it
  does **not** wait for any phone screen to be built.
- `lib/core/services/media_browser_tree.dart` (`MediaBrowserTree`) is **pure
  Dart**: it builds the browse tree from the `MusicLibraryRepository`, a
  `PlaybackState` snapshot, and (when wired) the `PlaylistRepository` /
  `FavoritesRepository`. No `audio_service` type and no widget dependency, so it
  is fully unit-tested.
- `lib/core/services/linthra_audio_handler.dart` (`LinthraAudioHandler`) is the
  only file that imports `audio_service`. It maps `MediaNode`s to media items,
  forwards transport commands to the single `PlaybackController`, and turns a
  selected item into a `PlaybackController.playTracks(...)` call. It also mirrors
  the controller's queue out as the session's **Up Next** list and maps a tapped
  queue row (`skipToQueueItem`) back onto the controller's history / up-next
  jumps — so the car's queue stays in sync and is navigable without the handler
  ever touching `just_audio` or the cast SDK.

### Transport controls & hardware buttons

The car's Next / Previous / Play / Pause — whether tapped on the head-unit
screen, pressed on the steering wheel, or sent over Bluetooth / a wired headset
— all arrive as the same media-session callbacks (`onSkipToNext`,
`onSkipToPrevious`, `onPlay`, …). audio_service forwards them to
`LinthraAudioHandler`, which calls the matching `PlaybackController` method
(`skipToNext`, `skipToPrevious`, `play`, `pause`, `seek`, `skipToQueueItem`).
There is no separate Android-Auto playback path: the car drives the **same**
controller as the in-app player, so playback, queue, history, shuffle, and
repeat stay consistent however you press a button.

- The handler advertises the transport capabilities it implements (skip,
  skip-to-queue-item, seek, shuffle, repeat) **steadily** in `systemActions`, so
  a head unit that caches the capability set when it connects keeps its
  Next / Previous and queue-row buttons live regardless of where you are in the
  queue.
- The **visible** notification / lock-screen buttons are still gated: the
  `skipToPrevious` button only appears once a previous track exists and
  `skipToNext` only while one is queued, so no dead button is ever shown.
- At a queue boundary (Next on the last track, Previous on the first) the action
  is a safe no-op — the queue and the now-playing state are left untouched.
- Previous always steps to the previous track (it does not restart the current
  track first); there is no "double-press to go back" behaviour.

### Browse tree

```
root
├── Library    → every catalog track
├── Queue      → current track + up-next (only populated while something plays)
├── Playlists  → your playlists (only shown when you have some)
│   └── <playlist> → that playlist's tracks
└── Favorites  → your favourited tracks (only shown when you have some)
```

Stable media IDs:

| Node | ID form |
| --- | --- |
| Library category | `library` |
| Library track | `library/<trackId>` |
| Queue category | `queue` |
| Queue item | `queue/<index>` |
| Playlists category | `playlists` |
| A playlist | `playlist/<playlistId>` |
| Playlist track | `playlist/<playlistId>/<index>` |
| Favorites category | `favorites` |
| Favorite track | `favorite/<index>` |

`Playlists` and `Favorites` only appear when you actually have some, so the car
never shows an empty dead-end. A favourite / playlist track id that isn't in the
on-device catalog yet is skipped (it can't be played until synced).

## Security / token notes

Android Auto media items are deliberately **secret-free**:

- A media item's **id** is built only from opaque catalog/track/playlist ids and
  small integer indices — never a Jellyfin/Subsonic access token or an
  authenticated stream URL.
- `Track.uri` is the opaque `jellyfin:<id>` / `subsonic:<id>` scheme (or a local
  file/SAF path), not a stream URL. The **authenticated stream URL is minted
  lazily at play time** by the resolver inside the playback engine, and is never
  stored on a track or handed to the media browser.
- `MediaItem.artUri` (cover art) is the **token-free** image endpoint for
  Jellyfin, and `null` for Subsonic/local — so no credential rides along in
  artwork either.
- The diagnostic log (see below) prints only the **category** of a media id
  (e.g. `library`, `playlist`, `favorite`) and small counts — never a raw id,
  title, URI, or token.

## Diagnostics / logging

Because Android Auto visibility can't be asserted in CI, the integration logs a
small, secret-free trace under the `Linthra.AndroidAuto` tag. View it while
testing:

```sh
adb logcat | grep Linthra.AndroidAuto
```

You should see, in order:

- `media session attached (Android Auto browser ready)` — `AudioService.init`
  succeeded. If you instead see `media session init failed: <Type>`, the media
  session never attached (so the app won't appear / won't browse) — investigate
  that first.
- `browse: root -> N children` — Android Auto bound and requested the root. If
  you never see a `browse:` line after connecting, Android Auto isn't binding
  (usually the "unknown sources" gate — see troubleshooting).
- `browse: library -> N children` — a category was opened; `N` tells you whether
  the catalog is populated.
- `play: library resolved=true` — a selection resolved to something playable.

## Build / install

```sh
flutter pub get
flutter build apk --debug      # or: flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Then **open Linthra once on the phone** and (if you use Jellyfin/Navidrome) sign
in and let the library sync. The Android Auto browse tree reads the **persisted**
on-device catalog, so it is empty until the app has synced at least once.

## Testing

### A) Desktop Head Unit (DHU) — no car required

The DHU is Google's official Android Auto emulator and is the fastest way to
verify the browse tree and playback from a desk.

1. Install **Android Auto** on the phone (Play Store) or use a phone with it
   built in.
2. On the phone: open Android Auto settings → tap the **version** ~10 times to
   unlock **Developer mode** → in the overflow menu enable **Add unknown
   sources** (required so a sideloaded Linthra is listed) and **Start head unit
   server**.
3. On the computer: install the **Desktop Head Unit** from the Android SDK
   (`Android SDK → extras → Android Auto Desktop Head Unit emulator`, binary at
   `$ANDROID_SDK/extras/google/auto/desktop-head-unit`).
4. Connect the phone by USB, enable USB debugging, then run:
   ```sh
   adb forward tcp:5277 tcp:5277
   $ANDROID_SDK/extras/google/auto/desktop-head-unit
   ```
5. In the DHU, open the **media app launcher** and confirm **Linthra** is listed.
   Open it, browse **Library / Playlists / Favorites**, play a track, and test
   the transport controls.

Reference: <https://developer.android.com/training/cars/testing/dhu>

### B) Real car / head unit

Use the [manual checklist](#manual-checklist) below. You still need Developer
mode → **Add unknown sources** enabled for a sideloaded build.

## Manual checklist

1. Build and install the debug or release APK (see [Build / install](#build--install)).
2. **Open Linthra once on the phone.**
3. Sign in / sync Jellyfin or Navidrome if you use one (so the catalog persists).
4. Enable Android Auto **Developer mode → Add unknown sources** (sideloaded builds).
5. Connect the phone to Android Auto (USB or wireless) — or start the DHU.
6. Open the Android Auto **app launcher / media list**.
7. Confirm **Linthra appears**.
8. Open Linthra.
9. Browse **Library** (and **Playlists** / **Favorites** if you have any).
10. Play a track — confirm it starts and the rest of the list becomes up-next.
11. Press the car / head-unit **Next** — confirm Linthra skips to the next track.
12. Press the car / head-unit **Previous** — confirm it goes to the previous
    track (it steps back; it does not restart the current track first).
13. Press **Play / Pause** — confirm the play state stays in sync both ways.
14. Open the car's **Up Next** list and tap a row — confirm playback jumps to it.
15. Test **shuffle / repeat** from the car.
16. **Lock the phone screen** and press car **Next** — confirm music keeps
    playing and skips correctly (no drop-out during the track change).
17. If you have a steering wheel or **Bluetooth** remote / headset, test its
    **Next / Previous / Play-Pause** — they should drive Linthra too.
18. Reopen Linthra on the phone — confirm it shows the **correct current track**
    after using the car controls.
19. Disconnect and reconnect — confirm the app still appears and resumes.
20. With a **Cast** session active, select a track (and press Next) from Android
    Auto and confirm **no duplicate audio starts on the phone** (it follows the
    receiver).
21. Skim `adb logcat | grep Linthra.AndroidAuto` — confirm **no tokens or
    authenticated stream URLs** appear (only category labels and counts).

## Troubleshooting

### Linthra doesn't appear

1. **Enable "unknown sources" (most common fix).** Android Auto only lists
   Play-Store media apps unless you turn on Developer mode → **Add unknown
   sources**. Linthra is sideloaded (F-Droid / GitHub Releases), so this is
   required. Steps: Android Auto settings → tap **Version** ~10× → overflow menu
   → **Developer settings** → enable **Add unknown sources** → fully restart
   Android Auto (or reconnect).
2. **Open Linthra once on the phone** after installing, so the app and its media
   service have run at least once.
3. **Confirm the session attached:** `adb logcat | grep Linthra.AndroidAuto`
   should show `media session attached`. If it shows `media session init
   failed`, the media session isn't starting — that's the blocker.
4. **Re-install and reconnect.** Android Auto caches its media-app list; toggling
   the connection or restarting Android Auto refreshes it.

### Library (or a category) is empty

- The browse tree reads the **persisted** catalog. Open Linthra on the phone and
  let it scan a local folder and/or sync your Jellyfin/Navidrome library first.
- `Playlists` / `Favorites` only show when you have some; a favourite or playlist
  track that hasn't been synced to the on-device catalog is skipped.
- Check `adb logcat | grep Linthra.AndroidAuto` for `browse: library -> 0
  children` — that confirms the bind works but the catalog is empty.

### Playback controls don't work

- Confirm `play: <category> resolved=true` appears in the log when you tap a
  track. `resolved=false` means a stale id resolved to nothing (re-open the
  category to refresh).
- On Android 13+, the media notification (and some controls) require the
  `POST_NOTIFICATIONS` runtime permission — grant it when prompted on first
  launch, or in system app settings.

### Cast vs Android Auto

- When a **Cast** session is active, Android Auto's transport and track
  selection are routed to the **single `PlaybackController`**, which has
  suspended the local engine for the duration of the cast session. So selecting
  a track or pressing play from the car updates the queue and the **cast
  receiver** plays it — the phone does **not** start a second, duplicate stream.
- Ending the cast session returns playback to the phone **paused** at the
  receiver's last position, so nothing surprise-starts.

## Known limitations

- **Sideloaded builds need "unknown sources"** (see above) — a device setting,
  not something Linthra can change.
- The browse tree is **flat**: no album/artist/folder grouping and no
  search-from-Auto; large libraries are not paged.
- The now-playing **Up Next** list mirrors the app's queue and you can tap a row
  to jump to it, but you **can't reorder or remove** queue items from the car
  (do that in the app). The browsable **Queue** category is likewise read + jump.
- **Previous** always steps to the previous track; there's no restart-then-go-back
  (single vs. double press) behaviour some apps use.
- Next on the last track / Previous on the first is a **no-op**; Next does not
  wrap to the start even with repeat-all on (only auto-advance at end-of-track
  wraps).
- The car experience is **basic browsing**, not a custom/polished car UI (no
  tabs, content-style hints, lyrics, or now-playing artwork tuning).
- Lock-screen / car artwork depends on `Track.artworkUri`; local-folder scanning
  does not populate it yet.
- No MPRIS (Linux desktop media keys) yet.
