/// # Now Playing layout config
///
/// This is the "where things sit and what they say" file for the Now Playing
/// screen. It turns the raw numbers in `design_tokens.dart` into named layout
/// values (paddings, the gaps between the three bands, the source-line spacing)
/// and gathers every visible word and the few decorative icons in one place.
///
/// The screen is grouped into three calm bands, top to bottom:
///
/// ```
///  ┌───────────────── header ─────────────────┐  ← close · "Now Playing" · cast
///  │                                           │
///  │            ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓                │  ← album artwork  (band 1)
///  │            ▓▓▓ artwork ▓▓▓                │
///  │            ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓                │
///  │                                           │
///  │                Song title                 │  ← title / artist / album
///  │                  Artist                   │     (band 2)
///  │                  Album                     │
///  │                                           │
///  │             Playing from Plex             │  ← source · progress · transport
///  │   ──────────●──────────────────────────   │     (band 3)
///  │   ⤮   ⏮      ▶      ⏭   ⟳                 │
///  │   ♥   ＋   ☰   ✎   ☾                      │  ← bottom action row
///  └───────────────────────────────────────────┘
/// ```
///
/// Editing tips:
///  - To change a **gap or margin**, edit the matching value below.
///  - To change a **word** (caption, tooltip, empty-state copy), edit
///    [NowPlayingLabels].
///  - To change **text weight / size**, edit [NowPlayingTextStyles] (and the
///    weight/spacing tokens it reads from in `design_tokens.dart`).
library;

import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Paddings, band gaps, and the small internal spacings of the Now Playing
/// screen. Values mirror the app's base spacing scale (`AppSpacing`): xs = 4,
/// sm = 8, md = 16, lg = 24, xl = 32.
abstract final class NowPlayingLayout {
  // ── Outer frame ──────────────────────────────────────────────────────────

  /// Padding around the header row (close · caption · cast).
  static const EdgeInsets headerPadding = EdgeInsets.symmetric(
    horizontal: 4, // AppSpacing.xs
    vertical: 4, // AppSpacing.xs
  );

  /// Padding around the main content (everything below the header). A tighter
  /// side margin lets the artwork breathe wider; the larger bottom keeps the
  /// action row off the screen edge.
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(
    16, // left  — AppSpacing.md
    8, // top   — AppSpacing.sm
    16, // right — AppSpacing.md
    24, // bottom— AppSpacing.lg
  );

  // ── Gaps between the three bands ───────────────────────────────────────────

  /// Space between the album artwork and the title block.
  static const double gapArtworkToMetadata = 32; // AppSpacing.xl

  /// Space between the title block and the live controls (source/progress/
  /// transport).
  static const double gapMetadataToControls = 24; // AppSpacing.lg

  /// Space between the transport controls and the bottom action row.
  static const double gapControlsToActions = 16; // AppSpacing.md

  // ── Inside the metadata block ──────────────────────────────────────────────

  /// Space between the title and the artist line.
  static const double gapTitleToArtist = 8; // AppSpacing.sm

  /// Space between the artist and the album line.
  static const double gapArtistToAlbum = 4; // AppSpacing.xs

  // ── Inside the live-controls block ─────────────────────────────────────────

  /// Space between the "Playing from …" source line and the progress bar.
  static const double gapSourceToProgress = 16; // AppSpacing.md

  /// Space between the progress bar and the transport row.
  static const double gapProgressToTransport = 8; // AppSpacing.sm

  /// Space between the progress track and the elapsed / remaining time row.
  static const double gapProgressToTimes = 4; // AppSpacing.xs

  /// Space between the source glyph and its "Playing from …" text.
  static const double gapSourceIconToText = 6; // AppSpacing.xs + 2
}

/// Every visible word on the Now Playing screen, plus the handful of purely
/// decorative icons (the ones that are *not* tappable actions — those live in
/// `now_playing_actions_config.dart`).
abstract final class NowPlayingLabels {
  /// The calm eyebrow caption centered in the header.
  static const String header = 'Now Playing';

  /// Tooltip on the collapse (down-chevron) button.
  static const String closeTooltip = 'Close';

  /// The chevron used to collapse the screen.
  static const IconData closeIcon = Icons.keyboard_arrow_down;

  /// Empty state shown when nothing is loaded.
  static const IconData emptyIcon = Icons.music_note_outlined;
  static const String emptyTitle = 'Nothing playing';
  static const String emptyMessage = 'Pick a track to start listening.';

  /// Shown (with a small spinner) during a mid-stream re-buffer.
  static const String buffering = 'Buffering…';

  /// Shown when playback fails but no specific reason was reported.
  static const String genericError = "Couldn't play this track";

  /// The "Casting to …" indicator. The glyph sits before the device name.
  static const IconData castingIcon = Icons.cast_connected;
  static String casting(String deviceName) => 'Casting to $deviceName';
}

/// The resolved text styles for the metadata block, header, source label, and
/// time readouts. Each is built from a role in the app's [TextTheme] (so it
/// follows the global type ramp) plus the finishing touches in
/// [NowPlayingTypeTokens] / [NowPlayingOpacityTokens].
///
/// To make a line **bigger or smaller**, change which `textTheme` role it reads
/// (e.g. swap `headlineSmall` → `headlineMedium` for a larger title), or add an
/// explicit `fontSize:` to the `copyWith` below. Everything stays in this one
/// spot — no need to open the widget files.
abstract final class NowPlayingTextStyles {
  /// Song title — the heaviest line, the hero of the text block.
  static TextStyle? title(ThemeData theme) =>
      theme.textTheme.headlineSmall?.copyWith(
        fontWeight: NowPlayingTypeTokens.titleWeight,
        letterSpacing: NowPlayingTypeTokens.titleLetterSpacing,
        height: NowPlayingTypeTokens.titleHeight,
      );

  /// Artist — the clear secondary line.
  static TextStyle? artist(ThemeData theme) =>
      theme.textTheme.titleMedium?.copyWith(
        color: theme.colorScheme.onSurface
            .withValues(alpha: NowPlayingOpacityTokens.artist),
        fontWeight: NowPlayingTypeTokens.artistWeight,
      );

  /// Album — the quietest line.
  static TextStyle? album(ThemeData theme) =>
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface
            .withValues(alpha: NowPlayingOpacityTokens.album),
        letterSpacing: NowPlayingTypeTokens.albumLetterSpacing,
      );

  /// The "Now Playing" header caption.
  static TextStyle? header(ThemeData theme) =>
      theme.textTheme.labelLarge?.copyWith(
        fontWeight: NowPlayingTypeTokens.headerWeight,
        letterSpacing: NowPlayingTypeTokens.headerLetterSpacing,
        color: theme.colorScheme.onSurface
            .withValues(alpha: NowPlayingOpacityTokens.header),
      );

  /// The "Playing from …" source caption.
  static TextStyle? source(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(
        fontWeight: NowPlayingTypeTokens.sourceWeight,
        letterSpacing: NowPlayingTypeTokens.sourceLetterSpacing,
        color: theme.colorScheme.onSurfaceVariant,
      );

  /// The elapsed / remaining time readouts under the progress bar. Uses tabular
  /// figures so the digits don't jitter as the time ticks.
  static TextStyle? time(ThemeData theme) =>
      theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: NowPlayingTypeTokens.timeLetterSpacing,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );
}
