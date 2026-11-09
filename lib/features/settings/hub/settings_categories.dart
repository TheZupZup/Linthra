import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../network/metered_network_wording.dart';

/// The same Settings sections on phones and in the desktop sidebar.
enum SettingsSection {
  musicLibrary('Music & library'),
  storageOffline('Storage & offline'),
  personalization('Personalization'),
  aboutHelp('About & help');

  const SettingsSection(this.title);

  final String title;
}

/// One destination in Settings. Presentation belongs to the hub and sidebar.
@immutable
class SettingsCategory {
  const SettingsCategory({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
    required this.section,
    this.prominent = false,
    this.opensPage = true,
    this.pagesWithin = const <String>[],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
  final SettingsSection section;

  /// Support is a separate callout, not another row inside About & help.
  final bool prominent;

  /// Non-page destinations (if any) open outside the Settings pane.
  final bool opensPage;

  /// Child routes which keep their parent category selected in the sidebar.
  final List<String> pagesWithin;
}

/// One source of truth for mobile Settings and the Linux sidebar.
List<SettingsCategory> settingsCategories(
  BuildContext context, {
  required bool showSupport,
}) {
  return <SettingsCategory>[
    const SettingsCategory(
      icon: Icons.hub_outlined,
      title: 'Connections',
      subtitle: 'Jellyfin, Plex, Navidrome/Subsonic, local files, '
          'Audiobookshelf',
      route: AppRoutes.settingsConnections,
      section: SettingsSection.musicLibrary,
      pagesWithin: <String>[AppRoutes.audiobooks],
    ),
    const SettingsCategory(
      icon: Icons.play_circle_outline,
      title: 'Music & playback',
      subtitle: 'Default source and playback behaviour',
      route: AppRoutes.settingsPlayback,
      section: SettingsSection.musicLibrary,
    ),
    const SettingsCategory(
      icon: Icons.sd_storage_outlined,
      title: 'Cache & data',
      subtitle: 'Smart pre-cache and cache size',
      route: AppRoutes.settingsCache,
      section: SettingsSection.storageOffline,
    ),
    SettingsCategory(
      icon: Icons.download_outlined,
      title: 'Offline & downloads',
      subtitle: MeteredNetworkWording.of(context).hubSubtitle,
      route: AppRoutes.settingsDownloads,
      section: SettingsSection.storageOffline,
    ),
    const SettingsCategory(
      icon: Icons.palette_outlined,
      title: 'Appearance',
      subtitle: 'App icon and in-app branding',
      route: AppRoutes.settingsAppearance,
      section: SettingsSection.personalization,
    ),
    const SettingsCategory(
      icon: Icons.help_outline,
      title: 'Diagnostics & support',
      subtitle: 'Report a bug, copy diagnostics',
      route: AppRoutes.settingsDiagnostics,
      section: SettingsSection.aboutHelp,
      pagesWithin: <String>[AppRoutes.reportBug],
    ),
    const SettingsCategory(
      icon: Icons.info_outline,
      title: 'About',
      subtitle: 'Version, help, and project links',
      route: AppRoutes.settingsAbout,
      section: SettingsSection.aboutHelp,
    ),
    if (showSupport)
      const SettingsCategory(
        icon: Icons.favorite_outline,
        title: 'Support Linthra',
        subtitle: 'Help keep Linthra free and open source',
        route: AppRoutes.settingsSupport,
        section: SettingsSection.aboutHelp,
        prominent: true,
      ),
  ];
}

/// Choose the active sidebar category from the navigator's route stack.
SettingsCategory? selectedSettingsCategory(
  List<SettingsCategory> categories,
  Iterable<String> stack,
) {
  final List<SettingsCategory> pages = <SettingsCategory>[
    for (final SettingsCategory category in categories)
      if (category.opensPage) category,
  ];
  for (final String location in stack) {
    for (final SettingsCategory category in pages) {
      if (category.route == location) return category;
    }
  }
  for (final String location in stack) {
    for (final SettingsCategory category in pages) {
      if (category.pagesWithin.contains(location)) return category;
    }
  }
  return null;
}
