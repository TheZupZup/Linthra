import 'package:flutter/material.dart';

import '../../app/colors.dart';

/// Which builds may offer an [AppIconVariant], and how.
///
/// This is a *data* seam, not a gate. In this build — and always in the F-Droid
/// build — every tier is fully available and selectable; the field exists only
/// so a future, Play-only PR can present [supporter] styles as cosmetic
/// supporter rewards behind the Play flavor. Even then it must stay purely
/// cosmetic: it can never affect playback, offline cache, providers, Android
/// Auto, or any core feature, and the F-Droid build keeps every variant
/// available.
enum AppIconTier {
  /// Always offered everywhere, with no strings attached.
  free,

  /// A cosmetic style earmarked for a possible future Play-only supporter
  /// edition. Offered and selectable here too — shown only with a neutral
  /// "Preview" badge — because this PR adds no gating or billing of any kind.
  supporter,
}

/// One Linthra brand-mark variant: a recolour/restyle of the same equalizer
/// mark, described as plain data.
///
/// Every variant keeps Linthra's identity — rounded equalizer bars under a
/// single vertical gradient — so the brand stays recognisable; a variant is
/// just a different [gradient] (top colour first) over a different [bars]
/// pattern. Because variants are data (no images, no extra assets), the whole
/// catalog is `const`, ships in every build, and is trivially unit-testable.
@immutable
class AppIconVariant {
  const AppIconVariant({
    required this.id,
    required this.label,
    required this.description,
    required this.tier,
    required this.gradient,
    required this.bars,
  });

  /// Stable identifier persisted in preferences and used for widget keys and
  /// tests. Never shown to users.
  final String id;

  /// Short, scannable name shown on the picker tile (e.g. "Neon").
  final String label;

  /// One line describing the look, surfaced as the tile's tooltip.
  final String description;

  /// Whether this is a free style or a cosmetic [AppIconTier.supporter] preview.
  /// Never gates anything in this build (see [AppIconTier]).
  final AppIconTier tier;

  /// The mark's vertical gradient, top colour first. Fed straight to the logo
  /// mark's shader.
  final List<Color> gradient;

  /// Bar heights as fractions of the mark's box (0..1), left to right. The mark
  /// lays out however many bars this lists, so a variant can read as a level
  /// meter, a rising signal, or a symmetric waveform.
  final List<double> bars;
}

// Cosmetic tints used only by the optional icon variants. Kept out of
// [AppColors] so the core palette stays focused on Linthra's primary
// violet+orange identity.
const Color _neonViolet = Color(0xFFB14DFF);
const Color _neonCyan = Color(0xFF22E0D6);
const Color _goldBright = Color(0xFFFFE08A);
const Color _goldDeep = Color(0xFFE6A200);

/// The built-in Linthra brand-mark variants and helpers to resolve them.
abstract final class AppIconVariants {
  /// The default identity — today's violet→orange equalizer mark. Also the
  /// fallback for an unknown or absent stored choice (see [byId]).
  static const AppIconVariant classic = AppIconVariant(
    id: 'classic',
    label: 'Classic',
    description: "Linthra's signature violet-to-orange equalizer.",
    tier: AppIconTier.free,
    gradient: <Color>[AppColors.brandBright, AppColors.accent],
    bars: <double>[0.46, 0.70, 0.56, 0.34],
  );

  /// A stealthy single-violet take on the mark.
  static const AppIconVariant dark = AppIconVariant(
    id: 'dark',
    label: 'Dark',
    description: 'A stealthy single-violet take on the mark.',
    tier: AppIconTier.free,
    gradient: <Color>[AppColors.brandBright, AppColors.brandDeep],
    bars: <double>[0.46, 0.70, 0.56, 0.34],
  );

  /// High-energy violet into electric cyan.
  static const AppIconVariant neon = AppIconVariant(
    id: 'neon',
    label: 'Neon',
    description: 'High-energy violet into electric cyan.',
    tier: AppIconTier.free,
    gradient: <Color>[_neonViolet, _neonCyan],
    bars: <double>[0.55, 0.85, 0.70, 0.45],
  );

  /// A black-and-gold treatment of the mark. Free, like every variant.
  static const AppIconVariant gold = AppIconVariant(
    id: 'gold',
    label: 'Gold',
    description: 'A black-and-gold treatment of the mark.',
    tier: AppIconTier.free,
    gradient: <Color>[_goldBright, _goldDeep],
    bars: <double>[0.46, 0.70, 0.56, 0.34],
  );

  /// Strictly black and white — no gray, no gradient. High-contrast minimalism.
  static const AppIconVariant blackWhite = AppIconVariant(
    id: 'blackwhite',
    label: 'Black & White',
    description: 'Strictly black and white — pure, high-contrast, minimal.',
    tier: AppIconTier.free,
    gradient: <Color>[Colors.white, Colors.white],
    bars: <double>[0.46, 0.70, 0.56, 0.34],
  );

  /// Every variant in display order; Classic first.
  static const List<AppIconVariant> all = <AppIconVariant>[
    classic,
    dark,
    neon,
    gold,
    blackWhite,
  ];

  /// Resolves a stored [id] to its variant, falling back to [classic] for a
  /// null, empty, or unrecognised value.
  ///
  /// This is the single place the "unknown selection → Classic" rule lives, so
  /// the controller and UI never have to guard for a bad id.
  static AppIconVariant byId(String? id) {
    if (id == null || id.isEmpty) {
      return classic;
    }
    for (final AppIconVariant variant in all) {
      if (variant.id == id) {
        return variant;
      }
    }
    return classic;
  }
}
