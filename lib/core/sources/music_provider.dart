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
    required this.canRemoveFromLibrary,
    required this.canRemoveOfflineCopy,
    required this.canDeleteLocalFile,
    required this.canDeleteRemoteItem,
    required this.canCreatePlaylist,
    required this.canEditPlaylist,
    required this.canDeletePlaylist,
    required this.canSyncPlaylists,
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

  /// The track can be removed from Linthra's local catalog/index — a safe,
  /// reversible action that never deletes the underlying file or server item.
  /// True for every provider.
  final bool canRemoveFromLibrary;

  /// The provider's tracks can have an app-managed offline copy that Linthra may
  /// safely delete (the same managed cache the download repository owns).
  /// Whether a *specific* track actually has a copy to remove is a per-track
  /// download-status check on top of this static capability.
  final bool canRemoveOfflineCopy;

  /// Linthra can delete the underlying file from the device for this provider's
  /// tracks. Only meaningful for on-device files and only when platform
  /// permissions allow it safely; left `false` until that path is robust.
  final bool canDeleteLocalFile;

  /// Linthra can delete the underlying item from the provider's server/library.
  /// Strongly destructive (affects every device), so it is only enabled when it
  /// can be done safely with explicit confirmation; left `false` otherwise.
  final bool canDeleteRemoteItem;

  /// A playlist of this provider's kind can be created from Linthra.
  final bool canCreatePlaylist;

  /// A playlist of this provider's kind can be edited (rename, add/remove/reorder
  /// tracks) from Linthra.
  final bool canEditPlaylist;

  /// A playlist of this provider's kind can be deleted from Linthra.
  final bool canDeletePlaylist;

  /// Playlists can be synced with this provider's server (two-way where the API
  /// supports it).
  final bool canSyncPlaylists;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MusicProviderCapabilities &&
          other.canStream == canStream &&
          other.canCache == canCache &&
          other.canFavorite == canFavorite &&
          other.canLyrics == canLyrics &&
          other.canCast == canCast &&
          other.canRemoveFromLibrary == canRemoveFromLibrary &&
          other.canRemoveOfflineCopy == canRemoveOfflineCopy &&
          other.canDeleteLocalFile == canDeleteLocalFile &&
          other.canDeleteRemoteItem == canDeleteRemoteItem &&
          other.canCreatePlaylist == canCreatePlaylist &&
          other.canEditPlaylist == canEditPlaylist &&
          other.canDeletePlaylist == canDeletePlaylist &&
          other.canSyncPlaylists == canSyncPlaylists);

  @override
  int get hashCode => Object.hash(
        canStream,
        canCache,
        canFavorite,
        canLyrics,
        canCast,
        canRemoveFromLibrary,
        canRemoveOfflineCopy,
        canDeleteLocalFile,
        canDeleteRemoteItem,
        canCreatePlaylist,
        canEditPlaylist,
        canDeletePlaylist,
        canSyncPlaylists,
      );
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
      canRemoveFromLibrary: true,
      // On-device tracks are already local — there is no separate app-managed
      // copy to remove.
      canRemoveOfflineCopy: false,
      // Deleting the real on-device file is not wired up safely yet.
      canDeleteLocalFile: false,
      canDeleteRemoteItem: false,
      canCreatePlaylist: true,
      canEditPlaylist: true,
      canDeletePlaylist: true,
      canSyncPlaylists: false,
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
      canRemoveFromLibrary: true,
      canRemoveOfflineCopy: true,
      canDeleteLocalFile: false,
      // Server-side delete (removing the item from Jellyfin for every device)
      // is intentionally not enabled in this release; see
      // docs/playlists-and-delete.md.
      canDeleteRemoteItem: false,
      canCreatePlaylist: true,
      canEditPlaylist: true,
      canDeletePlaylist: true,
      canSyncPlaylists: true,
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
      canRemoveFromLibrary: true,
      canRemoveOfflineCopy: true,
      canDeleteLocalFile: false,
      canDeleteRemoteItem: false,
      // Subsonic/Navidrome playlists aren't synced yet; its tracks can still be
      // added to local Linthra playlists.
      canCreatePlaylist: false,
      canEditPlaylist: false,
      canDeletePlaylist: false,
      canSyncPlaylists: false,
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
