import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../audiobookshelf/audiobookshelf_provider_card.dart';
import '../local_network/local_network_access_card.dart';
import '../source/provider_summary_cards.dart';
import 'settings_detail_scaffold.dart';

/// The "Connections" page of the Settings hub.
///
/// Stacks the existing music-source cards — Jellyfin, Navidrome/Subsonic, Plex,
/// and Local music — each of which already shows status and offers edit /
/// reconnect / remove behind its own "Manage" sheet, then the audiobook
/// connection under its own heading. This page only groups the cards; how a
/// source connects or syncs is unchanged.
class ConnectionsSettingsScreen extends StatelessWidget {
  const ConnectionsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsDetailScaffold(
      title: 'Connections',
      children: <Widget>[
        // Empty unless Android 17's local network access is missing for a
        // server the user set up on their own network.
        LocalNetworkAccessCard(),
        _SectionHeading('Music'),
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
        SizedBox(height: AppSpacing.lg),
        // Audiobooks are their own thing, not a music source: Audiobookshelf
        // has its own session and never syncs into the music catalog, so it
        // gets its own heading instead of sitting in the list above.
        _SectionHeading('Audiobooks'),
        AudiobookshelfProviderCard(),
      ],
    );
  }
}

/// A small group label above a run of cards. Only two groups exist, so this
/// stays a plain heading rather than a new shared component.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.xs,
        bottom: AppSpacing.sm,
      ),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
