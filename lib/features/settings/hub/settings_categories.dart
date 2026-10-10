import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../network/metered_network_wording.dart';

/// One category of the Settings hub.
///
/// The hub lists these as cards on a phone, and a wide window lists them again
/// as the sidebar beside the open page (#753). Both read this one list, so the
/// two can never disagree about what Settings holds or where a row goes.
@immutable
class SettingsCategory {
  const SettingsCategory({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
    this.opensPage = true,
    this.pagesWithin = const <String>[],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  /// Whether [route] is a settings page, shown beside the sidebar on a wide
  /// window. The welcome tour is not: it runs full screen over the whole app,
  /// so its row starts it rather than selecting anything.
  final bool opensPage;

  /// Pages reached from inside this category's own page, which keep it
  /// selected in the sidebar while they are open (Support from About, say).
  final List<String> pagesWithin;
}

/// The hub's categories, top to bottom.
List<SettingsCategory> settingsCategories(BuildContext context) {
  return <SettingsCategory>[
    const SettingsCategory(
      icon: Icons.hub_outlined,
      title: 'Connections',
      subtitle: 'Jellyfin, Plex, Navidrome/Subsonic, local files, '
          'Audiobookshelf',
      route: AppRoutes.settingsConnections,
      pagesWithin: <String>[AppRoutes.audiobooks],
    ),
    const SettingsCategory(
      icon: Icons.play_circle_outline,
      title: 'Music & playback',
      subtitle: 'Default source and playback behaviour',
      route: AppRoutes.settingsPlayback,
    ),
    const SettingsCategory(
      icon: Icons.sd_storage_outlined,
      title: 'Cache & data',
      subtitle: 'Smart pre-cache and cache size',
      route: AppRoutes.settingsCache,
    ),
    SettingsCategory(
      icon: Icons.download_outlined,
      title: 'Offline & downloads',
      subtitle: MeteredNetworkWording.of(context).hubSubtitle,
      route: AppRoutes.settingsDownloads,
    ),
    const SettingsCategory(
      icon: Icons.palette_outlined,
      title: 'Appearance',
      subtitle: 'App icon and in-app branding',
      route: AppRoutes.settingsAppearance,
    ),
    const SettingsCategory(
      icon: Icons.auto_awesome_outlined,
      title: 'Welcome tour',
      subtitle: 'Replay the Linthra introduction and music-source guide',
      route: AppRoutes.onboardingReplay,
      opensPage: false,
    ),
    const SettingsCategory(
      icon: Icons.help_outline,
      title: 'Diagnostics & support',
      subtitle: 'Report a bug, copy diagnostics',
      route: AppRoutes.settingsDiagnostics,
      pagesWithin: <String>[AppRoutes.reportBug],
    ),
    const SettingsCategory(
      icon: Icons.info_outline,
      title: 'About',
      subtitle: 'Version, support, and project links',
      route: AppRoutes.settingsAbout,
      pagesWithin: <String>[AppRoutes.settingsSupport],
    ),
  ];
}

/// The category that a stack of settings pages belongs to, bottom page first.
///
/// The first category page in the stack decides it, so Support opened from
/// Appearance's theme card keeps Appearance selected. A stack with no category
/// page in it (a deep link straight to Support) falls back to the category
/// that page normally lives in. Null when only the hub is open.
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
