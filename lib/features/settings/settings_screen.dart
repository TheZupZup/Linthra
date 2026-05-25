import 'package:flutter/material.dart';

import '../../app/dimens.dart';
import '../../core/app_info.dart';
import '../../shared/widgets/linthra_logo_mark.dart';
import 'cache/cache_settings_section.dart';
import 'diagnostics/diagnostics_settings_section.dart';
import 'jellyfin/jellyfin_settings_section.dart';
import 'precache/precache_settings_section.dart';
import 'subsonic/subsonic_settings_section.dart';

/// Settings. Hosts the connection/source and offline-storage options, plus a
/// quiet brand/about footer. Theme and other options will join them here.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: const [
          JellyfinSettingsSection(),
          SizedBox(height: AppSpacing.md),
          SubsonicSettingsSection(),
          SizedBox(height: AppSpacing.md),
          CacheSettingsSection(),
          SizedBox(height: AppSpacing.md),
          PrecacheSettingsSection(),
          SizedBox(height: AppSpacing.md),
          DiagnosticsSettingsSection(),
          SizedBox(height: AppSpacing.md),
          _AboutCard(),
        ],
      ),
    );
  }
}

/// A calm brand footer: the Linthra mark, name, tagline, and version. Keeps the
/// identity present in-app without shouting.
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            const LinthraLogoMark(size: 44),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Version ${AppInfo.version}',
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
