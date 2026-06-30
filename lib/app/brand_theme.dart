import 'package:flutter/material.dart';

import 'colors.dart';

/// The accent/brand colours one branding variant paints the app with.
///
/// Selecting an [AppIconVariant] does more than restyle the mark and the
/// launcher icon: it also retints the app's accent (and, for the neutral
/// variants, its brand colour) so the picker reads as a complete visual theme
/// selector. A [BrandPalette] is the small, data-only seam that carries those
/// colours; [BrandPalettes] maps each variant id to one (falling back to
/// [BrandPalettes.classic] for an unknown/absent id, exactly like
/// `AppIconVariants.byId`), and `AppTheme` threads the chosen palette through
/// the whole [ThemeData] so no screen has to know about variants.
///
/// Keeping this as plain `const` data — no images, no extra assets — means the
/// whole registry ships in every build and is trivially unit-testable, mirroring
/// the `AppIconVariant` catalog it parallels.
///
/// Roles — black-first, one accent per theme: surfaces stay dark and a single
/// accent colour carries everything coloured (Classic orange, Neon neon-blue,
/// Gold gold, Black & White white):
///  - [primary]/[primaryBright]/[onPrimary] → the colour-scheme seed and the
///    accent's text/icon tone for selected navigation, text buttons, input
///    focus, and selected rows. [primaryBright] is the accessible-on-dark tone.
///  - [accent]/[onAccent]        → `colorScheme.secondary`/`onSecondary` — the
///    same accent on filled call-to-action buttons, progress, sliders, the play
///    button, and small emphasis. Equal to [primary] for these themes.
///  - [accentBright]             → `colorScheme.onSecondaryContainer` and the
///    play button's gradient top (via [LinthraAccents]).
///  - [accentDeep]               → the play button's gradient bottom (via
///    [LinthraAccents]); it has no Material colour-scheme slot of its own.
///  - [accentContainer]          → `colorScheme.secondaryContainer`.
@immutable
class BrandPalette {
  const BrandPalette({
    required this.id,
    required this.primary,
    required this.onPrimary,
    required this.primaryBright,
    required this.accent,
    required this.accentBright,
    required this.accentDeep,
    required this.onAccent,
    required this.accentContainer,
  });

  /// The matching [AppIconVariant.id]. Never shown to users.
  final String id;

  /// The theme's single accent (orange for Classic): the colour-scheme seed and
  /// the tint behind selected navigation and selected rows. Equal to [accent].
  final Color primary;

  /// Text/icon colour on a [primary] fill (and the selected switch thumb).
  final Color onPrimary;

  /// A brighter take on [primary] for the accent's text/icons/borders on the
  /// dark surfaces — selected navigation, text buttons, selected rows, input
  /// focus — where [primary] itself can fall short of the text-contrast bar.
  final Color primaryBright;

  /// The accent (warm orange for Classic) on filled call-to-action buttons,
  /// progress, sliders, the play button, and small emphasis. One per theme.
  final Color accent;

  /// Lighter accent for the play button's gradient top and tonal foregrounds.
  final Color accentBright;

  /// Deeper accent for the play button's gradient bottom / pressed states.
  final Color accentDeep;

  /// Text/icon colour on an [accent] fill (e.g. the play button glyph).
  final Color onAccent;

  /// A muted surface behind selected/active accent content (selected chips).
  final Color accentContainer;
}

/// The two accent tones Material's [ColorScheme] has no slot for, carried on the
/// [ThemeData] so call sites can read them reactively via
/// `Theme.of(context).extension<LinthraAccents>()`.
///
/// [accent] and [onAccent] already live in the scheme (`secondary`/
/// `onSecondary`), so this extension stays minimal: it only adds the play
/// button's gradient ends. Implementing [lerp] lets a theme switch animate
/// smoothly like any other [ThemeData] change.
@immutable
class LinthraAccents extends ThemeExtension<LinthraAccents> {
  const LinthraAccents({
    required this.accentBright,
    required this.accentDeep,
  });

  /// The play button's gradient top (the palette's [BrandPalette.accentBright]).
  final Color accentBright;

  /// The play button's gradient bottom (the palette's [BrandPalette.accentDeep]).
  final Color accentDeep;

  @override
  LinthraAccents copyWith({Color? accentBright, Color? accentDeep}) {
    return LinthraAccents(
      accentBright: accentBright ?? this.accentBright,
      accentDeep: accentDeep ?? this.accentDeep,
    );
  }

