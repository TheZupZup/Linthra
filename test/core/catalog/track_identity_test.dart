import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/now_playing_match.dart';
import 'package:linthra/core/catalog/track_identity.dart';
import 'package:linthra/core/models/track.dart';

/// Whether the library merge takes [a] and [b] (from different servers) for
/// one song: decided by the Rust core, through the now-playing match.
bool _same(Track a, Track b) => isCurrentPlaybackTrack(a, b);

/// A Jellyfin-shaped track: opaque `jellyfin:<id>` uri and full tags.
Track _jelly(
  String id, {
  required String title,
  String? artist = 'Adele',
  String? album = '25',
  Duration duration = const Duration(minutes: 3),
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

/// A Subsonic/Navidrome-shaped track: opaque `subsonic:<id>` uri and full tags.
Track _sub(
  String id, {
  required String title,
  String? artist = 'Adele',
  String? album = '25',
  Duration duration = const Duration(minutes: 3),
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
  group('trackSourceId', () {
    test('reads the owning provider from the uri scheme', () {
      expect(trackSourceId(_jelly('1', title: 'x')), 'jellyfin');
      expect(trackSourceId(_sub('1', title: 'x')), 'subsonic');
      expect(
        trackSourceId(const Track(id: 'p', title: 'x', uri: '/music/x.mp3')),
        'local',
      );
      expect(
        trackSourceId(
          const Track(id: 'p', title: 'x', uri: 'content://media/x'),
        ),
        'local',
      );
    });
  });

  group('eligibility', () {
    test('no artist, no album, or a zero duration never matches', () {
      for (final (Track a, Track b) in <(Track, Track)>[
        (
          _jelly('j', title: 'X', artist: null),
          _sub('s', title: 'X', artist: null)
        ),
        (
          _jelly('j', title: 'X', album: null),
          _sub('s', title: 'X', album: null)
        ),
        (
          _jelly('j', title: 'X', duration: Duration.zero),
          _sub('s', title: 'X', duration: Duration.zero),
        ),
      ]) {
        expect(_same(a, b), isFalse);
      }
    });

    test('an untagged local file (title only) is never matched', () {
      const Track local = Track(id: '/m/x.mp3', title: 'x', uri: '/m/x.mp3');
      expect(_same(local, _sub('s', title: 'x')), isFalse);
    });
  });

  group('the same song — the same song across providers', () {
    test('identical tags match', () {
      expect(_same(_jelly('j', title: 'Hello'), _sub('s', title: 'Hello')),
          isTrue);
    });

    test('case and accents fold, so they never split a match', () {
      expect(
        _same(
          _jelly('j', title: 'Café', artist: 'Beyoncé'),
          _sub('s', title: 'cafe', artist: 'beyonce'),
        ),
        isTrue,
      );
    });

    test('a 1-second rounding difference still matches', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', duration: const Duration(seconds: 180)),
          _sub('s', title: 'Hello', duration: const Duration(seconds: 181)),
        ),
        isTrue,
      );
    });

    test('a rounding gap that straddled the old bucket edge now matches', () {
      // 181s and 182s fell in different 2-second *buckets* before; as an
      // absolute *difference* they are 1s apart and match.
      expect(
        _same(
          _jelly('j', title: 'Hello', duration: const Duration(seconds: 181)),
          _sub('s', title: 'Hello', duration: const Duration(seconds: 182)),
        ),
        isTrue,
      );
    });
  });

  group('the same song — real Jellyfin/Navidrome metadata drift', () {
    test('a featured artist in the title is ignored (CAREFUL feat. Cordae)',
        () {
      expect(
        _same(
          _jelly('j', title: 'CAREFUL'),
          _sub('s', title: 'CAREFUL feat. Cordae'),
        ),
        isTrue,
      );
    });

    test('a parenthesised featured artist in the title is ignored', () {
      expect(
        _same(
          _jelly('j', title: 'CAREFUL'),
          _sub('s', title: 'CAREFUL (feat. Cordae)'),
        ),
        isTrue,
      );
    });

    test('an extra featured artist in the artist field is ignored (NF, Cordae)',
        () {
      expect(
        _same(
          _jelly('j', title: 'CAREFUL', artist: 'NF'),
          _sub('s', title: 'CAREFUL', artist: 'NF, Cordae'),
        ),
        isTrue,
      );
    });

    test('the full reported drift (title + artist) still matches', () {
      expect(
        _same(
          _jelly('j', title: 'CAREFUL', artist: 'NF'),
          _sub('s', title: 'CAREFUL feat. Cordae', artist: 'NF, Cordae'),
        ),
        isTrue,
      );
    });

    test('an album edition suffix is tolerated (25 vs 25 (Deluxe))', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', album: '25'),
          _sub('s', title: 'Hello', album: '25 (Deluxe)'),
        ),
        isTrue,
      );
    });

    test('a matching track number reinforces a match', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello', trackNumber: 3),
        ),
        isTrue,
      );
    });
  });

  group('the same song — staying conservative', () {
    test('a different album is not a match', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', album: '25'),
          _sub('s', title: 'Hello', album: '21'),
        ),
        isFalse,
      );
    });

    test(
        'two different songs that share a title + artist + duration but sit on '
        'different albums are not merged', () {
      expect(
        _same(
          _jelly('j', title: 'Intro', album: 'Album A'),
          _sub('s', title: 'Intro', album: 'Album B'),
        ),
        isFalse,
      );
    });

    test('a different artist is not a match', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', artist: 'Adele'),
          _sub('s', title: 'Hello', artist: 'Lionel'),
        ),
        isFalse,
      );
    });

    test('a clearly different duration is vetoed', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', duration: const Duration(minutes: 3)),
          _sub('s', title: 'Hello', duration: const Duration(minutes: 5)),
        ),
        isFalse,
      );
    });

    test('a 3-second duration gap is vetoed', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', duration: const Duration(seconds: 180)),
          _sub('s', title: 'Hello', duration: const Duration(seconds: 183)),
        ),
        isFalse,
      );
    });

    test('a version qualifier keeps a remix/live distinct', () {
      expect(
        _same(
          _jelly('j', title: 'Hello'),
          _sub('s', title: 'Hello (Live)'),
        ),
        isFalse,
      );
    });

    test('conflicting track numbers veto an otherwise-identical match', () {
      // Same title/artist/album/duration but a different position on the album:
      // a strong signal these are different songs, so never merge.
      expect(
        _same(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello', trackNumber: 4),
        ),
        isFalse,
      );
    });

    test('a missing track number on one side never vetoes', () {
      expect(
        _same(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello'),
        ),
        isTrue,
      );
    });
  });
}
