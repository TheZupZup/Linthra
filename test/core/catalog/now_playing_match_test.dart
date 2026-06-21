import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/now_playing_match.dart';
import 'package:linthra/core/models/track.dart';

Track _jelly(
  String id, {
  String title = 'Careful',
  String artist = 'NF',
  String album = 'Perception',
  Duration duration = const Duration(seconds: 200),
  int? trackNumber,
}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
      trackNumber: trackNumber,
    );

Track _sub(
  String id, {
  String title = 'Careful',
  String artist = 'NF',
  String album = 'Perception',
  Duration duration = const Duration(seconds: 200),
  int? trackNumber,
}) =>
    Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
      trackNumber: trackNumber,
    );

void main() {
  group('isCurrentPlaybackTrack', () {
    test('matches the exact same track', () {
      final Track t = _jelly('a');
      expect(isCurrentPlaybackTrack(t, t), isTrue);
    });

    test('a different song on the same provider is not current', () {
      expect(
        isCurrentPlaybackTrack(
          _jelly('a', title: 'Alpha', album: 'A'),
          _jelly('b', title: 'Beta', album: 'B'),
        ),
        isFalse,
      );
    });

    test('two distinct same-provider ids never match by metadata alone', () {
      // Identical metadata but different ids on one provider: only the exact id
      // counts, mirroring the unifier never merging a single source's own rows.
      expect(isCurrentPlaybackTrack(_jelly('a'), _jelly('b')), isFalse);
    });

    test('the same song on a different provider matches (fallback)', () {
      // Tapped the Jellyfin row, playback fell back to the Navidrome copy.
      expect(isCurrentPlaybackTrack(_jelly('j1'), _sub('s1')), isTrue);
      // ...and the relation is symmetric.
      expect(isCurrentPlaybackTrack(_sub('s1'), _jelly('j1')), isTrue);
    });

    test('different songs on different providers do not match', () {
      expect(
        isCurrentPlaybackTrack(
          _jelly('j1', title: 'Alpha', album: 'A'),
          _sub('s1', title: 'Beta', album: 'B'),
        ),
        isFalse,
      );
    });

    test('a different track number vetoes a cross-provider match', () {
      expect(
        isCurrentPlaybackTrack(
          _jelly('j1', trackNumber: 1),
          _sub('s1', trackNumber: 4),
        ),
        isFalse,
      );
    });

    test('untagged local files only match by exact uri', () {
      const Track a =
          Track(id: 'file:///a.mp3', title: 'a', uri: 'file:///a.mp3');
      const Track b =
          Track(id: 'file:///b.mp3', title: 'b', uri: 'file:///b.mp3');
      expect(isCurrentPlaybackTrack(a, a), isTrue);
      expect(isCurrentPlaybackTrack(a, b), isFalse);
    });

    test('a different song sharing a bare id across providers is NOT current',
        () {
      // Regression for the bare-id short-circuit: a playing jellyfin:101 must
      // not mark an unrelated subsonic:101 as the now-playing row.
      expect(
        isCurrentPlaybackTrack(
          _jelly('101', title: 'Alpha', album: 'A'),
          _sub('101', title: 'Beta', album: 'B'),
        ),
        isFalse,
      );
      // The same song across providers with a shared bare id still matches.
      expect(isCurrentPlaybackTrack(_jelly('101'), _sub('101')), isTrue);
    });
  });
}
