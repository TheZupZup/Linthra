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
}
