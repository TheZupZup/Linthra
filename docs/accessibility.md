# Accessibility

Linthra's primary accessibility target is **Android with TalkBack**. Linux gets
the same work for free wherever it comes from a shared widget, because Orca
reads the same semantics tree Flutter builds — but Android is the platform the
rules below are written against.

This doc has the rules the widgets rely on (so a change does not undo them by
accident), a **TalkBack smoke** for a phone, and a **Linux Orca smoke** for the
desktop build. Widget tests pin the tree; the checklists are the pass that has
to be listened to.

## The rules

**Audit before adding.** Flutter already exposes most of what a screen reader
needs. Wrapping a widget in `Semantics` that Flutter has already described is
how a control comes to say its own name twice. Check the tree first —
`tester.getSemantics(...)`, or `debugDumpSemanticsTree()` — and add only what is
genuinely missing.

**A tooltip is the accessible name of an icon-only button.** `IconButton`'s
`tooltip` becomes `SemanticsNode.tooltip`, which is
`AccessibilityNodeInfo.setTooltipText` on Android. Every icon-only control in
Linthra carries one, and there is nothing to add on top: a `Semantics(label:)`
beside it would be the same words a second time.

**State comes from the widget, not from prose.** `IconButton.isSelected` is
already exposed as the selected flag, so shuffle, repeat, favourite and the
accent swatches announce their state without help. A disabled control reports
disabled from `onPressed: null` for the same reason. The tooltip carries the
*state's wording* too ("Shuffle" vs "Shuffle on", "Favorite" vs "Remove from
favorites") so the two never disagree.

**Say a thing once.** Where a widget supplies its own label *and* has children
that repeat it, exclude the subtree — and re-declare the action, because
`excludeSemantics: true` drops the descendant `InkWell`'s tap along with its
text, which leaves a button a screen reader can name and cannot press.

**A progress indicator is silent unless you name it.** Flutter builds no
semantics node for a bare `CircularProgressIndicator`, so a blocking spinner
announces nothing at all and a loading screen is indistinguishable from an empty
one. Blocking, textless loads use
[`LoadingIndicator`](../lib/shared/widgets/loading_indicator.dart), which names
what is loading. A spinner that already has a caption beside it — "Connecting to
Living Room…", "Downloading… 40%" — stays silent on purpose, or the sentence is
read twice.

**Never speak a secret.** Tokens, passwords, authenticated stream URLs and local
file paths must not reach a label, value, hint or tooltip. Password fields are
`obscureText`, which keeps the typed value out of the semantics value as well as
off the screen. Server addresses and usernames *are* shown on connection forms
on purpose — the user typed them and has to be able to check them — so the line
is the credential, not the address.

## Real-device TalkBack smoke checklist

Widget tests pin the semantics tree; they cannot tell you whether the result is
pleasant to listen to, whether focus order makes sense in the hand, or whether a
gesture actually reaches a control. This is the pass that needs a phone.

**Setup.** Settings ▸ Accessibility ▸ TalkBack on. Swipe right/left to move
between controls, double-tap to activate, swipe up-then-right for the actions
menu. Explore-by-touch is worth using too: some problems only show up when a
finger lands in the middle of a row.

Roughly fifteen minutes end to end.

### Navigation

- ☐ Each bottom-bar destination announces its name, and the current one says
  **selected**.
- ☐ Moving between tabs announces the new screen rather than leaving you on a
  stale one.
- ☐ Back reaches the previous screen and focus lands somewhere sensible, not at
  the top of the page every time.

### Library

- ☐ A track row reads as **one** item: title, artist, and any status — not as
  three separate stops with the cover announced between them.
- ☐ A row that is playing says so; a downloaded row says downloaded; a row whose
  server is away says the server is unavailable, and a row saved offline says it
  still plays.
- ☐ The overflow menu is named, opens, and its items are all readable.
- ☐ Selection mode: a selected row says **selected**, an unselected one does not.
- ☐ While the library is still loading, something says **Loading your library**
  rather than the screen being silent.

### Now Playing

