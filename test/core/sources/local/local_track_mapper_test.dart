import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';

void main() {
  group('LocalTrackMapper.fromPath', () {
    test('uses the file name without extension as the title', () {
      final track = LocalTrackMapper.fromPath('/music/Holocene.mp3');
      expect(track.title, 'Holocene');
    });

    test('keeps the full path as both id and uri', () {
      const path = '/music/Bon Iver/Holocene.flac';
      final track = LocalTrackMapper.fromPath(path);
      expect(track.id, path);
      expect(track.uri, path);
    });

    test('preserves spaces and punctuation in the title', () {
      final track = LocalTrackMapper.fromPath('/music/01 - Intro (Live).m4a');
      expect(track.title, '01 - Intro (Live)');
    });

    test('only strips the final extension when the name has dots', () {
      final track = LocalTrackMapper.fromPath('/music/a.b.c.opus');
      expect(track.title, 'a.b.c');
    });

    test('leaves metadata minimal until tag parsing exists', () {
      final track = LocalTrackMapper.fromPath('/music/song.wav');
      expect(track.artistName, isNull);
      expect(track.albumName, isNull);
      expect(track.duration, Duration.zero);
      expect(track.trackNumber, isNull);
      expect(track.artworkUri, isNull);
    });

    test('produces tracks that are equal by path identity', () {
      final a = LocalTrackMapper.fromPath('/music/song.mp3');
      final b = LocalTrackMapper.fromPath('/music/song.mp3');
      expect(a, b);
    });
  });
}
