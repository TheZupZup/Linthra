import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';

Track _track({String? artist, String? album}) => Track(
      id: '1',
      title: 'Song',
      uri: 'file:///s.mp3',
      artistName: artist,
      albumName: album,
    );

void main() {
  group('Track.artistAlbumLabel', () {
    test('joins artist and album with a bullet', () {
      expect(
        _track(artist: 'Artist', album: 'Album').artistAlbumLabel,
        'Artist • Album',
      );
    });

    test('keeps a lone artist or a lone album', () {
      expect(_track(artist: 'Artist').artistAlbumLabel, 'Artist');
      expect(_track(album: 'Album').artistAlbumLabel, 'Album');
    });

    test('is empty when neither is present, so callers can pick a fallback',
        () {
      expect(_track().artistAlbumLabel, isEmpty);
      // Whitespace-free empty strings count as missing too.
      expect(_track(artist: '', album: '').artistAlbumLabel, isEmpty);
    });
  });

  group('Track identity (== / hashCode)', () {
    Track jelly(String id) => Track(id: id, title: 't', uri: 'jellyfin:$id');
    Track sub(String id) => Track(id: id, title: 't', uri: 'subsonic:$id');

    test('two copies sharing a uri are equal and hash the same', () {
      // A metadata-only refresh keeps the uri, so it still compares equal.
      final Track a = jelly('101');
      final Track b = jelly('101')
          .copyWith(title: 'refreshed', duration: const Duration(minutes: 4));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('the same bare id from two providers is not equal', () {
      expect(jelly('101'), isNot(sub('101')));
      expect(jelly('101').hashCode, isNot(sub('101').hashCode));
    });

    test('same-id copies stay distinct in a Set (no collision)', () {
      final Set<Track> set = <Track>{jelly('101'), sub('101')};
      expect(set.length, 2);
      expect(set.contains(jelly('101')), isTrue);
      expect(set.contains(sub('101')), isTrue);
    });

    test('same-id copies are distinct Map/family keys', () {
      final Map<Track, String> byTrack = <Track, String>{
        jelly('101'): 'jelly',
        sub('101'): 'sub',
      };
      expect(byTrack[jelly('101')], 'jelly');
      expect(byTrack[sub('101')], 'sub');
    });
  });
}
