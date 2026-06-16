import 'package:flutter/material.dart';

import '../../app/colors.dart';
import '../../app/dimens.dart';

/// The warm, soft-light palette for Linthra's immersive player + lyrics
/// surfaces.
///
/// The rest of the app is dark-first; these two screens deliberately switch to
/// a calm, premium cream/blush light system (see [PlayerTheme]) because a
/// "music-first" now-playing reads better light and airy. Brand identity is
/// kept through the violet primary and the warm "live" accent — here the accent
/// is usually derived from the album art (highlights only), falling back to
/// [fallbackAccent] when there is no artwork.
abstract final class PlayerPalette {
  /// The base surface: a warm off-white the artwork sits on.
  static const Color background = Color(0xFFFBF6F1);

  /// A pale blush used low in the background gradient for subtle warmth.
  static const Color blush = Color(0xFFF6E7E0);

  /// Slightly lifted surface for sheets and cards over [background].
  static const Color surface = Color(0xFFFFFBF7);

  /// Soft container fill for the rounded transport buttons and the lyrics
  /// segmented control.
  static const Color container = Color(0xFFF0E5D9);

  /// A touch deeper than [container] for selected/pressed tonal surfaces.
  static const Color containerHigh = Color(0xFFE9DCCE);

  /// Primary text/icon ink — warm near-black, kept high-contrast for
  /// readability on the cream surfaces.
  static const Color ink = Color(0xFF2A2521);

  /// Secondary text (artist line, captions).
  static const Color inkMuted = Color(0xFF6B5F55);

  /// Tertiary ink for dimmed-but-legible content (inactive lyric lines).
  static const Color inkFaint = Color(0xFFAEA294);

  /// Hairline outlines / dividers.
  static const Color hairline = Color(0xFFEADDD0);

  /// The "live" accent used when no album colour can be derived — Linthra's
  /// warm orange, deepened so it stays legible as a highlight on cream.
  static const Color fallbackAccent = AppColors.accentDeep;
}

/// Builds the locally-scoped soft-light [ThemeData] for the now-playing and
/// lyrics screens, tuned around an [accent] (album-derived where possible).
///
/// Scoped with a `Theme`/`AnimatedTheme` wrapper on just those screens, so the
/// dark app shell is untouched. Call sites read `colorScheme.secondary` for the
/// live accent and `colorScheme.primary` for the violet brand, exactly as the
/// rest of the app does, so widgets stay token-driven.
abstract final class PlayerTheme {
  static ThemeData of(Color accent) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.brand,
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: onAccent(accent),
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

  /// A foreground (icon/text) colour that stays legible on top of [accent] —
  /// dark ink on a light accent, white on a saturated/dark one.
  static Color onAccent(Color accent) =>
      accent.computeLuminance() > 0.55 ? PlayerPalette.ink : Colors.white;
}
