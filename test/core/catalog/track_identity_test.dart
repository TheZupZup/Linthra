import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/track_identity.dart';
import 'package:linthra/core/models/track.dart';

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

  group('canMatchAcrossProviders / matchBlockKey — eligibility', () {
    test('a fully tagged track is eligible', () {
      expect(canMatchAcrossProviders(_jelly('j', title: 'Hello')), isTrue);
      expect(matchBlockKey(_jelly('j', title: 'Hello')), isNotNull);
    });

    test('the same song on two providers shares a block key', () {
      expect(
        matchBlockKey(_jelly('j', title: 'Hello')),
        matchBlockKey(_sub('s', title: 'Hello')),
      );
    });

    test('a featured-artist title still blocks with the plain copy', () {
      // The block key strips the feat. qualifier, so the two copies that the
      // scorer must compare actually land in the same block.
      expect(
        matchBlockKey(_jelly('j', title: 'CAREFUL')),
        matchBlockKey(_sub('s', title: 'CAREFUL feat. Cordae')),
      );
    });

    test('different songs by the same artist get different block keys', () {
      expect(
        matchBlockKey(_jelly('j', title: 'Hello')),
        isNot(matchBlockKey(_jelly('k', title: 'Skyfall'))),
      );
    });

    test('no artist, no album, or a zero duration is ineligible', () {
      expect(canMatchAcrossProviders(_jelly('j', title: 'X', artist: null)),
          isFalse);
      expect(canMatchAcrossProviders(_jelly('j', title: 'X', album: null)),
          isFalse);
      expect(
        canMatchAcrossProviders(
          _jelly('j', title: 'X', duration: Duration.zero),
        ),
        isFalse,
      );
    });

    test('an untagged local file (title only) is never matchable', () {
      const Track local = Track(id: '/m/x.mp3', title: 'x', uri: '/m/x.mp3');
      expect(canMatchAcrossProviders(local), isFalse);
      expect(matchBlockKey(local), isNull);
    });
  });

  group('isLikelySameTrack — the same song across providers', () {
    test('identical tags match', () {
      expect(
          isLikelySameTrack(
              _jelly('j', title: 'Hello'), _sub('s', title: 'Hello')),
          isTrue);
    });

    test('case and accents fold, so they never split a match', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Café', artist: 'Beyoncé'),
          _sub('s', title: 'cafe', artist: 'beyonce'),
        ),
        isTrue,
      );
    });

    test('a 1-second rounding difference still matches', () {
      expect(
        isLikelySameTrack(
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
        isLikelySameTrack(
          _jelly('j', title: 'Hello', duration: const Duration(seconds: 181)),
          _sub('s', title: 'Hello', duration: const Duration(seconds: 182)),
        ),
        isTrue,
      );
    });
  });

  group('isLikelySameTrack — real Jellyfin/Navidrome metadata drift', () {
    test('a featured artist in the title is ignored (CAREFUL feat. Cordae)',
        () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'CAREFUL'),
          _sub('s', title: 'CAREFUL feat. Cordae'),
        ),
        isTrue,
      );
    });

    test('a parenthesised featured artist in the title is ignored', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'CAREFUL'),
          _sub('s', title: 'CAREFUL (feat. Cordae)'),
        ),
        isTrue,
      );
    });

    test('an extra featured artist in the artist field is ignored (NF, Cordae)',
        () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'CAREFUL', artist: 'NF'),
          _sub('s', title: 'CAREFUL', artist: 'NF, Cordae'),
        ),
        isTrue,
      );
    });

    test('the full reported drift (title + artist) still matches', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'CAREFUL', artist: 'NF'),
          _sub('s', title: 'CAREFUL feat. Cordae', artist: 'NF, Cordae'),
        ),
        isTrue,
      );
    });

    test('an album edition suffix is tolerated (25 vs 25 (Deluxe))', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Hello', album: '25'),
          _sub('s', title: 'Hello', album: '25 (Deluxe)'),
        ),
        isTrue,
      );
    });

    test('a matching track number reinforces a match', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello', trackNumber: 3),
        ),
        isTrue,
      );
    });
  });

  group('isLikelySameTrack — staying conservative', () {
    test('a different album is not a match', () {
      expect(
        isLikelySameTrack(
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
        isLikelySameTrack(
          _jelly('j', title: 'Intro', album: 'Album A'),
          _sub('s', title: 'Intro', album: 'Album B'),
        ),
        isFalse,
      );
    });

    test('a different artist is not a match', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Hello', artist: 'Adele'),
          _sub('s', title: 'Hello', artist: 'Lionel'),
        ),
        isFalse,
      );
    });

    test('a clearly different duration is vetoed', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Hello', duration: const Duration(minutes: 3)),
          _sub('s', title: 'Hello', duration: const Duration(minutes: 5)),
        ),
        isFalse,
      );
    });

    test('a 3-second duration gap is vetoed', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Hello', duration: const Duration(seconds: 180)),
          _sub('s', title: 'Hello', duration: const Duration(seconds: 183)),
        ),
        isFalse,
      );
    });

    test('a version qualifier keeps a remix/live distinct', () {
      expect(
        isLikelySameTrack(
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
        isLikelySameTrack(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello', trackNumber: 4),
        ),
        isFalse,
      );
    });

    test('a missing track number on one side never vetoes', () {
      expect(
        isLikelySameTrack(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello'),
        ),
        isTrue,
      );
    });
  });

  group('trackMatchScore — the score itself', () {
    test('an exact match scores 1.0', () {
      expect(
        trackMatchScore(_jelly('j', title: 'Hello'), _sub('s', title: 'Hello')),
        closeTo(1.0, 1e-9),
      );
    });

    test('a duration veto scores exactly 0.0', () {
      // A hard veto (here, durations too far apart) collapses the score to 0,
      // regardless of how well the other fields agree.
      expect(
        trackMatchScore(
          _jelly('j', title: 'Hello', duration: const Duration(minutes: 3)),
          _sub('s', title: 'Hello', duration: const Duration(minutes: 5)),
        ),
        0.0,
      );
    });

    test('a track-number conflict scores exactly 0.0', () {
      expect(
        trackMatchScore(
          _jelly('j', title: 'Hello', trackNumber: 3),
          _sub('s', title: 'Hello', trackNumber: 4),
        ),
        0.0,
      );
    });

    test('a different artist scores low but is not a hard veto', () {
      // Different artists share no tokens, so the artist signal is 0; the score
      // stays well below the merge threshold without needing a veto.
      final double score = trackMatchScore(
        _jelly('j', title: 'Hello', artist: 'Adele'),
        _sub('s', title: 'Hello', artist: 'Lionel'),
      );
      expect(score, lessThan(kTrackMatchScore));
    });

    test('a low-confidence pair scores below the merge threshold', () {
      final double score = trackMatchScore(
        _jelly('j', title: 'Intro', album: 'Album A'),
        _sub('s', title: 'Intro', album: 'Album B'),
      );
      expect(score, lessThan(kTrackMatchScore));
      expect(score, greaterThan(0.0));
    });
  });
}
