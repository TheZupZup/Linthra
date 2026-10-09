import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/song_origin_legacy_store.dart';
import 'package:linthra/core/services/song_origins.dart';
import 'package:linthra/data/repositories/in_memory_song_origin_legacy_store.dart';

import '../../support/fake_song_origins.dart';

/// A legacy record that can't be read or written.
class _BrokenStore implements SongOriginLegacyStore {
  _BrokenStore({this.failRead = false, this.failWrite = false});

  final bool failRead;
  final bool failWrite;
  int writes = 0;

  @override
  Future<Map<String, String>> read() async {
    if (failRead) throw StateError('unreadable');
    return <String, String>{};
  }

  @override
  Future<void> write(Map<String, String> settled) async {
    writes++;
    if (failWrite) throw StateError('refused');
  }
}

void main() {
  group('songOriginMatches', () {
    final FakeSongOrigins origins = FakeSongOrigins(
      signedIn: <String, String?>{'subsonic:': 'server-a', 'plex:': 'pms-1'},
      legacy: <String, String>{'subsonic:': 'server-a', 'plex:': ''},
    );

    test('a reference made on the server signed in now matches', () {
      expect(songOriginMatches(origins, 'subsonic:1', 'server-a'), isTrue);
      expect(songOriginMatches(origins, 'plex:1', 'pms-1'), isTrue);
    });

    test('one made on another server does not, whatever its id', () {
      expect(songOriginMatches(origins, 'subsonic:1', 'server-b'), isFalse);
      expect(songOriginMatches(origins, 'plex:1', 'pms-2'), isFalse);
    });

    test('one made while signed out matches nothing', () {
      expect(songOriginMatches(origins, 'subsonic:1', noSongOrigin), isFalse);
    });

    test('an older one counts for the origin its kind was settled to', () {
      expect(songOriginMatches(origins, 'subsonic:1', null), isTrue);
      // Settled to nobody: never, on any server.
      expect(songOriginMatches(origins, 'plex:1', null), isFalse);
    });

    test('nothing matches while its provider is signed out', () {
      final FakeSongOrigins out = FakeSongOrigins(
        legacy: <String, String>{'subsonic:': 'server-a'},
      );
      expect(songOriginMatches(out, 'subsonic:1', 'server-a'), isFalse);
      expect(songOriginMatches(out, 'subsonic:1', null), isFalse);
    });

    test('local songs and Jellyfin ids are never bound', () {
      expect(songOriginMatches(origins, 'jellyfin:abc', 'anything'), isTrue);
      expect(songOriginMatches(origins, '/music/a.flac', null), isTrue);
      expect(songOriginToRecord(origins, 'jellyfin:abc'), isNull);
    });

    test('what a new reference records', () {
      expect(songOriginToRecord(origins, 'subsonic:1'), 'server-a');
      expect(
        songOriginToRecord(FakeSongOrigins(), 'subsonic:1'),
        noSongOrigin,
      );
    });
  });

  group('history keys', () {
    test('round-trip, and an unbound key is the uri itself', () {
      expect(songHistoryKey('/music/a.flac', null), '/music/a.flac');
      expect(
        splitSongHistoryKey('/music/a.flac'),
        (uri: '/music/a.flac', origin: null),
      );
      final String key = songHistoryKey('subsonic:48211', 'server-a');
      expect(key, isNot('subsonic:48211'));
      expect(
        splitSongHistoryKey(key),
        (uri: 'subsonic:48211', origin: 'server-a'),
      );
    });
  });

  group('SessionSongOrigins.settleLegacy', () {
    test('settles older references to the accounts restored at startup',
        () async {
      final InMemorySongOriginLegacyStore store =
          InMemorySongOriginLegacyStore();
      final SessionSongOrigins origins = SessionSongOrigins(
        signedIn: (String scheme) =>
            scheme == 'subsonic:' ? 'acct-alice' : null,
        legacyStore: store,
      );

      await origins.settleLegacy();

      expect(origins.legacy('subsonic:1'), 'acct-alice');
      // Plex wasn't signed in: its older references are nobody's.
      expect(origins.legacy('plex:1'), noSongOrigin);
      expect(store.settled, <String, String>{
        'subsonic:': 'acct-alice',
        'plex:': noSongOrigin,
      });
    });

    test('a later start with another account keeps what was settled', () async {
      final InMemorySongOriginLegacyStore store =
          InMemorySongOriginLegacyStore(<String, String>{
        'subsonic:': 'acct-alice',
        'plex:': noSongOrigin,
      });
      final SessionSongOrigins origins = SessionSongOrigins(
        signedIn: (String scheme) => 'acct-bob',
        legacyStore: store,
      );

      await origins.settleLegacy();

      expect(origins.legacy('subsonic:1'), 'acct-alice');
      expect(origins.legacy('plex:1'), noSongOrigin);
      expect(store.settled['subsonic:'], 'acct-alice');
    });

    test('an unreadable record settles nothing this time', () async {
      final _BrokenStore store = _BrokenStore(failRead: true);
      final SessionSongOrigins origins = SessionSongOrigins(
        signedIn: (String scheme) => 'acct-bob',
        legacyStore: store,
      );

      await origins.settleLegacy();

      expect(origins.legacy('subsonic:1'), isNull);
      expect(store.writes, 0);
    });

    test('a refused write still holds for this run', () async {
      final _BrokenStore store = _BrokenStore(failWrite: true);
      final SessionSongOrigins origins = SessionSongOrigins(
        signedIn: (String scheme) => 'acct-alice',
        legacyStore: store,
      );

      await origins.settleLegacy();

      expect(origins.legacy('subsonic:1'), 'acct-alice');
    });

    test('settling announces it, so what resolves references does again',
        () async {
      final SessionSongOrigins origins = SessionSongOrigins(
        signedIn: (String scheme) => 'acct-alice',
        legacyStore: InMemorySongOriginLegacyStore(),
      );
      int heard = 0;
      origins.changes.listen((_) => heard++);

      await origins.settleLegacy();
      await origins.settleLegacy();
      await pumpEventQueue();

      expect(heard, 1);
    });
  });
}
