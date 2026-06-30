import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/colors.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';

/// The 0..255 value of a colour channel (the new [Color] component API returns
/// 0..1 doubles).
int _chan(double v) => (v * 255).round();

bool _isPureBlackOrWhite(Color c) {
  for (final double v in <double>[c.r, c.g, c.b]) {
    final int channel = _chan(v);
    if (channel != 0 && channel != 255) {
      return false;
    }
  }
  return true;
}

void main() {
  group('BrandPalettes registry', () {
    test('every branding variant resolves to a palette in both brightnesses',
        () {
      // The single place the "every variant has a theme" rule is enforced, so a
      // future AppIconVariant can never silently ship without an accent palette.
      for (final AppIconVariant variant in AppIconVariants.all) {
        final BrandPalette dark =
            BrandPalettes.byId(variant.id, brightness: Brightness.dark);
        final BrandPalette light =
            BrandPalettes.byId(variant.id, brightness: Brightness.light);
        expect(dark.id, variant.id, reason: '${variant.id} needs a palette');
        expect(light.id, variant.id, reason: '${variant.id} needs a palette');
      }
    });

    test('falls back to Classic for null, empty, or unknown ids', () {
      // The same "unknown → Classic" rule AppIconVariants.byId follows.
      for (final Brightness b in Brightness.values) {
        expect(BrandPalettes.byId(null, brightness: b), BrandPalettes.classic);
        expect(BrandPalettes.byId('', brightness: b), BrandPalettes.classic);
        expect(
          BrandPalettes.byId('does-not-exist', brightness: b),
          BrandPalettes.classic,
        );
      }
    });

    test('Classic is a black + orange palette built from AppColors', () {
      // Classic uses Linthra's existing orange (AppColors.accent*) as its one
      // accent: primary and accent are the same orange.
      expect(BrandPalettes.classic.primary, AppColors.accent);
      expect(BrandPalettes.classic.onPrimary, AppColors.onAccent);
      expect(BrandPalettes.classic.primaryBright, AppColors.accentBright);
      expect(BrandPalettes.classic.accent, AppColors.accent);
      expect(BrandPalettes.classic.accentBright, AppColors.accentBright);
      expect(BrandPalettes.classic.accentDeep, AppColors.accentDeep);
      expect(BrandPalettes.classic.onAccent, AppColors.onAccent);
      expect(BrandPalettes.classic.accentContainer, AppColors.accentContainer);
    });

    test('every theme is a single accent (primary == accent)', () {
      // No second hue: each variant's identity colour is its accent.
      for (final BrandPalette p in BrandPalettes.all) {
        expect(p.primary, p.accent, reason: '${p.id} primary == accent');
        expect(
          p.primaryBright,
          p.accentBright,
          reason: '${p.id} primaryBright == accentBright',
        );
        expect(
          p.onPrimary,
          p.onAccent,
          reason: '${p.id} onPrimary == onAccent',
        );
      }
    });

    test('every palette keeps a legible accent/onAccent contrast', () {
      // onAccent rides on top of an accent fill (e.g. the play button glyph), so
      // the two must stay clearly distinguishable for accessibility.
      for (final BrandPalette p in BrandPalettes.all) {
        final double delta =
            (p.accent.computeLuminance() - p.onAccent.computeLuminance()).abs();
        expect(
          delta,
          greaterThan(0.3),
          reason: '${p.id}: accent vs onAccent must stay legible',
        );
      }
    });
  });

  group('Black & White palette', () {
    test('uses only pure black or pure white, in both brightnesses', () {
      for (final Brightness b in Brightness.values) {
        final BrandPalette bw = BrandPalettes.byId('blackwhite', brightness: b);
        for (final Color c in <Color>[
          bw.primary,
          bw.onPrimary,
          bw.accent,
          bw.accentBright,
          bw.accentDeep,
          bw.onAccent,
          bw.accentContainer,
        ]) {
          expect(
            _isPureBlackOrWhite(c),
            isTrue,
            reason: '$c ($b) must be pure black or pure white — no gray',
          );
        }
      }
    });

    test('flips between dark and light so it stays legible either way', () {
      final BrandPalette dark =
          BrandPalettes.byId('blackwhite', brightness: Brightness.dark);
      final BrandPalette light =
          BrandPalettes.byId('blackwhite', brightness: Brightness.light);
      // White accents on the dark surfaces; black accents on the light ones.
      expect(dark.accent, const Color(0xFFFFFFFF));
      expect(light.accent, const Color(0xFF000000));
    });
  });

  group('LinthraAccents extension', () {
    const LinthraAccents a = LinthraAccents(
      accentBright: Color(0xFF111111),
      accentDeep: Color(0xFF222222),
    );
    const LinthraAccents b = LinthraAccents(
      accentBright: Color(0xFFFFFFFF),
      accentDeep: Color(0xFFFFFFFF),
    );

    test('lerp endpoints return the start and end values', () {
      expect(a.lerp(b, 0.0).accentBright, a.accentBright);
      expect(a.lerp(b, 1.0).accentBright, b.accentBright);
      expect(a.lerp(b, 0.0).accentDeep, a.accentDeep);
      expect(a.lerp(b, 1.0).accentDeep, b.accentDeep);
    });

    test('copyWith overrides only the given field', () {
      final LinthraAccents c = a.copyWith(accentDeep: const Color(0xFF333333));
      expect(c.accentBright, a.accentBright);
      expect(c.accentDeep, const Color(0xFF333333));
    });
  });
}
