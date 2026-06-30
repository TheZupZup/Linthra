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
/// The fields map onto the theme like this:
///  - [primary]/[onPrimary]      → `colorScheme.primary`/`onPrimary` (brand:
///    identity + primary buttons). Unchanged (Linthra violet) for every colour
///    variant; only the neutral Black & White variant retints it.
///  - [accent]/[onAccent]        → `colorScheme.secondary`/`onSecondary` (the
///    "live/active/selected" highlight that replaces the orange accent).
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
    required this.accent,
    required this.accentBright,
    required this.accentDeep,
    required this.onAccent,
    required this.accentContainer,
  });

  /// The matching [AppIconVariant.id]. Never shown to users.
  final String id;

  /// Brand colour: app identity, primary buttons, input focus, text buttons.
  final Color primary;

  /// Text/icon colour on a [primary] fill.
  final Color onPrimary;

  /// The live/active/selected highlight (what replaces Linthra's orange accent):
  /// selected navigation, sliders, switches, active icons, links, progress.
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
/// [classic]'s fields are exactly today's [AppColors] values, so the Classic
/// theme is unchanged. [dark] and [neon] keep Linthra's violet [primary] and
/// only swap the [accent] (to purple, and to neon cyan/blue); [gold] is a
/// black-and-gold theme and [blackWhite] a pure black/white one, so both also
/// retint [primary]. Accents are chosen to stay legible on the dark surfaces
/// (the primary experience) with a contrasting [onAccent], matching Classic's
/// accent-with-dark-glyph play button.
abstract final class BrandPalettes {
  /// The default identity — today's violet brand + warm orange accent. Also the
  /// fallback for an unknown/absent id (see [byId]).
  static const BrandPalette classic = BrandPalette(
    id: 'classic',
    primary: AppColors.brand,
    onPrimary: Colors.white,
    accent: AppColors.accent,
    accentBright: AppColors.accentBright,
    accentDeep: AppColors.accentDeep,
    onAccent: AppColors.onAccent,
    accentContainer: AppColors.accentContainer,
  );

  /// Black + purple: the violet brand with a lighter-violet highlight in place
  /// of the orange accent. No orange, blue, or gold.
  static const BrandPalette dark = BrandPalette(
    id: 'dark',
    primary: AppColors.brand,
    onPrimary: Colors.white,
    accent: Color(0xFFC4A0FF),
    accentBright: Color(0xFFDCC4FF),
    accentDeep: Color(0xFFA982F0),
    onAccent: Color(0xFF1C1140),
    accentContainer: Color(0xFF241946),
  );

  /// Purple + neon: the violet brand with an electric cyan/blue neon highlight
  /// in place of the orange accent. No orange.
  static const BrandPalette neon = BrandPalette(
    id: 'neon',
    primary: AppColors.brand,
    onPrimary: Colors.white,
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
    primary: Color(0xFFE0A82E),
    onPrimary: Color(0xFF1A1300),
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
    accent: Color(0xFF000000),
    accentBright: Color(0xFF000000),
    accentDeep: Color(0xFF000000),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFFFFFFF),
  );

  /// Every palette in [AppIconVariants.all] order; Classic first.
  static const List<BrandPalette> all = <BrandPalette>[
    classic,
    dark,
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
