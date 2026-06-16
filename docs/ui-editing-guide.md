# UI editing guide — the Now Playing screen

This guide is for the **maintainer** who wants to adjust how the Now Playing
screen looks — move a button, change spacing, swap an icon, retune the artwork
size — **without** wading through the playback, provider, or networking code.

Almost everything you'll want to change lives in one folder:

```
lib/ui_linthra/
```

> **The current design is the reference and is preserved.** The files in
> `lib/ui_linthra/` were filled in with the *exact* values the screen already
> uses, so nothing looks different until you change a number there.

---

## 1. Open the project on Windows

You need Flutter installed once. The short version:

1. **Install Git for Windows** — <https://git-scm.com/download/win>.
2. **Install the Flutter SDK** — follow
   <https://docs.flutter.dev/get-started/install/windows>. Linthra is pinned to
   the Flutter version in the repo's [`.flutter-version`](../.flutter-version)
   file; install that version to avoid spurious formatting diffs.
3. **Enable Windows desktop support** (so you can run the preview on your PC
   without an emulator):
   ```powershell
   flutter config --enable-windows-desktop
   ```
4. **Get an editor** — [VS Code](https://code.visualstudio.com/) with the
   *Flutter* extension is the easiest. Open the Linthra folder in it.
5. **Fetch dependencies** once, from the project folder in a terminal:
   ```powershell
   flutter pub get
   ```

You don't need an Android phone, an emulator, or any Plex/Jellyfin server to
edit and preview the UI — see [§9](#9-test-your-changes).

---

## 2. Where the Now Playing UI files are

| File | What you edit it for |
| --- | --- |
| `lib/ui_linthra/design_tokens.dart` | Sizes & numbers: artwork size, blur strength, corner radius, shadows, button/icon sizes, text weights, muted-text opacity. |
| `lib/ui_linthra/now_playing_layout_config.dart` | Spacing/gaps/paddings, every on-screen **word** (captions, tooltips, empty-state text), and the **text styles**. |
| `lib/ui_linthra/now_playing_actions_config.dart` | The bottom action row: **button order, which buttons appear, icons, labels**. |
| `lib/ui_linthra/now_playing_preview_data.dart` | The fake songs used by the preview (see [§9](#9-test-your-changes)). |
| `lib/app/colors.dart` | The brand colour palette (violet + orange). |

The actual screen widgets live in `lib/features/player/` and **read** their
numbers and words from the files above. You rarely need to open them.

---

## 3. Change the bottom button order (or hide/show a button)

Open **`lib/ui_linthra/now_playing_actions_config.dart`** and find
`nowPlayingActionOrder`:

```dart
const List<NowPlayingAction> nowPlayingActionOrder = <NowPlayingAction>[
  NowPlayingAction.favorite,
  NowPlayingAction.addToPlaylist,
  NowPlayingAction.queue,
  NowPlayingAction.lyrics,
  NowPlayingAction.sleepTimer,
  // NowPlayingAction.shuffle, // ← uncomment to add a shuffle toggle to the row
  // NowPlayingAction.repeat,  // ← uncomment to add a repeat toggle to the row
];
```

- **Reorder:** move the lines up or down. The row is laid out left → right in
  exactly this order.
- **Hide a button:** delete (or comment out with `//`) its line.
- **Show an optional button:** add (or uncomment) its line. `shuffle` and
  `repeat` are supported here too — they're already wired.

### Change a button's icon or label

In the same file, edit that action's entry in `nowPlayingActionStyles`. For
example, to give "Add to playlist" a different icon and tooltip:

```dart
NowPlayingAction.addToPlaylist: NowPlayingActionStyle(
  icon: Icons.library_add,        // was Icons.playlist_add
  label: 'Save to a playlist',    // was 'Add to playlist'
),
```

Icon names come from Flutter's built-in
[Material Icons](https://fonts.google.com/icons) — type `Icons.` in your editor
and it will suggest them.

You do **not** need to touch any playback code to do any of this — what each
button *does* stays wired in `lib/features/player/widgets/now_playing_actions.dart`.

---

## 4. Change spacing

Open **`lib/ui_linthra/now_playing_layout_config.dart`** → `NowPlayingLayout`.
The screen is three stacked bands (artwork · title/artist/album · controls), and
the gaps between them are named plainly:

```dart
static const double gapArtworkToMetadata = 32; // artwork → title block
static const double gapMetadataToControls = 24; // title block → controls
static const double gapControlsToActions = 16; // transport → bottom buttons
```

Make a gap bigger or smaller by changing its number (logical pixels). The outer
margins are right there too (`headerPadding`, `contentPadding`).

---

## 5. Change colors

The two-colour identity — violet **brand** + warm orange **accent** — lives in
**`lib/app/colors.dart`** (`AppColors`). For example, the play button and the
progress bar use the orange accent:

```dart
static const Color accent = Color(0xFFFF9F43);      // the live/accent orange
static const Color accentBright = Color(0xFFFFB867); // play-button gradient top
static const Color accentDeep = Color(0xFFF2861E);   // play-button gradient bottom
```

Colours are written as `Color(0xAARRGGBB)` (alpha, red, green, blue in hex). To
soften how strongly a colour shows on the Now Playing screen — without changing
the palette — adjust the opacities in `NowPlayingOpacityTokens`
(`design_tokens.dart`), e.g. how dim the album line or the resting action icons
are.

> Changing `AppColors` affects the **whole app**, not just Now Playing — that's
> intentional, so the brand stays consistent.

---

## 6. Change the artwork size, blur, corner radius, or shadow

Open **`lib/ui_linthra/design_tokens.dart`**.

```dart
// NowPlayingArtworkTokens
static const double maxWidth = 480;      // biggest the cover gets on tablets
static const double cornerRadius = 24;   // higher = rounder corners
static const double shadowBlur = 40;     // softness of the drop shadow

// NowPlayingBackgroundTokens
static const double blurStrength = 40;   // how blurred the backdrop artwork is
```

Each value has a comment explaining what it does and which direction makes it
bigger/softer/rounder.

---

## 7. Change the play button / transport / progress bar sizes

Also in **`design_tokens.dart`**:

```dart
// NowPlayingButtonTokens
static const double playButtonDiameter = 72; // the big round play/pause button
static const double skipIconSize = 38;        // previous / next
static const double modeIconSize = 24;        // shuffle / repeat
static const double actionIconSize = 22;      // the bottom action row

// NowPlayingProgressTokens
static const double trackHeight = 4;          // thickness of the progress bar
static const double thumbRadius = 6;          // the draggable dot
```

---

## 8. Change labels and text sizes

### Words

Open **`now_playing_layout_config.dart`** → `NowPlayingLabels`. Every visible
word is here:

```dart
static const String header = 'Now Playing';
static const String emptyTitle = 'Nothing playing';
static const String emptyMessage = 'Pick a track to start listening.';
```

### Text sizes / weights

In the same file, `NowPlayingTextStyles` builds each line's style. To make the
**title bigger**, swap which text-theme role it uses (or add an explicit
`fontSize`):

```dart
static TextStyle? title(ThemeData theme) =>
    theme.textTheme.headlineMedium?.copyWith( // was headlineSmall (bigger now)
      fontWeight: NowPlayingTypeTokens.titleWeight,
      letterSpacing: NowPlayingTypeTokens.titleLetterSpacing,
      height: NowPlayingTypeTokens.titleHeight,
    );
```

The weights and letter-spacing are tokens in `design_tokens.dart`
(`NowPlayingTypeTokens`) if you'd rather tune those.

---

## 9. Test your changes

### Preview with fake data (recommended — no server needed)

Run the **dev-only preview** of the Now Playing screen. It uses fake songs, so
you don't need Plex, Jellyfin, or Navidrome connected:

```powershell
flutter run -t lib/ui_linthra/preview/now_playing_preview_main.dart
```

- A dropdown at the top flips between sample states — different providers,
  paused / buffering / error, a long title, and the no-artwork fallback.
- After editing a file in `lib/ui_linthra/`, press **`r`** in the terminal for
  **hot reload** to see the change instantly (or **`R`** for a full restart).
- Add your own samples by editing `lib/ui_linthra/now_playing_preview_data.dart`.

You can run the preview on **Windows desktop** (`flutter run -d windows -t …`)
or on an Android device/emulator if you have one.

### Run the automated checks before committing

These are the same checks CI runs:

```powershell
flutter analyze   # static analysis / lints
flutter test      # widget & unit tests
```

The Now Playing widget tests (`test/features/player/player_screen_test.dart`)
assert the screen's labels, tooltips, icons, and behaviour — so if a change
accidentally breaks the design contract, these will tell you.

---

## 10. What **not** to edit (unless you're changing playback behaviour)

These files hold **logic**, not look. Leave them alone for visual tweaks — and
changing them can affect playback, providers, security, or tokens:

| Don't edit for UI changes | Why |
| --- | --- |
| `lib/features/player/player_providers.dart` | Wires playback, resolvers, caching, reporting. |
| `lib/core/services/**` (e.g. `*_playback_controller.dart`, `playable_uri_resolver*.dart`) | The audio engine and how a track becomes a playable URL. |
| `lib/core/sources/**` (jellyfin / plex / subsonic / local) | Provider logic, sessions, and tokens. |
| `lib/core/services/playback_source_label.dart` | The safe "Playing from …" naming (never exposes a URL/token). |
| `lib/features/player/cast/**` | Cast logic. |
| `lib/features/player/*_providers.dart`, `sleep_timer_controller.dart`, `lyrics_*` | Favorites, lyrics, sleep-timer behaviour. |

The widgets in `lib/features/player/widgets/` are the *rendering* of the screen.
They now read their values from `lib/ui_linthra/`, so for look-and-feel changes
you should edit the config there, not the widgets. Reach into a widget only when
you need to change **structure** (add/remove an element), not spacing, sizes,
icons, labels, or button order.

---

## Quick reference

| I want to… | Edit |
| --- | --- |
| Reorder / hide / show bottom buttons | `now_playing_actions_config.dart` → `nowPlayingActionOrder` |
| Change a button's icon or label | `now_playing_actions_config.dart` → `nowPlayingActionStyles` |
| Change spacing / gaps / margins | `now_playing_layout_config.dart` → `NowPlayingLayout` |
| Change on-screen words | `now_playing_layout_config.dart` → `NowPlayingLabels` |
| Change text size / weight | `now_playing_layout_config.dart` → `NowPlayingTextStyles` |
| Change artwork size / blur / radius / shadow | `design_tokens.dart` → `NowPlayingArtworkTokens` / `NowPlayingBackgroundTokens` |
| Change button / progress sizes | `design_tokens.dart` → `NowPlayingButtonTokens` / `NowPlayingProgressTokens` |
| Change colours | `lib/app/colors.dart` |
| Preview without a server | `flutter run -t lib/ui_linthra/preview/now_playing_preview_main.dart` |
