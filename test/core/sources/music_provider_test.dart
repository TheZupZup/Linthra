import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/music_provider.dart';

void main() {
  group('MusicProviders capabilities', () {
    test('local: plays and favorites on-device, but cannot cast', () {
      final caps = MusicProviders.local.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canFavoriteTracks, isTrue);
      expect(caps.canReadFavoriteState, isTrue);
      // On-device favourites stay local — there's no server to sync them to.
      expect(caps.canSyncFavorites, isFalse);
      expect(caps.canListPlaylists, isFalse);
      expect(caps.canCast, isFalse);
      expect(caps.canCache, isFalse);
    });

    test('jellyfin: full capabilities', () {
      final caps = MusicProviders.jellyfin.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canCache, isTrue);
      expect(caps.canFavoriteTracks, isTrue);
      expect(caps.canReadFavoriteState, isTrue);
      expect(caps.canSyncFavorites, isTrue);
      expect(caps.canListPlaylists, isTrue);
      expect(caps.canLyrics, isTrue);
      expect(caps.canCast, isTrue);
    });

    test('subsonic: stream/cache/cast/lyrics implemented; favorites are not',
        () {
      final caps = MusicProviders.subsonic.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canCache, isTrue);
      expect(caps.canCast, isTrue);
      // Lyrics arrive via the OpenSubsonic getLyricsBySongId extension
      // (Navidrome) with a legacy getLyrics fallback.
      expect(caps.canLyrics, isTrue);
      // Declared unsupported so their actions stay hidden/disabled.
      expect(caps.canFavoriteTracks, isFalse);
      expect(caps.canReadFavoriteState, isFalse);
      expect(caps.canSyncFavorites, isFalse);
      expect(caps.canListPlaylists, isFalse);
    });

    test('identity fields', () {
      expect(MusicProviders.subsonic.sourceId, 'subsonic');
      expect(MusicProviders.subsonic.displayName, 'Navidrome / Subsonic');
      expect(MusicProviders.subsonic.serverUrlLabel, 'Server URL');
      expect(MusicProviders.local.serverUrlLabel, isNull);
    });

    test('remove/delete capabilities are safe by default', () {
      // Every provider allows the safe, reversible "remove from library".
      expect(MusicProviders.local.capabilities.canRemoveFromLibrary, isTrue);
      expect(MusicProviders.jellyfin.capabilities.canRemoveFromLibrary, isTrue);
      expect(MusicProviders.subsonic.capabilities.canRemoveFromLibrary, isTrue);

      // On-device tracks have no app-managed offline copy to remove; remote
      // providers do.
      expect(MusicProviders.local.capabilities.canRemoveOfflineCopy, isFalse);
      expect(MusicProviders.jellyfin.capabilities.canRemoveOfflineCopy, isTrue);

      // Destructive file/server deletes are not enabled in this release for any
      // provider, so those actions stay hidden everywhere.
      for (final caps in <MusicProviderCapabilities>[
        MusicProviders.local.capabilities,
        MusicProviders.jellyfin.capabilities,
        MusicProviders.subsonic.capabilities,
      ]) {
        expect(caps.canDeleteLocalFile, isFalse);
        expect(caps.canDeleteRemoteItem, isFalse);
      }
    });

    test('playlist capabilities reflect provider support', () {
      expect(MusicProviders.local.capabilities.canCreatePlaylist, isTrue);
      expect(MusicProviders.local.capabilities.canSyncPlaylists, isFalse);

      expect(MusicProviders.jellyfin.capabilities.canCreatePlaylist, isTrue);
      expect(MusicProviders.jellyfin.capabilities.canEditPlaylist, isTrue);
      expect(MusicProviders.jellyfin.capabilities.canDeletePlaylist, isTrue);
      expect(MusicProviders.jellyfin.capabilities.canSyncPlaylists, isTrue);

      // Subsonic playlists aren't synced yet.
      expect(MusicProviders.subsonic.capabilities.canSyncPlaylists, isFalse);
    });

    test('favorite capabilities reflect provider support', () {
      // Jellyfin reads, toggles, and two-way syncs favourites against the
      // server; local toggles/reads on-device only; Subsonic does neither yet.
      final jelly = MusicProviders.jellyfin.capabilities;
      expect(jelly.canReadFavoriteState, isTrue);
      expect(jelly.canFavoriteTracks, isTrue);
      expect(jelly.canSyncFavorites, isTrue);

      final local = MusicProviders.local.capabilities;
      expect(local.canFavoriteTracks, isTrue);
      expect(local.canSyncFavorites, isFalse);

      expect(MusicProviders.subsonic.capabilities.canFavoriteTracks, isFalse);
    });

    test('a future provider seam is data-driven via a fake provider', () {
      // The capability matrix is a plain value, so a not-yet-shipped provider
      // (e.g. a richer Navidrome) can declare its abilities and be tested/
      // compared without touching any feature code.
      const MusicProvider future = MusicProvider(
        sourceId: 'navidrome-future',
        displayName: 'Future Navidrome',
        serverUrlLabel: 'Server URL',
        capabilities: MusicProviderCapabilities(
          canStream: true,
          canCache: true,
          canFavoriteTracks: true,
          canReadFavoriteState: true,
          canSyncFavorites: true,
          canLyrics: false,
          canCast: true,
          canRemoveFromLibrary: true,
          canRemoveOfflineCopy: true,
          canDeleteLocalFile: false,
          canDeleteRemoteItem: false,
          canListPlaylists: true,
          canCreatePlaylist: true,
          canEditPlaylist: true,
          canDeletePlaylist: true,
          canSyncPlaylists: true,
        ),
      );

      expect(future.capabilities.canListPlaylists, isTrue);
      expect(future.capabilities.canSyncFavorites, isTrue);
      // Value equality lets a UI compare capability sets directly.
      expect(
        future.capabilities,
        const MusicProviderCapabilities(
          canStream: true,
          canCache: true,
          canFavoriteTracks: true,
          canReadFavoriteState: true,
          canSyncFavorites: true,
          canLyrics: false,
          canCast: true,
          canRemoveFromLibrary: true,
          canRemoveOfflineCopy: true,
          canDeleteLocalFile: false,
          canDeleteRemoteItem: false,
          canListPlaylists: true,
          canCreatePlaylist: true,
          canEditPlaylist: true,
          canDeletePlaylist: true,
          canSyncPlaylists: true,
        ),
      );
    });
  });

  group('MusicProviders.forTrackUri', () {
    test('routes by scheme', () {
      expect(MusicProviders.forTrackUri('subsonic:abc'),
          same(MusicProviders.subsonic));
      expect(MusicProviders.forTrackUri('jellyfin:abc'),
          same(MusicProviders.jellyfin));
      expect(MusicProviders.forTrackUri('/music/song.mp3'),
          same(MusicProviders.local));
      expect(MusicProviders.forTrackUri('content://media/x'),
          same(MusicProviders.local));
    });

    test('capabilitiesForTrackUri matches the resolved provider', () {
      expect(
        MusicProviders.capabilitiesForTrackUri('subsonic:1'),
        MusicProviders.subsonic.capabilities,
      );
    });
  });
}
