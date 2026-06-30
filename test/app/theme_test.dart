import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/colors.dart';
import 'package:linthra/app/theme.dart';

void main() {
  group('AppTheme', () {
    test('Classic dark theme keeps the existing brand + accent', () {
      final ThemeData theme = AppTheme.dark(BrandPalettes.classic);
      expect(theme.colorScheme.primary, AppColors.brand);
      expect(theme.colorScheme.secondary, AppColors.accent);
      expect(theme.colorScheme.onSecondary, AppColors.onAccent);
      expect(theme.colorScheme.error, AppColors.error);
    });

    test('exposes the accent gradient ends via the LinthraAccents extension',
        () {
      final ThemeData theme = AppTheme.dark(BrandPalettes.classic);
      final LinthraAccents? accents = theme.extension<LinthraAccents>();
      expect(accents, isNotNull);
      expect(accents!.accentBright, AppColors.accentBright);
      expect(accents.accentDeep, AppColors.accentDeep);
    });

    test('a violet-brand variant retints the accent but keeps brand + error',
        () {
      final ThemeData neon = AppTheme.dark(
        BrandPalettes.byId('neon', brightness: Brightness.dark),
      );
      expect(neon.colorScheme.secondary, BrandPalettes.neon.accent);
      expect(neon.colorScheme.secondary, isNot(AppColors.accent));
      // Dark and Neon keep Linthra's violet brand — only the accent changes.
      expect(neon.colorScheme.primary, AppColors.brand);
      // Destructive/error colour is never themed.
      expect(neon.colorScheme.error, AppColors.error);
    });

    test('Gold is a black-and-gold theme — gold brand + gold accent, no violet',
        () {
      final ThemeData gold = AppTheme.dark(
        BrandPalettes.byId('gold', brightness: Brightness.dark),
      );
      expect(gold.colorScheme.primary, BrandPalettes.gold.primary);
      expect(gold.colorScheme.primary, isNot(AppColors.brand));
      expect(gold.colorScheme.secondary, BrandPalettes.gold.accent);
      expect(gold.colorScheme.error, AppColors.error);
    });

    test('the neutral Black & White variant also themes the primary', () {
      final ThemeData bw = AppTheme.dark(
        BrandPalettes.byId('blackwhite', brightness: Brightness.dark),
      );
      expect(bw.colorScheme.primary, const Color(0xFFFFFFFF));
      expect(bw.colorScheme.secondary, const Color(0xFFFFFFFF));
      expect(bw.colorScheme.error, AppColors.error);
    });
  });
}
