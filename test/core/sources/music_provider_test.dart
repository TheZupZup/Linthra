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
