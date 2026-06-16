/// # Now Playing action-row config
///
/// The bottom action row on the Now Playing screen — favorite · add to playlist
/// · queue · lyrics · sleep timer — is driven entirely by this file. Reorder,
/// hide, show, re-label, or re-icon the buttons here; you never have to touch the
/// playback or provider code to do it.
///
/// The split:
///  - **What the row contains and in what order** → [nowPlayingActionOrder].
///  - **How each button looks (icon + words)** → [nowPlayingActionStyles].
///  - **What each button *does* (the wiring)** → stays in the widget
///    `lib/features/player/widgets/now_playing_actions.dart`. You almost never
///    need to open it.
///
/// ## Reorder the buttons
/// Move the lines in [nowPlayingActionOrder] up or down. The row is laid out
/// left → right in exactly this order.
///
/// ## Hide a button
/// Delete (or comment out) its line in [nowPlayingActionOrder].
///
/// ## Show an optional button
/// Add (or uncomment) its line. `shuffle` and `repeat` normally live in the
/// transport row above, but are fully supported here too — uncomment them in the
/// order list and they appear in the action row, already wired.
///
/// ## Change an icon or label
/// Edit that action's entry in [nowPlayingActionStyles].
library;

import 'package:flutter/material.dart';

/// Every action the bottom row knows how to show. Adding the id to
/// [nowPlayingActionOrder] makes it appear; removing it hides it.
enum NowPlayingAction {
  /// Heart the current track (synced to Jellyfin for remote tracks, on-device
  /// for local ones).
  favorite,

  /// Open the "add to playlist" sheet for the current track.
  addToPlaylist,

  /// Open the up-next queue.
  queue,

  /// Open the lyrics sheet for the current track.
  lyrics,

  /// Open the sleep-timer picker.
  sleepTimer,

  /// Toggle shuffle. Normally shown in the transport row; optional here.
  shuffle,

  /// Cycle repeat off → all → one. Normally shown in the transport row; optional
  /// here. (Its glyph and tooltip change with the mode, handled by the widget.)
  repeat,
}

/// Which brand colour a button lights up with when it is "on". Buttons that
/// never toggle use [none] and stay the calm resting tint.
enum NowPlayingActionTint {
  /// Never highlights (it is a momentary action, not a toggle).
  none,

  /// Lights up violet (the app's primary identity colour) when active. Used by
  /// favorite and the sleep timer.
  brand,

  /// Lights up warm orange (the "live" accent) when active. Used by shuffle and
  /// repeat, matching the transport row.
  accent,
}

/// The look of a single action button: its resting glyph and word, the glyph and
/// word to swap in while it is "on" (for toggles), and which colour it lights up.
@immutable
class NowPlayingActionStyle {
  const NowPlayingActionStyle({
    required this.icon,
    required this.label,
    this.activeIcon,
    this.activeLabel,
    this.tint = NowPlayingActionTint.none,
  });

  /// The glyph shown at rest.
  final IconData icon;

  /// The tooltip / accessibility label shown at rest.
  final String label;

  /// The glyph to swap in while the button is "on". Null for buttons whose glyph
  /// doesn't change (the same icon is reused).
  final IconData? activeIcon;

  /// The tooltip to swap in while the button is "on". Null reuses [label].
  final String? activeLabel;

  /// The colour the button takes while "on" (see [NowPlayingActionTint]).
  final NowPlayingActionTint tint;
}

/// The default order and contents of the bottom action row, left → right.
///
/// This is the one obvious knob for the row. Reorder by moving lines; hide by
/// removing a line; show an optional button by uncommenting its line.
const List<NowPlayingAction> nowPlayingActionOrder = <NowPlayingAction>[
  NowPlayingAction.favorite,
  NowPlayingAction.addToPlaylist,
  NowPlayingAction.queue,
  NowPlayingAction.lyrics,
  NowPlayingAction.sleepTimer,
  // NowPlayingAction.shuffle, // ← uncomment to add a shuffle toggle to the row
  // NowPlayingAction.repeat,  // ← uncomment to add a repeat toggle to the row
];

/// The look of each action. Edit an entry to change that button's icon or words;
/// the wiring (what it does on tap) is unaffected.
const Map<NowPlayingAction, NowPlayingActionStyle> nowPlayingActionStyles =
    <NowPlayingAction, NowPlayingActionStyle>{
  NowPlayingAction.favorite: NowPlayingActionStyle(
    icon: Icons.favorite_border,
    activeIcon: Icons.favorite,
    label: 'Favorite',
    activeLabel: 'Remove from favorites',
    tint: NowPlayingActionTint.brand,
  ),
  NowPlayingAction.addToPlaylist: NowPlayingActionStyle(
    icon: Icons.playlist_add,
    label: 'Add to playlist',
  ),
  NowPlayingAction.queue: NowPlayingActionStyle(
    icon: Icons.queue_music_outlined,
    label: 'Queue',
  ),
  NowPlayingAction.lyrics: NowPlayingActionStyle(
    icon: Icons.lyrics_outlined,
    label: 'Lyrics',
  ),
  NowPlayingAction.sleepTimer: NowPlayingActionStyle(
    icon: Icons.bedtime_outlined,
    activeIcon: Icons.bedtime,
    label: 'Sleep timer',
    activeLabel: 'Sleep timer (on)',
    tint: NowPlayingActionTint.brand,
  ),
  NowPlayingAction.shuffle: NowPlayingActionStyle(
    icon: Icons.shuffle,
    label: 'Shuffle',
    activeLabel: 'Shuffle on',
    tint: NowPlayingActionTint.accent,
  ),
  NowPlayingAction.repeat: NowPlayingActionStyle(
    icon: Icons.repeat,
    // While repeating one track the widget swaps in this glyph; "repeat all"
    // keeps the plain glyph above. The mode-specific tooltip is derived in the
    // widget.
    activeIcon: Icons.repeat_one,
    label: 'Repeat',
    tint: NowPlayingActionTint.accent,
  ),
};