- ☐ Play/pause announces the action it will perform, and changes after it runs.
- ☐ Next and Previous are named, and say **disabled** at the ends of the queue.
- ☐ Shuffle says **selected** when on, and only then.
- ☐ Repeat distinguishes off / all / one, and says selected when active.
- ☐ Favourite says whether it will add or remove, and reports selected state.
- ☐ The seek bar is a slider: it reads a position, and swipe up/down moves it.
- ☐ Lyrics, sleep timer, queue and Cast are all named, and the ones that carry a
  state say it.

### Queue

- ☐ Each up-next row reads as one item.
- ☐ The row that is playing is identifiable by ear.
- ☐ **Move up** and **Move down** are offered in the actions menu (swipe up then
  right) and actually reorder the queue.
- ☐ Remove is named and works.

### Downloads

- ☐ An in-flight row says what it is doing and how far along it is.
- ☐ Retry and Cancel are named.
- ☐ A failed download says it failed rather than going quiet.

### Playlists

- ☐ A playlist row reads its name and track count as one item.
- ☐ Create, rename and delete are all reachable and named, and delete confirms.
- ☐ Reordering a playlist works through the actions menu.

### Settings

- ☐ Every switch reads its label and its on/off state, and toggling announces
  the change.
- ☐ The Settings hub's category rows are named.
- ☐ Sliders and pickers announce the value they land on.

### Onboarding

- ☐ Each source card reads its name and description **once**.
- ☐ Picking a source announces that it is setting up rather than going silent.
- ☐ Skip is reachable and named.

### Provider connection

- ☐ Server URL, username and password fields are each named.
- ☐ The password field does not read the typed characters back.
- ☐ Revealing the password is a named, deliberate action.
- ☐ A connection error is read out, and says nothing about a token.
- ☐ Sign out confirms first.

### The things worth failing a pass on

- Any control that announces nothing at all.
- Anything that says the same words twice in a row.
- A stateful control that sounds identical on and off.
- A screen that is silent while it loads.
- A token, password or full server URL spoken out loud.


## Linux Orca smoke checklist

Widget tests pin names, states and actions on the shared widgets. They cannot
tell you whether Orca reads those nodes in an order a person can follow,
whether the window itself is named, or whether a Flatpak sandbox left AT-SPI
silent. This is the pass that needs a real Linux session.

**Setup.** Orca is the screen reader this pass uses — it is the one a GNOME
install already has, and it runs on KDE Plasma too. Settings ▸ Accessibility ▸
Screen Reader, or `orca`. Caps Lock is the Orca modifier on a laptop layout;
Insert on a full keyboard.

Tab / Shift+Tab move between controls. Arrow keys move through lists and
grids. Enter or Space activates. Escape closes a dialog. There is no
explore-by-touch: if you cannot Tab to it, a keyboard user cannot reach it.

Run this against a native `flutter run -d linux` build first. A Flatpak that
is silent while the native window talks is a sandbox/AT-SPI issue, not a
missing label — file that separately rather than wrapping the widget.

Roughly fifteen minutes end to end.

### App identity

