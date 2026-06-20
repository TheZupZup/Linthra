import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../source/provider_summary_cards.dart';
import 'settings_detail_scaffold.dart';

/// The "Connections" page of the Settings hub.
///
/// Stacks the existing music-source cards — Jellyfin, Navidrome/Subsonic, Plex,
/// and Local music — each of which already shows status and offers edit /
/// reconnect / remove behind its own "Manage" sheet. This page only groups the
/// cards; how a source connects or syncs is unchanged.
class ConnectionsSettingsScreen extends StatelessWidget {
  const ConnectionsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsDetailScaffold(
      title: 'Connections',
      children: <Widget>[
        JellyfinProviderCard(),
        SizedBox(height: AppSpacing.md),
        SubsonicProviderCard(),
        SizedBox(height: AppSpacing.md),
        // Plex supports streaming, lyrics, and offline caching; advanced
        // features (cast, favorites, playlists) are not offered until they ship.
        PlexProviderCard(),
        SizedBox(height: AppSpacing.md),
        // Local music is a connection here, deliberately kept away from the
        // offline-downloads page so it is not confused with offline downloads.
        LocalMusicProviderCard(),
      ],
    );
  }
}
