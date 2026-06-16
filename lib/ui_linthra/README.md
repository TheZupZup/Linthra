# `lib/ui_linthra/` — the Now Playing design surface

This folder is the **maintainer-friendly home for the Now Playing screen's
look**. Everything you'd normally want to tweak — spacing, the album-art size,
blur strength, corner radius, button sizes, text sizes, the bottom button
order, icons, and labels — lives here in plain, heavily-commented Dart, so you
can adjust the design without reading the playback, provider, or networking
code.

> **The current Now Playing design is the reference and is preserved.** These
> files were filled in with the *exact* values the screen already uses, so
> nothing changes until you change a number here.

## What's in here

| File | Edit it to change… |
| --- | --- |
| [`design_tokens.dart`](design_tokens.dart) | Raw numbers: artwork size, blur strength, corner radius, shadows, button & icon sizes, text weights, and the opacity of muted text. |
| [`now_playing_layout_config.dart`](now_playing_layout_config.dart) | Where things sit (paddings, the gaps between the three bands), every on-screen **word**, and the assembled **text styles**. |
| [`now_playing_actions_config.dart`](now_playing_actions_config.dart) | The bottom action row: **button order**, which buttons show, and each button's icon + label. |
| [`now_playing_preview_data.dart`](now_playing_preview_data.dart) | The fake tracks/states used by the dev preview. |
| [`preview/`](preview/) | The dev-only preview app (see below). Not part of the shipping app. |

## Preview the screen with fake data (no server needed)

You can see the real Now Playing screen — with fake songs, different providers,
paused/buffering/error states, long titles, and the no-artwork fallback —
without connecting Plex, Jellyfin, or Navidrome:

```bash
flutter run -t lib/ui_linthra/preview/now_playing_preview_main.dart
```

Use the dropdown at the top to flip between samples. Edit any file in this
folder and **hot-reload** (press `r`) to see your change instantly.

## How the design connects to the widgets

The widgets in `lib/features/player/` (the actual screen) read their numbers,
words, and styles from this folder. For example, the album-art corner radius in
`player_screen.dart` comes from `NowPlayingArtworkTokens.cornerRadius`, and the
bottom button order comes from `nowPlayingActionOrder`. You change the value
here; the widget picks it up.

The **wiring** (what a button does, how playback works, how providers resolve a
song) deliberately stays in `lib/features/player/` and `lib/core/`. You almost
never need to open those to retune the look.

See [`docs/ui-editing-guide.md`](../../docs/ui-editing-guide.md) for a friendly,
step-by-step guide (including how to open the project on Windows and exactly
which lines to edit for common changes).
