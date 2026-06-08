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
}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
    );

/// A Subsonic/Navidrome-shaped track: opaque `subsonic:<id>` uri and full tags.
Track _sub(
  String id, {
  required String title,
  String? artist = 'Adele',
  String? album = '25',
  Duration duration = const Duration(minutes: 3),
}) =>
    Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
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

  group('logicalMatchKey — the same song across providers', () {
    test('Jellyfin and Subsonic copies of one song share a key', () {
      final String? a = logicalMatchKey(_jelly('j', title: 'Hello'));
      final String? b = logicalMatchKey(_sub('s', title: 'Hello'));
      expect(a, isNotNull);
      expect(a, b);
    });

    test('case and accents fold, so they never split a match', () {
      final String? a =
          logicalMatchKey(_jelly('j', title: 'Café', artist: 'Beyoncé'));
      final String? b =
          logicalMatchKey(_sub('s', title: 'cafe', artist: 'beyonce'));
      expect(a, isNotNull);
      expect(a, b);
    });

    test('a 1-second rounding difference still matches', () {
      final String? a = logicalMatchKey(
        _jelly('j', title: 'Hello', duration: const Duration(seconds: 180)),
      );
      final String? b = logicalMatchKey(
        _sub('s', title: 'Hello', duration: const Duration(seconds: 181)),
      );
      expect(a, b);
    });
  });

  group('logicalMatchKey — staying conservative', () {
    test('a different album is a different key', () {
      expect(
        logicalMatchKey(_jelly('j', title: 'Hello', album: '25')),
        isNot(logicalMatchKey(_sub('s', title: 'Hello', album: '21'))),
      );
    });

    test('a different artist is a different key', () {
      expect(
        logicalMatchKey(_jelly('j', title: 'Hello', artist: 'Adele')),
        isNot(logicalMatchKey(_sub('s', title: 'Hello', artist: 'Lionel'))),
      );
    });

    test('a clearly different duration is a different key', () {
      expect(
        logicalMatchKey(
          _jelly('j', title: 'Hello', duration: const Duration(minutes: 3)),
        ),
        isNot(
          logicalMatchKey(
            _sub('s', title: 'Hello', duration: const Duration(minutes: 5)),
          ),
        ),
      );
    });

    test('a version qualifier in the title keeps a remix/live distinct', () {
      expect(
        logicalMatchKey(_jelly('j', title: 'Hello')),
        isNot(logicalMatchKey(_sub('s', title: 'Hello (Live)'))),
      );
    });
  });

  group('logicalMatchKey — ineligible tracks never match', () {
    test('no artist yields no key', () {
      expect(
          logicalMatchKey(_jelly('j', title: 'Hello', artist: null)), isNull);
      expect(
        canMatchAcrossProviders(_jelly('j', title: 'Hello', artist: null)),
        isFalse,
      );
    });

    test('no album yields no key', () {
      expect(logicalMatchKey(_jelly('j', title: 'Hello', album: null)), isNull);
    });

    test('an unknown (zero) duration yields no key', () {
      expect(
        logicalMatchKey(
          _jelly('j', title: 'Hello', duration: Duration.zero),
        ),
        isNull,
      );
    });

    test('an untagged local file (title only) is never matchable', () {
      const Track local = Track(id: '/m/x.mp3', title: 'x', uri: '/m/x.mp3');
      expect(logicalMatchKey(local), isNull);
    });
  });
}
