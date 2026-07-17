import 'package:flutter/material.dart';

import '../../app/brand_theme.dart';
import '../../core/models/custom_theme_settings.dart';

/// Builds the complete Linthra palette from the user's two color choices.
///
/// Error and destructive colors remain owned by `AppTheme`; this function only
/// derives identity and playback-accent roles.
BrandPalette customBrandPalette(
  CustomThemeSettings settings, {
  required Brightness brightness,
}) {
  final Color primary = Color(settings.primaryColorValue);
  final Color accent = Color(settings.accentColorValue);
  final bool isDark = brightness == Brightness.dark;

  return BrandPalette(
    id: 'custom',
    primary: primary,
    onPrimary: _foregroundFor(primary),
    primaryBright: _shiftLightness(primary, isDark ? 0.18 : -0.12),
    accent: accent,
    accentBright: _shiftLightness(accent, isDark ? 0.16 : -0.08),
    accentDeep: _shiftLightness(accent, isDark ? -0.14 : -0.20),
    onAccent: _foregroundFor(accent),
    accentContainer: _containerFor(accent, brightness),
  );
}

Color _foregroundFor(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

Color _shiftLightness(Color color, double amount) {
  final HSLColor hsl = HSLColor.fromColor(color);
  final double lightness =
      (hsl.lightness + amount).clamp(0.08, 0.92).toDouble();
  return hsl.withLightness(lightness).toColor();
}

Color _containerFor(Color color, Brightness brightness) {
  final HSLColor hsl = HSLColor.fromColor(color);
  final double lightness = brightness == Brightness.dark ? 0.18 : 0.90;
  final double saturation = hsl.saturation.clamp(0.25, 0.75).toDouble();
  return hsl
      .withSaturation(saturation)
      .withLightness(lightness)
      .toColor();
}
