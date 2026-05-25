import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/music_provider.dart';

void main() {
  group('MusicProviders capabilities', () {
    test('local: plays and favorites on-device, but cannot cast', () {
      final caps = MusicProviders.local.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canFavorite, isTrue);
      expect(caps.canCast, isFalse);
      expect(caps.canCache, isFalse);
    });

    test('jellyfin: full capabilities', () {
      final caps = MusicProviders.jellyfin.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canCache, isTrue);
      expect(caps.canFavorite, isTrue);
      expect(caps.canLyrics, isTrue);
      expect(caps.canCast, isTrue);
    });

    test('subsonic: stream/cache/cast implemented; favorites & lyrics are not',
        () {
      final caps = MusicProviders.subsonic.capabilities;
      expect(caps.canStream, isTrue);
      expect(caps.canCache, isTrue);
      expect(caps.canCast, isTrue);
      // Declared unsupported so their actions stay hidden/disabled.
      expect(caps.canFavorite, isFalse);
      expect(caps.canLyrics, isFalse);
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
