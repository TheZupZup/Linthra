import 'package:flutter/material.dart';

import '../../app/colors.dart';
import '../../app/dimens.dart';

/// The soft, light palette for Linthra's immersive player + lyrics surfaces.
///
/// The rest of the app is dark-first; these two screens deliberately switch to a
/// calm, premium light system because a "music-first" now-playing reads better
/// light and airy. The identity is a **soft lavender** brand kept deliberately
/// light and unsaturated (calming, never heavy), with a **warm soft orange**
/// reserved for playback, progress, and key actions. Secondary text and inactive
/// controls fall back to a muted gray so the colour stays purposeful.
abstract final class PlayerPalette {
  /// The base surface: a very light, warm-leaning lavender white.
  static const Color background = Color(0xFFFAF6FB);

  /// A pale lavender used low in the background gradient for a soft, breathable
  /// fade.
  static const Color backgroundLow = Color(0xFFF1EBF7);

  /// Slightly lifted surface for sheets and cards over [background].
  static const Color surface = Color(0xFFFFFFFF);

  /// Soft lavender-gray container fill for the rounded transport buttons and the
  /// lyrics segmented control.
  static const Color container = Color(0xFFECE5F2);

  /// A touch deeper than [container] for selected/pressed tonal surfaces.
  static const Color containerHigh = Color(0xFFE3D9EE);

  /// Primary text/icon ink — a deep plum-charcoal, high-contrast on the light
  /// surfaces for strong readability.
  static const Color ink = Color(0xFF2B2733);

  /// Muted gray for secondary text (artist line, captions) and inactive
  /// controls.
  static const Color inkMuted = Color(0xFF7C7689);

  /// Softer gray for dimmed-but-legible content (inactive lyric lines).
  static const Color inkFaint = Color(0xFFB3ADC0);

  /// Hairline outlines / dividers.
  static const Color hairline = Color(0xFFE9E1F1);

  /// Soft lavender — Linthra's main brand colour, kept light and unsaturated so
  /// the player feels calm and premium rather than heavy. Used for identity
  /// moments: favorite, casting, the active lyrics segment, the ambient halo.
  static const Color brand = Color(0xFF8E76D8);

  /// Warm, soft orange — the "live" accent, reserved for playback, progress, and
  /// key actions (play/pause, the seek waveform, active shuffle/repeat).
  static const Color accent = Color(0xFFF4A258);

  /// Dark, warm ink for an icon sitting on the orange accent (the play button),
  /// where white would wash out against the warm fill.
  static const Color onAccent = Color(0xFF3A2410);
}

/// Builds the locally-scoped soft-light [ThemeData] for the now-playing and
/// lyrics screens.
///
/// Scoped with a `Theme` wrapper on just those screens, so the dark app shell is
/// untouched. Call sites read `colorScheme.primary` for the lavender brand and
/// `colorScheme.secondary` for the warm playback accent, exactly as the rest of
/// the app does, so widgets stay token-driven.
abstract final class PlayerTheme {
  static final ThemeData light = _build();

  static ThemeData _build() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: PlayerPalette.brand,
      brightness: Brightness.light,
    ).copyWith(
      primary: PlayerPalette.brand,
      onPrimary: Colors.white,
      secondary: PlayerPalette.accent,
      onSecondary: PlayerPalette.onAccent,
      surface: PlayerPalette.background,
      onSurface: PlayerPalette.ink,
      onSurfaceVariant: PlayerPalette.inkMuted,
      surfaceContainerLowest: PlayerPalette.background,
      surfaceContainerLow: PlayerPalette.surface,
      surfaceContainer: PlayerPalette.container,
      surfaceContainerHigh: PlayerPalette.container,
      surfaceContainerHighest: PlayerPalette.containerHigh,
      outline: PlayerPalette.hairline,
      outlineVariant: PlayerPalette.hairline,
      error: AppColors.error,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: PlayerPalette.background,
      splashFactory: InkSparkle.splashFactory,
      iconTheme: const IconThemeData(color: PlayerPalette.ink),
      // Sheets opened from the player (queue, sleep timer, add-to-playlist)
      // inherit this captured theme, so they stay cohesive with the light
      // surface rather than flashing the dark app theme.
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: PlayerPalette.surface,
        modalBackgroundColor: PlayerPalette.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.lg),
          ),
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: PlayerPalette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.md)),
        ),
      ),
    );
  }
}