  @override
  LinthraAccents lerp(ThemeExtension<LinthraAccents>? other, double t) {
    if (other is! LinthraAccents) {
      return this;
    }
    return LinthraAccents(
      accentBright: Color.lerp(accentBright, other.accentBright, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
    );
  }
}

/// The built-in brand palettes, one per [AppIconVariant], and the resolver the
/// theme reads them through.
///
/// Every theme is a single accent on the dark surfaces, with no second hue:
/// [classic] is orange (reusing today's [AppColors] orange), [neon] neon
/// cyan/blue, [gold] gold, and [blackWhite] pure black/white. Each sets
/// [primary] equal to its [accent] so the whole UI reads as one accent on
/// black; [primaryBright] is the accessible-on-dark tone for accent text/icons.
/// Error/destructive colours are never themed.
abstract final class BrandPalettes {
  /// The default — black + orange: a single warm orange accent on the dark
  /// surfaces. Also the fallback for an unknown/absent id (see [byId]).
  static const BrandPalette classic = BrandPalette(
    id: 'classic',
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    primaryBright: AppColors.accentBright,
    accent: AppColors.accent,
    accentBright: AppColors.accentBright,
    accentDeep: AppColors.accentDeep,
    onAccent: AppColors.onAccent,
    accentContainer: AppColors.accentContainer,
  );

  /// Black + neon blue: a single electric cyan/blue accent. No purple.
  static const BrandPalette neon = BrandPalette(
    id: 'neon',
    primary: Color(0xFF34C5FF),
    onPrimary: Color(0xFF02161F),
    primaryBright: Color(0xFF7ADBFF),
    accent: Color(0xFF34C5FF),
    accentBright: Color(0xFF7ADBFF),
    accentDeep: Color(0xFF1C9FE6),
    onAccent: Color(0xFF02161F),
    accentContainer: Color(0xFF0D2735),
  );

  /// Black + gold: a rich gold brand *and* gold accent on the dark surfaces, so
  /// the whole theme reads black-and-gold (no violet, no orange/yellow mix).
  static const BrandPalette gold = BrandPalette(
    id: 'gold',
    primary: Color(0xFFF5C518),
    onPrimary: Color(0xFF241C00),
    primaryBright: Color(0xFFFFDD55),
    accent: Color(0xFFF5C518),
    accentBright: Color(0xFFFFDD55),
    accentDeep: Color(0xFFD9A400),
    onAccent: Color(0xFF241C00),
    accentContainer: Color(0xFF332808),
  );

  /// A strictly black-and-white theme for dark mode: pure white accents/brand on
  /// the dark surfaces, with pure-black glyphs. Every colour here is pure black
  /// or pure white — no gray, no tint. (Light mode flips to black-on-white; see
  /// [_blackWhiteLight] / [byId].)
  static const BrandPalette blackWhite = BrandPalette(
    id: 'blackwhite',
    primary: Color(0xFFFFFFFF),
    onPrimary: Color(0xFF000000),
    primaryBright: Color(0xFFFFFFFF),
    accent: Color(0xFFFFFFFF),
    accentBright: Color(0xFFFFFFFF),
    accentDeep: Color(0xFFFFFFFF),
    onAccent: Color(0xFF000000),
    accentContainer: Color(0xFF000000),
  );

  /// The light-mode counterpart of [blackWhite]: pure black accents/brand on
  /// light surfaces. Kept strictly black-and-white too. (Linthra runs dark-only
  /// today, so this is defensive: if light mode ever ships, Black & White stays
  /// legible instead of going invisible-white on white.)
  static const BrandPalette _blackWhiteLight = BrandPalette(
    id: 'blackwhite',
    primary: Color(0xFF000000),
    onPrimary: Color(0xFFFFFFFF),
    primaryBright: Color(0xFF000000),
    accent: Color(0xFF000000),
    accentBright: Color(0xFF000000),
    accentDeep: Color(0xFF000000),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFFFFFFF),
  );

  /// Every palette in [AppIconVariants.all] order; Classic first.
  static const List<BrandPalette> all = <BrandPalette>[
    classic,
    neon,
    gold,
    blackWhite,
  ];

  /// Resolves a stored/selected variant [id] to its palette for [brightness],
  /// falling back to [classic] for a null, empty, or unrecognised value — the
  /// same "unknown → Classic" rule [AppIconVariants.byId] uses, so the theme can
  /// never land on a palette that does not exist.
  ///
  /// Only Black & White differs by brightness (white-on-dark vs black-on-light);
  /// every other variant uses one palette for both, since accents chosen for the
  /// dark surfaces stay legible either way.
  static BrandPalette byId(String? id, {required Brightness brightness}) {
    if (id == null || id.isEmpty) {
      return classic;
    }
    if (id == blackWhite.id) {
      return brightness == Brightness.light ? _blackWhiteLight : blackWhite;
    }
    for (final BrandPalette palette in all) {
      if (palette.id == id) {
        return palette;
      }
    }
    return classic;
  }
}
