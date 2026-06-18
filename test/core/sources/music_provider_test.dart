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
      // Sidecar .lrc/.txt lyrics (LocalLyricsProvider) — the docs/providers.md
      // matrix has said ✅ since they shipped.
      expect(caps.canLyrics, isTrue);
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

    test('plex: stream/cache/lyrics implemented; server writes stay off', () {
      final caps = MusicProviders.plex.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canCache, isTrue);
      expect(caps.canRemoveOfflineCopy, isTrue);
      // Lyrics are fetched on demand from the track's Plex lyric stream (synced
      // `.lrc` or plain), so they read ✅ — the one capability beyond playback
      // and offline caching.
      expect(caps.canLyrics, isTrue);
      // Everything else is declared unsupported so its actions stay hidden/
      // disabled rather than failing — exactly how Subsonic deferred features.
      expect(caps.canFavoriteTracks, isFalse);
      expect(caps.canReadFavoriteState, isFalse);
      expect(caps.canSyncFavorites, isFalse);
      // Cast stays off for now to keep the credential-in-URL surface small.
      expect(caps.canCast, isFalse);
      expect(caps.canListPlaylists, isFalse);
      expect(caps.canCreatePlaylist, isFalse);
      expect(caps.canEditPlaylist, isFalse);
      expect(caps.canDeletePlaylist, isFalse);
      expect(caps.canSyncPlaylists, isFalse);
    });

    test('identity fields', () {
      expect(MusicProviders.subsonic.sourceId, 'subsonic');
      expect(MusicProviders.subsonic.displayName, 'Navidrome / Subsonic');
      expect(MusicProviders.subsonic.serverUrlLabel, 'Server URL');
      expect(MusicProviders.local.serverUrlLabel, isNull);
      expect(MusicProviders.plex.sourceId, 'plex');
      expect(MusicProviders.plex.displayName, 'Plex');
      expect(MusicProviders.plex.serverUrlLabel, 'Server URL');
    });

    test('remove/delete capabilities are safe by default', () {
      // Every provider allows the safe, reversible "remove from library".
      expect(MusicProviders.local.capabilities.canRemoveFromLibrary, isTrue);
      expect(MusicProviders.jellyfin.capabilities.canRemoveFromLibrary, isTrue);
      expect(MusicProviders.subsonic.capabilities.canRemoveFromLibrary, isTrue);
      expect(MusicProviders.plex.capabilities.canRemoveFromLibrary, isTrue);

      // On-device tracks have no app-managed offline copy to remove; remote
      // providers with offline cache support do.
      expect(MusicProviders.local.capabilities.canRemoveOfflineCopy, isFalse);
      expect(MusicProviders.jellyfin.capabilities.canRemoveOfflineCopy, isTrue);
      expect(MusicProviders.subsonic.capabilities.canRemoveOfflineCopy, isTrue);
      expect(MusicProviders.plex.capabilities.canRemoveOfflineCopy, isTrue);

      // Destructive file/server deletes are not enabled in this release for any
      // provider, so those actions stay hidden everywhere. Plex is additionally
      // library-read-only by design and never deletes items from PMS.
      for (final caps in <MusicProviderCapabilities>[
        MusicProviders.local.capabilities,
        MusicProviders.jellyfin.capabilities,
        MusicProviders.subsonic.capabilities,
        MusicProviders.plex.capabilities,
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
      expect(MusicProviders.forTrackUri('plex:101'), same(MusicProviders.plex));
      expect(MusicProviders.forTrackUri('/music/song.mp3'),
          same(MusicProviders.local));
      expect(MusicProviders.forTrackUri('content://media/x'),
          same(MusicProviders.local));
    });

    test('registering plex did not change how existing URIs route', () {
      // The no-regression guard docs/plex.md calls for: the only shared-code
      // edit Plex makes is its own forTrackUri branch, so every URI shape the
      // existing providers produce must keep resolving exactly as before.
      expect(MusicProviders.forTrackUri('jellyfin:item-42'),
          same(MusicProviders.jellyfin));
      expect(MusicProviders.forTrackUri('subsonic:mf-7'),
          same(MusicProviders.subsonic));
      expect(MusicProviders.forTrackUri('/storage/emulated/0/Music/a.flac'),
          same(MusicProviders.local));
      expect(MusicProviders.forTrackUri('content://com.android.docs/tree/x'),
          same(MusicProviders.local));
      expect(MusicProviders.forTrackUri('file:///music/song.ogg'),
          same(MusicProviders.local));
      // Near-misses of the plex: scheme stay on-device rather than routing to
      // Plex; the artwork scheme is not a track scheme.
      expect(
          MusicProviders.forTrackUri('plexamp:1'), same(MusicProviders.local));
      expect(MusicProviders.forTrackUri('plex-thumb:/library/x'),
          same(MusicProviders.local));
    });

    test('capabilitiesForTrackUri matches the resolved provider', () {
      expect(
        MusicProviders.capabilitiesForTrackUri('subsonic:1'),
        MusicProviders.subsonic.capabilities,
      );
      expect(
        MusicProviders.capabilitiesForTrackUri('plex:1'),
        MusicProviders.plex.capabilities,
      );
    });
  });
}
