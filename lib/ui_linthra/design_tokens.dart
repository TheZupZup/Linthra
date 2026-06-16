/// # Now Playing design tokens
///
/// Every tunable *number* that shapes the Now Playing screen lives here, grouped
/// by what it controls. Change a value, hot-reload (or rebuild), and the screen
/// updates — you should never have to read the playback or provider code to
/// retune the look.
///
/// What is **not** here:
///  - **Colours** — the brand violet / warm orange palette lives in
///    `lib/app/colors.dart` (`AppColors`). This file only holds the *opacities*
///    used to soften those colours (see [NowPlayingOpacityTokens]).
///  - **Spacing / gaps / paddings** — those are assembled, with names that say
///    where they sit, in `now_playing_layout_config.dart`.
///  - **Button order / icons / labels** — those live in
///    `now_playing_actions_config.dart`.
///
/// These are plain `const` values, so they are baked in at build time and cost
/// nothing at runtime.
library;

import 'package:flutter/material.dart';

/// The album cover "hero" at the top of the screen — its size, rounding, and the
/// soft drop shadow that lifts it off the blurred background.
abstract final class NowPlayingArtworkTokens {
  /// Largest the cover is allowed to get, in logical pixels. Phones fill the
  /// available width; tablets/foldables stop here so the cover stays a square
  /// album, not an oversized panel. Increase for a bigger hero on large screens.
  static const double maxWidth = 480;

  /// Cover shape. 1 = a perfect square (the album-cover look). Values > 1 make it
  /// wider than tall; < 1 makes it taller than wide.
  static const double aspectRatio = 1;

  /// Corner rounding of the cover, in logical pixels. Higher = rounder corners.
  /// (Matches the app's large radius, `AppRadii.lg`.)
  static const double cornerRadius = 24;

  /// The drop shadow under the cover. Together these read as a soft, lifted card.
  ///  - [shadowOpacity]  how dark the shadow is (0 = none, 1 = solid black).
  ///  - [shadowBlur]     how soft/spread the shadow edge is (higher = softer).
  ///  - [shadowSpread]   negative pulls the shadow *in* so it hugs the cover.
  ///  - [shadowOffset]   how far the shadow falls; `(0, 20)` = straight down 20px.
  static const double shadowOpacity = 0.4;
  static const double shadowBlur = 40;
  static const double shadowSpread = -12;
  static const Offset shadowOffset = Offset(0, 20);
}

/// The full-screen backdrop: a heavily blurred copy of the artwork (or a calm
/// brand gradient when there is no artwork) under a darkening scrim that keeps
/// the title, slider, and controls readable.
abstract final class NowPlayingBackgroundTokens {
  /// Blur strength of the artwork backdrop, in logical pixels. Higher = dreamier
  /// and less detailed; lower lets more of the cover show through. 0 = no blur.
  static const double blurStrength = 40;

  /// The darkening scrim laid over the backdrop, from the top of the screen to
  /// the bottom. Each value is how much of the surface (background) colour is
  /// mixed in at that point — higher = darker / more opaque. The bottom is the
  /// most opaque so the controls sit on a calm, legible base.
  static const double scrimTopOpacity = 0.30;
  static const double scrimMidOpacity = 0.70;
  static const double scrimBottomOpacity = 0.92;

  /// Where along the top→bottom run each scrim stop sits (0 = very top,
  /// 1 = very bottom). Keep this the same length as the three opacities above.
  static const List<double> scrimStops = <double>[0.0, 0.55, 1.0];

  /// The fallback gradient shown when a track has no artwork: a whisper of the
  /// brand violet at the top-left and the warm accent at the bottom-right, over
  /// the surface colour. These are how strongly each brand colour tints the
  /// surface (0 = invisible, 1 = full strength).
  static const double fallbackBrandTint = 0.32;
  static const double fallbackAccentTint = 0.12;
  static const List<double> fallbackStops = <double>[0.0, 0.55, 1.0];
}

/// Sizes for the two button rows: the transport row (shuffle · previous ·
/// play/pause · next · repeat) and, just below it, the secondary action row
/// (favorite · playlist · queue · lyrics · sleep timer).
abstract final class NowPlayingButtonTokens {
  /// Icon size of every button in the bottom **action** row, in logical pixels.
  static const double actionIconSize = 22;

