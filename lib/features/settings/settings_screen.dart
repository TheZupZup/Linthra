import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../core/app_info.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/layout/pane_layout.dart';
import '../appearance/selected_logo_mark.dart';
import '../support/support_actions_provider.dart';
import 'hub/settings_categories.dart';
import 'hub/settings_category_tile.dart';
import 'settings_panes.dart';

/// A compact Settings hub, grouped the same way as the desktop sidebar.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool showSupport = ref.watch(supportLinksEnabledProvider);
    final categories = settingsCategories(context, showSupport: showSupport);

    if (SettingsPanesScope.isSplit(context)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const DetailPanePlaceholder(
          icon: Icons.settings_outlined,
          message: 'Pick a category to see its settings.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AdaptiveContentWidth(
        maxWidth: maxFormWidth,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: <Widget>[
            const SettingsBrandHeader(),
            for (final SettingsSection section in SettingsSection.values)
              _SettingsGroup(section: section, categories: categories),
            if (showSupport) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              _SupportCard(onTap: () => context.push(categories.last.route)),
            ],
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}

/// Several destinations share one card instead of each taking a full card.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.section,
    required this.categories,
  });

  final SettingsSection section;
  final List<SettingsCategory> categories;

  @override
  Widget build(BuildContext context) {
    final List<SettingsCategory> items = <SettingsCategory>[
      for (final SettingsCategory category in categories)
        if (category.section == section && !category.prominent) category,
    ];

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.sm,
              bottom: AppSpacing.sm,
            ),
            child: Text(
              section.title.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < items.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  SettingsCategoryTile(
                    icon: items[i].icon,
                    title: items[i].title,
                    subtitle: items[i].subtitle,
                    onTap: () => context.push(items[i].route),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A separate, optional invitation. No popups or constant glowing animation.
class _SupportCard extends StatelessWidget {
  const _SupportCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color muted = colors.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: Color.alphaBlend(
        colors.primary.withValues(alpha: 0.08),
        colors.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: colors.primary.withValues(alpha: 0.55)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Icon(Icons.favorite_outline, color: colors.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Support Linthra',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Help keep Linthra free and open source. '
                      'Support is always optional.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Linthra's identity at the top of Settings, with a single gentle entrance.
class SettingsBrandHeader extends StatelessWidget {
  const SettingsBrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color muted = colors.onSurfaceVariant;

    return TweenAnimationBuilder<double>(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (BuildContext context, double progress, Widget? child) {
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(0, (1 - progress) * AppSpacing.sm),
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                colors.primary.withValues(alpha: 0.22),
                colors.surfaceContainerHigh,
              ],
            ),
          ),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _HeaderWavePainter(colors.primary),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: <Widget>[
                    const SelectedLinthraLogoMark(size: 40),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            AppInfo.name,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            AppInfo.tagline,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Decorative wave. Static after the entrance animation, so it costs no frames.
class _HeaderWavePainter extends CustomPainter {
  const _HeaderWavePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Path wave = Path()
      ..moveTo(0, size.height * 0.88)
      ..quadraticBezierTo(
        size.width * 0.32,
        size.height * 0.40,
        size.width * 0.62,
        size.height * 0.72,
      )
      ..quadraticBezierTo(
        size.width * 0.85,
        size.height * 0.95,
        size.width,
        size.height * 0.40,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      wave,
      Paint()..color = color.withValues(alpha: 0.12),
    );
  }

  @override
  bool shouldRepaint(_HeaderWavePainter oldDelegate) =>
      oldDelegate.color != color;
}
