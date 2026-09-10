import 'package:flutter/material.dart';

import 'brand_theme.dart';
import 'colors.dart';
import 'dimens.dart';

/// Builds the light and dark [ThemeData] for Linthra. The look is black-first:
/// dark surfaces carry the UI, the brand identity colour (violet for Classic)
/// carries structure, and the warm accent (orange for Classic) carries energy.
///
/// Token rule of thumb for call sites:
///  - `colorScheme.primary`   → brand identity: text buttons, input focus, and
///    selected/active states (selected nav and rows use a brighter tone);
///  - `colorScheme.secondary` → the energy accent: primary call-to-action
///    buttons, progress, sliders, the play button, and small emphasis;
///  - `colorScheme.surface*`  → the dark elevation ramp.
/// Reach for these instead of hard-coding colours, so retuning the brand stays
/// a one-file change.
abstract final class AppTheme {
  static ThemeData dark(BrandPalette palette, {VisualDensity? density}) =>
      _build(
        palette: palette,
        density: density,
        brightness: Brightness.dark,
        background: AppColors.darkBackground,
        surface: AppColors.darkSurface,
        surfaceHigh: AppColors.darkSurfaceHigh,
        surfaceHighest: AppColors.darkSurfaceHighest,
        onSurface: AppColors.darkOnSurface,
        onSurfaceMuted: AppColors.darkOnSurfaceMuted,
        outline: AppColors.darkOutline,
        // Dark mode draws control borders and dividers with one tone, so both
        // slots take the same value and the rendered dark theme is unchanged.
        outlineVariant: AppColors.darkOutline,
        error: AppColors.error,
      );

  static ThemeData light(BrandPalette palette, {VisualDensity? density}) =>
      _build(
        palette: palette,
        density: density,
        brightness: Brightness.light,
        background: AppColors.lightBackground,
        surface: AppColors.lightSurface,
        surfaceHigh: AppColors.lightSurfaceHigh,
        surfaceHighest: AppColors.lightSurfaceHighest,
        onSurface: AppColors.lightOnSurface,
        onSurfaceMuted: AppColors.lightOnSurfaceMuted,
        // Light mode splits the two: controls need a 3:1 edge, dividers are
        // decorative and stay softer. See the AppColors doc comments.
        outline: AppColors.lightOutline,
        outlineVariant: AppColors.lightOutlineVariant,
        error: AppColors.lightError,
      );

  static ThemeData _build({
    required BrandPalette palette,
    required Brightness brightness,
    VisualDensity? density,
    required Color background,
    required Color surface,
    required Color surfaceHigh,
    required Color surfaceHighest,
    required Color onSurface,
    required Color onSurfaceMuted,
    required Color outline,
    required Color outlineVariant,
    required Color error,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: palette.primary,
      brightness: brightness,
    ).copyWith(
      primary: palette.primary,
      onPrimary: palette.onPrimary,
      secondary: palette.accent,
      onSecondary: palette.onAccent,
      secondaryContainer: palette.accentContainer,
      onSecondaryContainer: palette.accentBright,
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceMuted,
      surfaceContainerLowest: background,
      surfaceContainerLow: surface,
      surfaceContainer: surfaceHigh,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHighest,
      outline: outline,
      outlineVariant: outlineVariant,
      error: error,
    );

    final pillShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.pill),
    );
    final smallShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.sm),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      // Desktop content density (#384). Material's own adaptive value: compact
      // on Linux/macOS/Windows, standard everywhere touch-first, so a Linux
      // window fits materially more of a library per screen while a phone's
      // rows and tap targets do not move a pixel.
      //
      // It reads `defaultTargetPlatform`, the same signal the shell's
      // navigation rail keys off, rather than shrinking on width: density is
      // about what is pointing at the row, and an Android tablet in landscape
      // is as wide as a desktop window and still driven by a thumb.
      //
      // [density] overrides it with the user's Compact/Comfortable choice
      // (#395). `LinthraApp` passes one only on a desktop host, so a touch
      // build can never inherit a desktop density: off desktop the parameter is
      // null and this stays exactly the adaptive value it has always been.
      visualDensity: density ?? VisualDensity.adaptivePlatformDensity,
      // Hover feedback (#385). Material's default is a 4% white/black veil,
      // which on a black-first theme is close to invisible — so a mouse user
      // could not tell a row apart from the page it sits on.
      //
      // Deliberately neutral rather than brand-tinted: the violet tint is what
      // *selected* means (see listTileTheme below), and hover has to stay
      // distinct from selection, from focus and from pressed. One value here
      // reaches every ink surface at once: list rows, buttons, grid cards, the
      // navigation rail's destinations and popup-menu items.
      hoverColor: onSurface.withValues(alpha: 0.07),
      extensions: <ThemeExtension<dynamic>>[
        LinthraAccents(
          accentBright: palette.accentBright,
          accentDeep: palette.accentDeep,
        ),
      ],
      scaffoldBackgroundColor: background,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        color: surfaceHigh,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: onSurface,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: palette.primary.withValues(alpha: 0.18),
        indicatorShape: pillShape,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? palette.primaryBright : onSurfaceMuted,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            letterSpacing: 0.2,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? palette.primaryBright : onSurfaceMuted,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
          shape: pillShape,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: onSurface,
          side: BorderSide(color: outline),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: pillShape,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.primaryBright,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: palette.accent,
        inactiveTrackColor: onSurface.withValues(alpha: 0.16),
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: 0.16),
        trackShape: const RoundedRectSliderTrackShape(),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.onPrimary
              : onSurfaceMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : surfaceHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : outline,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        prefixIconColor: onSurfaceMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: palette.primaryBright, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHigh,
        selectedColor: colorScheme.secondaryContainer,
        side: BorderSide(color: outline),
        labelStyle: TextStyle(
          color: onSurface,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: colorScheme.onSecondaryContainer,
        ),
        shape: pillShape,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: onSurfaceMuted,
        selectedColor: palette.primaryBright,
        selectedTileColor: palette.primary.withValues(alpha: 0.10),
        shape: smallShape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceHighest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceHigh,
        modalBackgroundColor: surfaceHigh,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.lg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHighest,
        contentTextStyle: TextStyle(color: onSurface),
        actionTextColor: palette.accent,
        shape: smallShape,
      ),
      dividerTheme: DividerThemeData(
        // Separators, not control edges — they take the softer variant. In dark
        // mode this is the same colour as [outline], so nothing changes there.
        color: outlineVariant,
        thickness: 0.5,
        space: 0.5,
      ),
    );
  }
}
