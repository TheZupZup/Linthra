import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/playback_source_label.dart';

void main() {
  group('PlaybackSourceLabel.of — the copy actually playing', () {
    test('an on-device file reads as Local files', () {
      expect(
        PlaybackSourceLabel.of(
          trackUri: '/music/song.mp3',
          source: PlaybackSource.localFile,
        ),
        'Local files',
      );
    });

    test('a direct Jellyfin stream names Jellyfin', () {
      expect(
        PlaybackSourceLabel.of(
          trackUri: 'jellyfin:abc',
          source: PlaybackSource.streamingDirect,
        ),
        'Jellyfin',
      );
    });

    test('a direct Subsonic stream names Navidrome', () {
      expect(
        PlaybackSourceLabel.of(
          trackUri: 'subsonic:abc',
          source: PlaybackSource.streamingDirect,
        ),
        'Navidrome',
      );
    });

    test('a cached copy reads as Cache regardless of the owning server', () {
      expect(
        PlaybackSourceLabel.of(
          trackUri: 'jellyfin:abc',
          source: PlaybackSource.offlineCache,
        ),
        'Cache',
      );
      expect(
        PlaybackSourceLabel.of(
          trackUri: 'subsonic:abc',
          source: PlaybackSource.offlineCache,
        ),
        'Cache',
      );
    });

    test('no resolved source reads as Unknown source', () {
      expect(
        PlaybackSourceLabel.of(trackUri: 'jellyfin:abc', source: null),
        'Unknown source',
      );
    });
  });

  group('PlaybackSourceLabel.phrase', () {
    test('prefixes the safe name with "Playing from"', () {
      expect(
        PlaybackSourceLabel.phrase(
          trackUri: 'subsonic:abc',
          source: PlaybackSource.streamingDirect,
        ),
        'Playing from Navidrome',
      );
    });
  });
}
