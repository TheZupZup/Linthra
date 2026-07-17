import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/colors.dart';
import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../data/repositories/launcher_icon_service_provider.dart';
import '../support/supporter_entitlement.dart';
import 'app_icon_access.dart';
import 'app_icon_controller.dart';
import 'app_icon_variant.dart';
import 'linthra_logo_mark.dart';

/// "App icon & branding" — reached from Settings → Appearance.
///
/// Lets the user pick how the Linthra mark looks across the app. The feature is
/// purely cosmetic: access can affect only themes and launcher icons, never
/// playback, sync, providers, downloads, or storage.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<AppIconVariant> variants =
        ref.watch(availableAppIconVariantsProvider);
    final AppIconVariant selected = ref.watch(appIconControllerProvider);
    final SupporterEntitlement entitlement =
        ref.watch(supporterEntitlementProvider);
    // Only Android can switch the real launcher icon; elsewhere the picker
    // changes the in-app mark only, so we skip the home-screen hint there.
    final bool launcherSwitchSupported =
        ref.watch(launcherIconServiceProvider).isSupported;
    return Scaffold(
      appBar: AppBar(title: const Text('App icon & branding')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: <Widget>[
          _IntroCard(entitlement: entitlement),
          const SizedBox(height: AppSpacing.md),
          _VariantGrid(
            variants: variants,
            entitlement: entitlement,
            selectedId: selected.id,
            onSelect: (AppIconVariant variant) {
              final AppIconAccess access =
                  appIconAccessFor(variant, entitlement);
              if (!access.canSelect) {
                _showSupporterStyleSheet(context, variant);
                return;
              }
              _onSelect(
                context,
                ref,
                variant: variant,
                isNewSelection: variant.id != selected.id,
                announceLauncherChange: launcherSwitchSupported,
              );
            },
          ),
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

  /// Explains a locked cosmetic without turning the picker into a paywall.
  /// Core features remain free and the support destination owns all payment
  /// presentation, so this screen stays billing-SDK agnostic.
  void _showSupporterStyleSheet(
    BuildContext context,
    AppIconVariant variant,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        final Color muted =
            theme.colorScheme.onSurface.withValues(alpha: 0.65);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    LinthraLogoMark(
                      size: 44,
                      gradient: variant.gradient,
                      bars: variant.bars,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        '${variant.label} supporter style',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'This is an optional visual reward for people who support '
                  'Linthra. Music playback, offline listening, server '
                  'connections, Android Auto, and every core feature stay free.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      context.push(AppRoutes.settingsSupport);
                    },
                    icon: const Icon(Icons.favorite_outline),
                    label: const Text('View supporter options'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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

/// Explains how cosmetic access works in the current distribution.
class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.entitlement});

  final SupporterEntitlement entitlement;

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
              _description,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }

  String get _description {
    switch (entitlement) {
      case SupporterEntitlement.included:
        return 'Choose how the Linthra mark and accent colors look across the '
            'app. Every style is included in this build. Gold and Black & White '
            'are marked as supporter cosmetics for the future Play edition, but '
            'branding never changes how Linthra handles your music.';
      case SupporterEntitlement.locked:
        return 'Classic and Neon are included. Gold and Black & White are '
            'optional supporter cosmetics in the Play edition. Playback, '
            'offline listening, server connections, and every core feature '
            'remain free.';
      case SupporterEntitlement.unlocked:
        return 'Thank you for supporting Linthra. Every branding style is '
            'available, including the Gold and Black & White supporter '
            'cosmetics. Your support changes the look — never the music features.';
    }
  }
}

/// The wrapping grid of selectable variant tiles.
class _VariantGrid extends StatelessWidget {
  const _VariantGrid({
    required this.variants,
    required this.entitlement,
    required this.selectedId,
    required this.onSelect,
  });

  final List<AppIconVariant> variants;
  final SupporterEntitlement entitlement;
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
            locked: !appIconAccessFor(variant, entitlement).canSelect,
            onTap: () => onSelect(variant),
          ),
      ],
    );
  }
}

/// One branding variant. Supporter styles remain visible as previews; when the
/// current Play entitlement does not allow them, the tile opens an explanation
/// instead of changing state.
class _VariantTile extends StatelessWidget {
  const _VariantTile({
    required this.variant,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final AppIconVariant variant;
  final bool selected;
  final bool locked;
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
                      child: Opacity(
                        opacity: locked ? 0.55 : 1,
                        child: LinthraLogoMark(
                          size: 44,
                          gradient: variant.gradient,
                          bars: variant.bars,
                        ),
                      ),
                    ),
                  ),
                  if (selected)
                    const Positioned(
                      top: -6,
                      right: -6,
                      child: _SelectedBadge(),
                    )
                  else if (locked)
                    const Positioned(
                      top: -6,
                      right: -6,
                      child: _LockedBadge(),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                variant.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (variant.tier == AppIconTier.supporter) ...<Widget>[
                const SizedBox(height: 2),
                _SupporterBadge(locked: locked),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The check badge pinned to the corner of the selected tile.
class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.surface, width: 2),
      ),
      child: Icon(Icons.check, size: 14, color: theme.colorScheme.onPrimary),
    );
  }
}

/// A compact lock marker for a Play supporter preview.
class _LockedBadge extends StatelessWidget {
  const _LockedBadge();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.surface, width: 2),
      ),
      child: Icon(
        Icons.lock_outline,
        size: 13,
        color: theme.colorScheme.onSecondaryContainer,
      ),
    );
  }
}

/// Neutral tier label. It identifies the cosmetic reward without showing a
/// price or implying that any music feature is restricted.
class _SupporterBadge extends StatelessWidget {
  const _SupporterBadge({required this.locked});

  final bool locked;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Text(
        locked ? 'Supporter' : 'Supporter',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
