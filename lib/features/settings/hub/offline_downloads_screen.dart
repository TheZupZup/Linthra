import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dimens.dart';
import '../../../app/routes.dart';
import '../network/network_settings_section.dart';
import 'settings_detail_scaffold.dart';

/// The "Offline & downloads" page of the Settings hub.
///
/// Hosts the Wi-Fi / mobile-data download policy and a shortcut to the
/// Downloads tab where the actual offline tracks are managed. The mobile-data
/// switch is the existing section, unchanged; the download/cache policy still
/// lives in the repository.
class OfflineDownloadsScreen extends StatelessWidget {
  const OfflineDownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: 'Offline & downloads',
      children: <Widget>[
        const NetworkSettingsSection(),
        const SizedBox(height: AppSpacing.md),
        _ManageDownloadsCard(onTap: () => context.go(AppRoutes.downloads)),
      ],
    );
  }
}

/// A shortcut into the Downloads tab, where tracks kept for offline play are
/// listed and managed. Switching tabs (rather than pushing) keeps the Downloads
/// screen the single home for that list.
class _ManageDownloadsCard extends StatelessWidget {
  const _ManageDownloadsCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: ListTile(
        leading:
            Icon(Icons.download_outlined, color: theme.colorScheme.primary),
        title: const Text('Manage downloads'),
        subtitle: Text(
          'See and remove the tracks you kept for offline play.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        trailing: Icon(Icons.chevron_right, color: muted),
        onTap: onTap,
      ),
    );
  }
}
