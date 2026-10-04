import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/app_info.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../appearance/selected_logo_mark.dart';
import 'hub/settings_category_tile.dart';
import 'network/metered_network_wording.dart';

/// The Settings hub: a short, scannable list of categories rather than one long
/// technical form. Each row opens its own page (Connections, Music & playback,
/// Cache & data, …) where the existing setting cards live, unchanged. Grouping
/// the options this way is the whole point — it reorganises Settings to feel
/// like a modern app, without changing what any setting does.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // A settings row is a label and a control; on a wide window the column
      // stops growing rather than pulling the two apart.
      body: AdaptiveContentWidth(
        maxWidth: maxFormWidth,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: <Widget>[
            const _BrandHeader(),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.hub_outlined,
              title: 'Connections',
              subtitle: 'Jellyfin, Plex, Navidrome/Subsonic, local files, '
                  'Audiobookshelf',
              onTap: () => context.push(AppRoutes.settingsConnections),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.play_circle_outline,
              title: 'Music & playback',
              subtitle: 'Default source and playback behaviour',
              onTap: () => context.push(AppRoutes.settingsPlayback),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.sd_storage_outlined,
              title: 'Cache & data',
              subtitle: 'Smart pre-cache and cache size',
              onTap: () => context.push(AppRoutes.settingsCache),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.download_outlined,
              title: 'Offline & downloads',
              subtitle: MeteredNetworkWording.of(context).hubSubtitle,
              onTap: () => context.push(AppRoutes.settingsDownloads),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.palette_outlined,
              title: 'Appearance',
              subtitle: 'App icon and in-app branding',
              onTap: () => context.push(AppRoutes.settingsAppearance),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.auto_awesome_outlined,
              title: 'Welcome tour',
              subtitle:
                  'Replay the Linthra introduction and music-source guide',
              onTap: () => context.push(AppRoutes.onboardingReplay),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.help_outline,
              title: 'Diagnostics & support',
              subtitle: 'Report a bug, copy diagnostics',
              onTap: () => context.push(AppRoutes.settingsDiagnostics),
            ),
            const SizedBox(height: AppSpacing.md),
            SettingsCategoryTile(
              icon: Icons.info_outline,
              title: 'About',
              subtitle: 'Version, support, and project links',
              onTap: () => context.push(AppRoutes.settingsAbout),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact brand presence at the top of the hub: the Linthra mark, name, and
/// tagline. Keeps the identity in view without the full About panel (which lives
/// one tap away under "About").
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

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
