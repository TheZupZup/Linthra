import 'package:flutter/material.dart';

/// Centralized colour palette for Linthra.
///
/// The identity is two colours working together: a vivid **violet** that
/// carries the brand (logo, primary actions, structure) and a warm **orange**
/// accent reserved for things that are *live* — the playing / selected / active
/// states and playback progress. Keeping orange scarce is what makes it read as
/// energy rather than decoration, and it's what separates Linthra from a calm
/// productivity app. Dark mode is the primary experience; the light palette
/// mirrors it so both feel like the same product.
abstract final class AppColors {
  // Brand violet — the primary identity.
  /// The core brand colour: app identity, primary buttons, structural accents.
  static const Color brand = Color(0xFF7C5CFF);

  /// Lighter violet for gradient tops, the logo mark, and hover/emphasis.
  static const Color brandBright = Color(0xFF9C84FF);

  /// Deeper violet for gradient bottoms and pressed states.
  static const Color brandDeep = Color(0xFF5B3FD9);

  /// Low-emphasis violet for tinted containers/indicators on dark surfaces.
  static const Color brandMuted = Color(0xFF463B73);

  // Warm orange — the "live" accent.
  /// The accent: playback / active / selected states, key highlights, progress.
  static const Color accent = Color(0xFFFF9F43);

  /// Lighter orange for gradient tops and the logo mark's warm end.
  static const Color accentBright = Color(0xFFFFB867);

  /// Deeper orange for gradient bottoms and pressed states.
  static const Color accentDeep = Color(0xFFF2861E);

  /// A dark, warm ink for text/icons sitting on an orange fill (e.g. the play
  /// button), where white would wash out against the bright accent.
  static const Color onAccent = Color(0xFF231405);

  /// A dark, warm surface behind selected/active orange content (e.g. a tonal
  /// button or selected chip), readable with [accentBright] as its foreground.
  static const Color accentContainer = Color(0xFF3A2A16);

  // Dark surfaces (primary experience).
  static const Color darkBackground = Color(0xFF111018);
  static const Color darkSurface = Color(0xFF17151F);
  static const Color darkSurfaceHigh = Color(0xFF201D2B);
  static const Color darkSurfaceHighest = Color(0xFF272336);
  static const Color darkOnSurface = Color(0xFFF5F7FA);
  static const Color darkOnSurfaceMuted = Color(0xFF9E9CB0);
  static const Color darkOutline = Color(0xFF322E40);

  // Light surfaces.
  static const Color lightBackground = Color(0xFFF6F5FB);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFF1EFF8);
  static const Color lightSurfaceHighest = Color(0xFFE9E5F3);
  static const Color lightOnSurface = Color(0xFF1A1820);
  static const Color lightOnSurfaceMuted = Color(0xFF6B6878);
  static const Color lightOutline = Color(0xFFD9D5E6);

  static const Color error = Color(0xFFE5484D);
}