- ☐ Focusing the window, Alt+Tab, and the overview / task switcher all say
  **Linthra**, not "Flutter" or an empty caption. The runner sets
  `gtk_window_set_title` unconditionally — see
  [Desktop identity](./linux-desktop.md#desktop-identity).
- ☐ Shells that resolve an application id see `io.github.thezupzup.linthra`.

### Sidebar navigation

- ☐ Each rail destination — Library, Folders, Playlists, Downloads,
  Settings — announces its **name**, and the current one says **selected**.
- ☐ Tab walks the page first, then the whole rail in that order, not
  interleaved. Shift+Tab retraces. (Pinned by
  `home_shell_focus_order_test.dart`; this box is whether Orca says the
  same thing.)
- ☐ Moving to another destination announces the new screen.
- ☐ A source that is down is named (for example "Jellyfin unavailable") and
  can be activated to open connection settings. A healthy source stays
  quiet.
- ☐ A window narrowed past the rail breakpoint still names each bottom-bar
  destination.

### Library

- ☐ A track row reads as **one** item: title, artist, and any status.
- ☐ An album card reads as one item (title and artist together).
- ☐ Arrow keys move through the list / grid; Home and End reach the ends.
- ☐ The overflow / context menu is named, and its items are readable.
- ☐ While the library is loading, something says it is loading.

### Now Playing

- ☐ Play/pause, next, previous, shuffle, repeat and favourite are named, and
  their on / off or disabled states are audible.
- ☐ The seek bar is a slider: it reads a position, and the arrow keys move
  it while it is focused.
- ☐ Volume, when focused, announces its value. There is no global volume
  chord.

### Dialogs and connection management

- ☐ Opening a confirm dialog traps Tab inside it and gives focus back when
  it closes.
- ☐ Connection forms (Settings ▸ the provider) name server URL, username
  and password. The password field does not read the typed characters
  back.
- ☐ Revealing the password is a named, deliberate action.
- ☐ A connection error is read out and says nothing about a token.
- ☐ Sign out confirms first.

The separate server-management window is not part of this pass until it
exists. Use Settings' existing connection forms.

### Keyboard-only traversal

- ☐ The whole window is reachable without a pointer: page, rail,
  mini-player, queue column, dialogs.
- ☐ A focused control has a visible accent focus ring.
- ☐ Closing the queue column or a detail pane returns focus to the control
  that opened it.

The keyboard mechanics themselves are in
[linux-desktop.md](./linux-desktop.md#keyboard-navigation). This section is
whether those stops are *understandable* with the screen reader on.

### Desktop-specific limitations (not a fail)

- Orca on Flutter Linux speaks the AT-SPI tree the GTK embedder publishes.
  A custom-painted control that is a slider in the semantics tree may still
  sound generic compared with a GTK `GtkScale`.
- TalkBack swipe gestures do not exist here. If a control is only reachable
  by pointer, that is a fail of the keyboard pass, not of Orca.
- GNOME and KDE both run Orca; they do not have to sound identical. What
  has to match is that every named control above is reachable and named.
- Cast is contained on shipped builds — the sheet saying so must be named,
  and must not start listing devices.
- Tokens, passwords, authenticated stream URLs and local file paths must
  not be spoken. Server addresses and usernames on connection forms are
  shown on purpose.

### The things worth failing a pass on

Same as TalkBack, plus:

- A window that announces nothing when focused (empty caption).
- A rail destination with no name, or one that does not say selected when
  it is current.
- A Flatpak that is silent when the native build talks — file the sandbox,
  do not "fix" it by adding duplicate `Semantics` labels.

## Where the tests are

| Surface | Test |
| --- | --- |
| Library rows | `test/features/library/track_tile_semantics_test.dart` |
| Now Playing transport | `test/features/player/now_playing_talkback_test.dart` |
| Now-playing bar | `test/features/player/mini_player_semantics_test.dart` |
| Queue rows | `test/features/player/queue_sheet_test.dart` |
| Cast | `test/features/player/cast/cast_devices_semantics_test.dart` |
| Onboarding | `test/features/onboarding/onboarding_semantics_test.dart` |
| Accent swatches | `test/features/appearance/custom_theme_swatch_semantics_test.dart` |
| Loading states | `test/shared/widgets/loading_indicator_test.dart` |
| Folders ▸ Add folder | `test/features/library/folders_add_folder_test.dart` |
| Provider cards | `test/features/settings/source/provider_summary_card_semantics_test.dart` |
| Secrets, Plex | `test/features/settings/plex/plex_settings_secrets_semantics_test.dart` |
| Secrets, Jellyfin & Navidrome | `test/features/settings/provider_secrets_semantics_test.dart` |
| Desktop rail focus order | `test/features/shell/home_shell_focus_order_test.dart` |
| Sidebar source status | `test/features/shell/sidebar_source_status_test.dart` |
| Album cards | `test/features/library/album_grid_test.dart` |
| Keyboard seek | `test/features/player/wavy_seek_bar_keyboard_test.dart` |
| Window title / app id | `scripts/check_linux_runner.py` |
