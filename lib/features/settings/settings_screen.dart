import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../core/app_info.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/layout/pane_layout.dart';
import '../appearance/selected_logo_mark.dart';
import 'hub/settings_categories.dart';
import 'hub/settings_category_tile.dart';
import 'settings_panes.dart';

/// The Settings hub: a short, scannable list of categories rather than one long
/// technical form. Each row opens its own page (Connections, Music & playback,
/// Cache & data, …) where the existing setting cards live, unchanged. Grouping
/// the options this way is the whole point — it reorganises Settings to feel
/// like a modern app, without changing what any setting does.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Beside the sidebar on a wide window the categories are already on
    // screen, so the hub's own page is just the empty pane (#753).
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
      // A settings row is a label and a control; on a wide window the column
      // stops growing rather than pulling the two apart.
      body: AdaptiveContentWidth(
        maxWidth: maxFormWidth,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: <Widget>[
            const SettingsBrandHeader(),
            for (final SettingsCategory category
                in settingsCategories(context)) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              SettingsCategoryTile(
                icon: category.icon,
                title: category.title,
                subtitle: category.subtitle,
                onTap: () => context.push(category.route),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact brand presence at the top of the hub: the Linthra mark, name, and
/// tagline. Keeps the identity in view without the full About panel (which lives
/// one tap away under "About").
class SettingsBrandHeader extends StatelessWidget {
  const SettingsBrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.sm,
      ),
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
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  AppInfo.tagline,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
