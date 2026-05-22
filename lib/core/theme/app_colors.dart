import 'package:flutter/material.dart';

/// Centralized color palette. Dark mode is the primary experience; the light
/// palette mirrors it so both themes feel like the same product.
abstract final class AppColors {
  // Brand accent — a calm violet that reads well on dark surfaces.
  static const Color accent = Color(0xFF8B7CF6);
  static const Color accentMuted = Color(0xFF5B53A8);

  // Dark surfaces (primary).
  static const Color darkBackground = Color(0xFF0E0F13);
  static const Color darkSurface = Color(0xFF16181F);
  static const Color darkSurfaceHigh = Color(0xFF1E212B);
  static const Color darkOnSurface = Color(0xFFE7E7EC);
  static const Color darkOnSurfaceMuted = Color(0xFF9A9BA6);

  // Light surfaces.
  static const Color lightBackground = Color(0xFFF6F6FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightOnSurface = Color(0xFF1A1B20);
  static const Color lightOnSurfaceMuted = Color(0xFF6B6C76);

  static const Color error = Color(0xFFE5484D);
}