  /// Icon size of the shuffle and repeat buttons that flank the transport row.
  /// Kept smaller than the skip buttons so they read as secondary.
  static const double modeIconSize = 24;

  /// Icon size of the previous / next (skip) buttons.
  static const double skipIconSize = 38;

  /// The dominant play/pause button — the one bold, "this is the music" moment.
  ///  - [playButtonDiameter] the size of the round button, in logical pixels.
  ///  - [playIconSize]       the play/pause glyph inside it.
  ///  - [playSpinnerSize]    the loading spinner shown while a track resolves.
  ///  - [playSpinnerStroke]  thickness of that spinner.
  static const double playButtonDiameter = 72;
  static const double playIconSize = 40;
  static const double playSpinnerSize = 26;
  static const double playSpinnerStroke = 2.5;

  /// The warm glow under the play button. Same idea as the artwork shadow:
  /// opacity (how strong), blur (how soft), spread (negative hugs the button),
  /// and offset (how far it falls).
  static const double playGlowOpacity = 0.45;
  static const double playGlowBlur = 24;
  static const double playGlowSpread = -4;
  static const Offset playGlowOffset = Offset(0, 8);
}

/// The seekable progress bar and the small source/label glyphs around it.
abstract final class NowPlayingProgressTokens {
  /// Thickness of the progress track, in logical pixels.
  static const double trackHeight = 4;

  /// Radius of the draggable thumb on the progress bar.
  static const double thumbRadius = 6;

  /// Radius of the soft halo that appears around the thumb while dragging.
  static const double overlayRadius = 12;

  /// Icon size of the small "Playing from …" / buffering / casting glyph shown
  /// just under the metadata.
  static const double sourceIconSize = 15;

  /// Reserved height (in logical pixels) for the source line while a track is
  /// still resolving, so the layout never jumps when the label appears.
  static const double sourceLineReservedHeight = 22;
}

/// Type *weight and shape* for the title / artist / album block and the header
/// caption. The base font **sizes** come from the app's text theme (see
/// `now_playing_layout_config.dart`, where each style is assembled); these are
/// the finishing touches layered on top.
abstract final class NowPlayingTypeTokens {
  /// Title (song name): bold, very slightly tightened, with snug line spacing,
  /// wrapping to at most two lines before it ellipsises.
  static const FontWeight titleWeight = FontWeight.w700;
  static const double titleLetterSpacing = -0.2;
  static const double titleHeight = 1.15;
  static const int titleMaxLines = 2;

  /// Artist: a clear secondary line, medium weight.
  static const FontWeight artistWeight = FontWeight.w500;

  /// Album: the quietest line, with a touch of letter spacing.
  static const double albumLetterSpacing = 0.1;

  /// The "Now Playing" caption in the header: a calm, tracked eyebrow.
  static const FontWeight headerWeight = FontWeight.w600;
  static const double headerLetterSpacing = 1.0;

  /// The "Playing from …" source label: a confident small caps-y caption.
  static const FontWeight sourceWeight = FontWeight.w600;
  static const double sourceLetterSpacing = 0.2;

  /// The elapsed / remaining time labels under the progress bar.
  static const double timeLetterSpacing = 0.4;
}

/// How strongly the calmer elements are dimmed. Every value is an *opacity*
/// applied to a theme colour (almost always `onSurface`): 0 = invisible,
/// 1 = full strength. Nudging these is the easiest way to make the screen feel
/// quieter or more present without touching the palette in `app/colors.dart`.
abstract final class NowPlayingOpacityTokens {
  /// The header caption ("Now Playing") and its close affordance.
  static const double header = 0.7;

  /// The resting tint of the bottom action-row icons (before any light up).
  static const double action = 0.7;

  /// The artist line.
  static const double artist = 0.75;

  /// The album line (the faintest text on the screen).
  static const double album = 0.5;

  /// Shuffle / repeat when they are *off* (they switch to a solid accent on).
  static const double inactiveMode = 0.65;

  /// The unfilled remainder of the progress track.
  static const double inactiveProgressTrack = 0.15;
}
