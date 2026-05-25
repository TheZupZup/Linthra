import 'package:flutter/foundation.dart';

import 'jellyfin/jellyfin_track_mapper.dart';
import 'subsonic/subsonic_track_mapper.dart';

/// What a music provider can do, so the UI can show only the actions a given
/// source actually supports rather than offering ones that would silently fail.
///
/// This is the capability model the roadmap calls for: each provider declares
/// its abilities once, here, and features read them (e.g. a cast affordance is
/// only meaningful when [canCast]). Keeping it a plain value makes the matrix
/// trivial to unit-test and a single source of truth as providers are added.
@immutable
class MusicProviderCapabilities {
  const MusicProviderCapabilities({
    required this.canStream,
    required this.canCache,
    required this.canFavorite,
    required this.canLyrics,
    required this.canCast,
  });

  /// Tracks can be played by resolving a stream URL at play time.
  final bool canStream;

  /// Tracks can be downloaded for offline use safely (a token-free cache file).
  final bool canCache;

  /// Favorites can be toggled and reflected for this provider.
  final bool canFavorite;

  /// Lyrics can be fetched for this provider's tracks.
  final bool canLyrics;

  /// A track's playback URL is network-reachable, so it can be handed to a Cast
  /// receiver. False for on-device files a receiver can't reach.
  final bool canCast;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MusicProviderCapabilities &&
          other.canStream == canStream &&
          other.canCache == canCache &&
          other.canFavorite == canFavorite &&
          other.canLyrics == canLyrics &&
          other.canCast == canCast);

  @override
  int get hashCode =>
      Object.hash(canStream, canCache, canFavorite, canLyrics, canCast);
}

/// The identity + capabilities of one music provider (local files, Jellyfin,
/// Subsonic/Navidrome). The [serverUrlLabel] is the field label a settings
/// section shows for the server address, or null for the on-device source which
/// has no server.
@immutable
class MusicProvider {
  const MusicProvider({
    required this.sourceId,
    required this.displayName,
    required this.serverUrlLabel,
    required this.capabilities,
  });

  final String sourceId;
  final String displayName;
  final String? serverUrlLabel;
  final MusicProviderCapabilities capabilities;
}

/// The registry of known providers and the lookup from a [Track.uri] to the
/// provider that owns it. The lookup keys off the same `scheme:` prefixes the
/// resolvers use, so capabilities and routing can never disagree.
abstract final class MusicProviders {
  static const MusicProvider local = MusicProvider(
    sourceId: 'local',
    displayName: 'On this device',
    serverUrlLabel: null,
    capabilities: MusicProviderCapabilities(
      canStream: true,
      canCache: false,
      canFavorite: true,
      canLyrics: false,
      canCast: false,
    ),
  );

  static const MusicProvider jellyfin = MusicProvider(
    sourceId: 'jellyfin',
    displayName: 'Jellyfin',
    serverUrlLabel: 'Server URL',
    capabilities: MusicProviderCapabilities(
      canStream: true,
      canCache: true,
      canFavorite: true,
      canLyrics: true,
      canCast: true,
    ),
  );

  /// Subsonic/Navidrome. Streaming, offline caching, and casting are
  /// implemented; favorites and lyrics are documented follow-ups, so they are
  /// declared unsupported here and their actions stay hidden/disabled.
  static const MusicProvider subsonic = MusicProvider(
    sourceId: 'subsonic',
    displayName: 'Navidrome / Subsonic',
    serverUrlLabel: 'Server URL',
    capabilities: MusicProviderCapabilities(
      canStream: true,
      canCache: true,
      canFavorite: false,
      canLyrics: false,
      canCast: true,
    ),
  );

  /// The provider that owns [trackUri], by its `scheme:` prefix. Anything not a
  /// known remote scheme is an on-device ([local]) track.
  static MusicProvider forTrackUri(String trackUri) {
    if (trackUri.startsWith(JellyfinTrackMapper.uriScheme)) return jellyfin;
    if (trackUri.startsWith(SubsonicTrackMapper.uriScheme)) return subsonic;
    return local;
  }

  /// The capabilities of the provider that owns [trackUri].
  static MusicProviderCapabilities capabilitiesForTrackUri(String trackUri) =>
      forTrackUri(trackUri).capabilities;
}
