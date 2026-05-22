import 'package:flutter/material.dart';

import 'colors.dart';
import 'dimens.dart';

/// Builds the light and dark [ThemeData] for Sonara. Both share the same
/// shape language and accent so the product feels cohesive across modes.
abstract final class AppTheme {
  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        background: AppColors.darkBackground,
        surface: AppColors.darkSurface,
        surfaceHigh: AppColors.darkSurfaceHigh,
        onSurface: AppColors.darkOnSurface,
        onSurfaceMuted: AppColors.darkOnSurfaceMuted,
      );

  static ThemeData get light => _build(
        brightness: Brightness.light,
        background: AppColors.lightBackground,
        surface: AppColors.lightSurface,
        surfaceHigh: AppColors.lightSurface,
        onSurface: AppColors.lightOnSurface,
        onSurfaceMuted: AppColors.lightOnSurfaceMuted,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color surfaceHigh,
    required Color onSurface,
    required Color onSurfaceMuted,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: brightness,
    ).copyWith(
      primary: AppColors.accent,
      surface: surface,
      onSurface: onSurface,
      error: AppColors.error,
    );

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.md),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        color: surfaceHigh,
        elevation: 0,
        shape: cardShape,
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.accentMuted.withValues(alpha: 0.35),
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: onSurface),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: onSurfaceMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
      ),
    );
  }
}
