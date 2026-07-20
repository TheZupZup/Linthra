import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/colors.dart';
import '../../app/dimens.dart';
import '../../data/repositories/launcher_icon_service_provider.dart';
import '../support/support_actions_provider.dart';
import 'app_icon_controller.dart';
import 'app_icon_variant.dart';
import 'custom_theme_card.dart';
import 'linthra_logo_mark.dart';

/// "App icon & branding" — reached from Settings → Appearance.
///
/// Every built-in icon theme remains free. The separate custom-palette card is
/// offered only by the dedicated GitHub Sponsor distribution and never affects
/// music functionality.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<AppIconVariant> variants =
        ref.watch(availableAppIconVariantsProvider);
    final AppIconVariant selected = ref.watch(appIconControllerProvider);
    final SupportDistribution distribution =
        ref.watch(supportDistributionProvider);
    final bool showCustomPalette = distribution.offersCustomPalette;
    // Only Android can switch the real launcher icon; elsewhere the picker
    // changes the in-app mark only, so we skip the home-screen hint there.
    final bool launcherSwitchSupported =
        ref.watch(launcherIconServiceProvider).isSupported;
    return Scaffold(
      appBar: AppBar(title: const Text('App icon & branding')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: <Widget>[
          _IntroCard(showCustomPalette: showCustomPalette),
          const SizedBox(height: AppSpacing.md),
          _VariantGrid(
            variants: variants,
            selectedId: selected.id,
            onSelect: (AppIconVariant variant) => _onSelect(
              context,
              ref,
              variant: variant,
              isNewSelection: variant.id != selected.id,
              announceLauncherChange: launcherSwitchSupported,
            ),
          ),
          if (showCustomPalette) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            const CustomThemeCard(),
          ],
          const SizedBox(height: AppSpacing.lg),
          const _SuggestionsNote(),
        ],
      ),
    );
  }

  /// Applies the selection and, when the real launcher icon actually changes
  /// (Android, and only for a *new* pick), surfaces a brief note that some
  /// launchers need a moment or a refresh before the new icon shows.
  void _onSelect(
    BuildContext context,
    WidgetRef ref, {
    required AppIconVariant variant,
    required bool isNewSelection,
    required bool announceLauncherChange,
  }) {
    ref.read(appIconControllerProvider.notifier).select(variant);
    if (isNewSelection && announceLauncherChange) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Launcher icon updated. Some launchers take a few seconds — or a '
            'refresh — to show the new icon.',
          ),
        ),
      );
    }
  }
}

/// A friendly, low-key invitation under the picker.
class _SuggestionsNote extends StatelessWidget {
  const _SuggestionsNote();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Text(
        "Have an idea for another color theme? I'm open to suggestions.",
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

/// Explains the free built-in themes and, where available, the supporter palette.
class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.showCustomPalette});

  final bool showCustomPalette;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.palette_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Make Linthra yours',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              showCustomPalette
                  ? 'Choose how the Linthra mark looks across the app and, on '
                      'Android, on your home screen. Classic, Neon, Gold, and '
                      'Black & White are free for everyone. The optional custom '
                      'palette below changes colors only — never how Linthra '
                      'plays, syncs, or stores your music.'
                  : 'Choose how the Linthra mark looks across the app and, on '
                      'Android, on your home screen. Classic, Neon, Gold, and '
                      'Black & White are free for everyone.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The wrapping grid of selectable variant tiles.
class _VariantGrid extends StatelessWidget {
  const _VariantGrid({
    required this.variants,
    required this.selectedId,
    required this.onSelect,
  });

  final List<AppIconVariant> variants;
  final String selectedId;
  final ValueChanged<AppIconVariant> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.md,
      alignment: WrapAlignment.center,
      children: <Widget>[
        for (final AppIconVariant variant in variants)
          _VariantTile(
            variant: variant,
            selected: variant.id == selectedId,
            onTap: () => onSelect(variant),
          ),
      ],
    );
  }
}

/// One free built-in branding variant.
class _VariantTile extends StatelessWidget {
  const _VariantTile({
    required this.variant,
    required this.selected,
    required this.onTap,
  });

  final AppIconVariant variant;
  final bool selected;
  final VoidCallback onTap;

  static const double _tileWidth = 104;
  static const double _iconBox = 72;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color borderColor =
        selected ? theme.colorScheme.primary : theme.colorScheme.outline;
    return SizedBox(
      width: _tileWidth,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Tooltip(
                    message: variant.description,
                    child: Container(
                      width: _iconBox,
                      height: _iconBox,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.darkBackground,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(
                          color: borderColor,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: LinthraLogoMark(
                        gradient: variant.gradient,
                        bars: variant.bars,
                        size: 54,
                      ),
                    ),
                  ),
                  if (selected)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary,
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          Icons.check,
                          size: 14,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                variant.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
