import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';

void main() {
  const Track jellyfin = Track(
    id: '101',
    title: 'Remote',
    uri: 'jellyfin:101',
    artistName: 'A',
    duration: Duration(minutes: 3),
  );
  const Track local = Track(
    id: '/music/a.mp3',
    title: 'Local',
    uri: '/music/a.mp3',
    duration: Duration(minutes: 2),
  );
  const Track subsonic = Track(
    id: '55',
    title: 'Sub',
    uri: 'subsonic:55',
  );

  group('isLogicalTrackUri', () {
    test('accepts provider-namespaced and local path identities', () {
      expect(isLogicalTrackUri('jellyfin:101'), isTrue);
      expect(isLogicalTrackUri('subsonic:abc'), isTrue);
      expect(isLogicalTrackUri('plex:9'), isTrue);
      expect(isLogicalTrackUri('/home/me/Music/song.mp3'), isTrue);
    });

    test('rejects authenticated stream URLs and token-bearing strings', () {
      expect(
        isLogicalTrackUri(
          'https://server/Audio/101/stream?api_key=secret-token',
        ),
        isFalse,
      );
      expect(
        isLogicalTrackUri(
          'http://plex.local/library/parts/1?X-Plex-Token=tok',
        ),
        isFalse,
      );
      expect(isLogicalTrackUri('jellyfin:101?api_key=x'), isFalse);
      expect(isLogicalTrackUri(''), isFalse);
      expect(isLogicalTrackUri('   '), isFalse);
    });

    test('accepts a local path whose names say "bearer "', () {
      // Band and song names, not a token.
      expect(
        isLogicalTrackUri(
          '/home/me/Music/Pallbearer - Heartless/01 - I Saw the End.flac',
        ),
        isTrue,
      );
      expect(
        isLogicalTrackUri('/storage/emulated/0/Music/Torchbearer (Live).mp3'),
        isTrue,
      );
    });

    test('still rejects a bearer token, and a path carrying a token key', () {
      expect(isLogicalTrackUri('Bearer eyJhbGciOiJIUzI1NiJ9.e30.sig'), isFalse);
      expect(isLogicalTrackUri('/music/a.mp3?api_key=secret'), isFalse);
      expect(isLogicalTrackUri('/Audio/101/stream?X-Plex-Token=tok'), isFalse);
    });
  });

  group('PersistedPlaybackSession', () {
    test('round-trips logical queue, modes, and position', () {
      const PersistedPlaybackSession session = PersistedPlaybackSession(
        tracks: <Track>[local, jellyfin, subsonic],
        currentIndex: 1,
        position: Duration(seconds: 42),
        shuffleEnabled: true,
        repeatMode: RepeatMode.all,
      );

      final PersistedPlaybackSession? loaded =
          PersistedPlaybackSession.fromJson(session.toJson());

      expect(loaded, isNotNull);
      expect(loaded!.tracks.map((Track t) => t.uri), <String>[
        local.uri,
        jellyfin.uri,
        subsonic.uri,
      ]);
      expect(loaded.currentIndex, 1);
      expect(loaded.position, const Duration(seconds: 42));
      expect(loaded.shuffleEnabled, isTrue);
      expect(loaded.repeatMode, RepeatMode.all);
      expect(loaded.toJson().toString(), isNot(contains('http')));
      expect(loaded.toJson().toString(), isNot(contains('api_key')));
      expect(loaded.toJson().toString(), isNot(contains('token')));
    });

    test('fromPlayback refuses a queue that includes a stream URL', () {
      const Track poisoned = Track(
        id: 'bad',
        title: 'Bad',
        uri: 'https://server/stream?AccessToken=abc',
      );
      expect(
        PersistedPlaybackSession.fromPlayback(
          previous: const <Track>[],
          current: poisoned,
          upNext: const <Track>[],
          position: Duration.zero,
          shuffleEnabled: false,
          repeatMode: RepeatMode.off,
        ),
        isNull,
      );
    });

    test('fromJson drops a future schema version entirely', () {
      expect(
        PersistedPlaybackSession.fromJson(<String, dynamic>{
          'v': PersistedPlaybackSession.currentSchemaVersion + 1,
          'i': 0,
          'p': 0,
          's': false,
          'r': 'off',
          't': <Map<String, dynamic>>[logicalTrackToJson(jellyfin)],
        }),
        isNull,
      );
    });

    test('fromJson keeps the saved entry of a song queued twice', () {
      final PersistedPlaybackSession? loaded =
          PersistedPlaybackSession.fromJson(<String, dynamic>{
        'v': 1,
        'i': 3,
        'p': 0,
        's': false,
        'r': 'off',
        't': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'x',
            'title': 'Stream',
            'uri': 'https://evil/stream?api_key=secret',
          },
          logicalTrackToJson(jellyfin),
          logicalTrackToJson(local),
          logicalTrackToJson(jellyfin),
          logicalTrackToJson(subsonic),
        ],
      });

      // The second copy, one place earlier now the stream URL row is gone.
      expect(loaded!.currentIndex, 2);
      expect(loaded.current!.uri, jellyfin.uri);
    });

    test('fromJson drops invalid tracks and remaps the current item', () {
      final PersistedPlaybackSession? loaded =
          PersistedPlaybackSession.fromJson(<String, dynamic>{
        'v': 1,
        'i': 1,
        'p': 1500,
        's': false,
        'r': 'one',
        't': <Map<String, dynamic>>[
          logicalTrackToJson(local),
          <String, dynamic>{
            'id': 'x',
            'title': 'Stream',
            'uri': 'https://evil/stream?api_key=secret',
            'durationMs': 1000,
          },
          logicalTrackToJson(jellyfin),
        ],
      });

      expect(loaded, isNotNull);
      // The stream URL row is gone; preferred current (index 1) was that row, so
      // restore lands on the first surviving track.
      expect(loaded!.tracks.map((Track t) => t.uri), <String>[
        local.uri,
        jellyfin.uri,
      ]);
      expect(loaded.current!.uri, local.uri);
      expect(loaded.repeatMode, RepeatMode.one);
    });

    test('fromJson keeps the preferred current when it survives filtering', () {
      final PersistedPlaybackSession? loaded =
          PersistedPlaybackSession.fromJson(
        <String, dynamic>{
          'v': 1,
          'i': 1,
          'p': 9000,
          's': false,
          'r': 'off',
          't': <Map<String, dynamic>>[
            logicalTrackToJson(local),
            logicalTrackToJson(jellyfin),
            logicalTrackToJson(subsonic),
          ],
        },
        isTrackRestorable: (Track t) => t.uri != local.uri,
      );

      expect(loaded, isNotNull);
      expect(loaded!.tracks.map((Track t) => t.uri), <String>[
        jellyfin.uri,
        subsonic.uri,
      ]);
      expect(loaded.current!.uri, jellyfin.uri);
      expect(loaded.position, const Duration(milliseconds: 9000));
    });

    test('fromJson clamps position to track duration when known', () {
      final PersistedPlaybackSession? loaded =
          PersistedPlaybackSession.fromJson(<String, dynamic>{
        'v': 1,
        'i': 0,
        'p': const Duration(minutes: 10).inMilliseconds,
        's': false,
        'r': 'off',
        't': <Map<String, dynamic>>[logicalTrackToJson(local)],
      });
      expect(loaded!.position, local.duration);
    });

    test('artwork with a token query is stripped on write/read', () {
      final Track withTokenArt = jellyfin.copyWith(
        artworkUri: Uri.parse(
          'https://server/Items/101/Images/Primary?api_key=secret',
        ),
      );
      final Map<String, dynamic> json = logicalTrackToJson(withTokenArt);
      expect(json.containsKey('artwork'), isFalse);

      final Track? roundTrip = logicalTrackFromJson(<String, dynamic>{
        ...logicalTrackToJson(jellyfin),
        'artwork': 'https://server/Items/101/Images/Primary?api_key=secret',
      });
      expect(roundTrip!.artworkUri, isNull);
    });
  });

  group('owners (#767)', () {
    const Track sub = Track(id: '1', title: 'One', uri: 'subsonic:1');

    Map<String, dynamic> recordWith(Object? owners) => <String, dynamic>{
          'v': PersistedPlaybackSession.currentSchemaVersion,
          'i': 0,
          't': <Map<String, dynamic>>[logicalTrackToJson(sub)],
          if (owners != null) 'a': owners,
        };

    test('go out and come back with the record', () {
      final PersistedPlaybackSession session = const PersistedPlaybackSession(
        tracks: <Track>[sub],
        currentIndex: 0,
      ).withOwners(<String, String>{'subsonic': 'f00d'});

      final PersistedPlaybackSession? back =
          PersistedPlaybackSession.fromJson(session.toJson());

      expect(back!.owners, <String, String>{'subsonic': 'f00d'});
    });

    test('a record from before them has none, and writes none', () {
      final PersistedPlaybackSession? back =
          PersistedPlaybackSession.fromJson(recordWith(null));

      expect(back!.owners, isNull);
      expect(back.toJson().containsKey('a'), isFalse);
    });

    test("one that can't be read says nobody's, not anybody's", () {
      expect(
        PersistedPlaybackSession.fromJson(recordWith('garbage'))!.owners,
        isEmpty,
      );
      expect(
        PersistedPlaybackSession.fromJson(
          recordWith(<String, Object?>{'subsonic': 42, 'plex': 'm1'}),
        )!
            .owners,
        <String, String>{'plex': 'm1'},
      );
    });

    test('never keeps anything that looks like a token', () {
      final PersistedPlaybackSession session = const PersistedPlaybackSession(
        tracks: <Track>[sub],
        currentIndex: 0,
      ).withOwners(<String, String>{
        'subsonic': 'x?api_key=secret',
        'jellyfin': '',
        'plex': 'm1',
      });

      expect(session.owners, <String, String>{'plex': 'm1'});
      expect(session.toJson().toString(), isNot(contains('secret')));
    });
  });
}
