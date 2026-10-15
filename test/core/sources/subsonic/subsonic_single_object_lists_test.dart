// A Subsonic list holding one entry, sent as that entry alone, is read.
//
// Older Subsonic servers build their JSON from the XML answer, so a list of
// one comes out as a bare object: an album down to one song answers
// `"song": {...}`, and an album-list page holding one album answers
// `"album": {...}`. The client used to read anything but a JSON list as "no
// entries", so a re-sync took that album for an empty one (or never reached
// it) and pruned its rows, starred and playlist reads came back empty the
// same way.
//
// The prune cases run the real controller, the real HttpSubsonicClient and
// the production Recording(Drift) repository stack.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_remote_catalog_owner_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_sync_pending_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/remote_catalog_owner_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_sync_pending_store_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';

import 'synthetic_navidrome.dart';

const SubsonicSession _alice = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt',
  token: 'token',
);

/// A [SyntheticNavidrome] whose JSON comes from an older server: album
/// [oneSongAlbum] is down to its first song, sent as a bare object, and an
/// album-list page holding a single album sends it as a bare object too.
class _LegacyJsonNavidrome extends SyntheticNavidrome {
  _LegacyJsonNavidrome({
    required super.albums,
    super.songsPerAlbum,
    this.oneSongAlbum,
  });

  final int? oneSongAlbum;

  @override
  Future<http.Response> handle(http.Request request) async {
    final http.Response answer = await super.handle(request);
    final String method = request.url.pathSegments.last.replaceAll('.view', '');
    final Map<String, dynamic> json =
        jsonDecode(answer.body) as Map<String, dynamic>;
    final Map<String, dynamic> body =
        json['subsonic-response'] as Map<String, dynamic>;
    if (method == 'getAlbum' &&
        request.url.queryParameters['id'] == 'al-$oneSongAlbum') {
      final Map<String, dynamic> album = body['album'] as Map<String, dynamic>;
      album['song'] = (album['song'] as List<dynamic>).first;
    } else if (method == 'getAlbumList2') {
      final Map<String, dynamic> list =
          body['albumList2'] as Map<String, dynamic>;
      final List<dynamic> albums = list['album'] as List<dynamic>;
      if (albums.length == 1) list['album'] = albums.single;
    } else {
      return answer;
    }
    return http.Response(
      jsonEncode(json),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

/// Syncs [server]'s library as alice into [db], from a restored session.
Future<void> _sync(SyntheticNavidrome server, LinthraDatabase db) async {
  final ProviderContainer container = ProviderContainer(overrides: <Override>[
    subsonicClientProvider.overrideWithValue(server.client()),
    subsonicSessionStoreProvider.overrideWithValue(
      InMemorySubsonicSessionStore(initialSession: _alice),
    ),
    subsonicAutoSyncStoreProvider.overrideWithValue(
      InMemorySubsonicAutoSyncStore(subsonicAccountFingerprint(_alice)),
    ),
    subsonicSyncPendingStoreProvider
        .overrideWithValue(InMemorySubsonicSyncPendingStore()),
    remoteCatalogOwnerStoreProvider
        .overrideWithValue(InMemoryRemoteCatalogOwnerStore()),
    musicLibraryRepositoryProvider.overrideWithValue(_repository(db)),
    subsonicSyncRetryDelaysProvider.overrideWithValue(const <Duration>[]),
  ]);
  addTearDown(container.dispose);
  await container
      .read(subsonicSettingsControllerProvider.notifier)
      .ensureLoaded();
  await container.read(subsonicSyncControllerProvider.notifier).sync();
}

RecordingMusicLibraryRepository _repository(LinthraDatabase db) =>
    RecordingMusicLibraryRepository(
      delegate: DriftMusicLibraryRepository(db),
      addedStore: InMemoryLibraryAddedStore(),
    );

Future<Set<String>> _subsonicUris(LinthraDatabase db) async => <String>{
      for (final Track t in await _repository(db).getAllTracks())
        if (t.uri.startsWith('subsonic:')) t.uri,
    };

LinthraDatabase _openDatabase() {
  final LinthraDatabase db =
      LinthraDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// A client whose server answers every request with [data] in an `ok`
/// envelope.
HttpSubsonicClient _answering(Map<String, dynamic> data) => HttpSubsonicClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok', ...data},
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        ),
      ),
    );

void main() {
  group('a list of one sent as a bare object reads as that one entry', () {
    test('an album-list page', () async {
      final SubsonicAlbumPage page = await _answering(<String, dynamic>{
        'albumList2': <String, dynamic>{
          'album': <String, dynamic>{'id': 'al-1', 'name': 'One'},
        },
      }).getAlbumListPage(_alice, size: 500, offset: 0);

      expect(page.albums.map((SubsonicAlbumDto a) => a.id), <String>['al-1']);
      expect(page.entryCount, 1);
    });

    test("an album's songs", () async {
      final List<SubsonicSongDto> songs = await _answering(<String, dynamic>{
        'album': <String, dynamic>{
          'id': 'al-1',
          'song': <String, dynamic>{'id': 's-1', 'title': 'Only'},
        },
      }).getAlbumSongs(_alice, 'al-1');

      expect(songs.map((SubsonicSongDto s) => s.id), <String>['s-1']);
    });

    test('the starred songs', () async {
      final Set<String> starred = await _answering(<String, dynamic>{
        'starred2': <String, dynamic>{
          'song': <String, dynamic>{'id': 's-1', 'title': 'Only'},
        },
      }).getStarredSongIds(_alice);

      expect(starred, <String>{'s-1'});
    });

    test('the playlists, and a playlist\'s entries', () async {
      final List<SubsonicPlaylistDto> playlists =
          await _answering(<String, dynamic>{
        'playlists': <String, dynamic>{
          'playlist': <String, dynamic>{'id': 'pl-1', 'name': 'Mix'},
        },
      }).getPlaylists(_alice);
      final List<String> entries = await _answering(<String, dynamic>{
        'playlist': <String, dynamic>{
          'id': 'pl-1',
          'entry': <String, dynamic>{'id': 's-1', 'title': 'Only'},
        },
      }).getPlaylistSongIds(_alice, 'pl-1');

      expect(playlists.map((SubsonicPlaylistDto p) => p.id), <String>['pl-1']);
      expect(entries, <String>['s-1']);
    });

    test('the artists, under a single index', () async {
      final List<SubsonicArtistDto> artists =
          await _answering(<String, dynamic>{
        'artists': <String, dynamic>{
          'index': <String, dynamic>{
            'name': 'A',
            'artist': <String, dynamic>{'id': 'ar-1', 'name': 'Abba'},
          },
        },
      }).getArtists(_alice);

      expect(artists.map((SubsonicArtistDto a) => a.id), <String>['ar-1']);
    });

    test('the album served by an older server', () async {
      final _LegacyJsonNavidrome server =
          _LegacyJsonNavidrome(albums: 5, songsPerAlbum: 2, oneSongAlbum: 2);

      final List<SubsonicSongDto> songs =
          await server.client().getAlbumSongs(_alice, 'al-2');

      expect(songs.map((SubsonicSongDto s) => s.id), <String>['mf-alice-2-0']);
    });
  });

  test("a re-sync keeps the song of an album that is down to one", () async {
    final LinthraDatabase db = _openDatabase();
    await _sync(SyntheticNavidrome(albums: 5, songsPerAlbum: 2), db);
    expect(await _subsonicUris(db), hasLength(10));

    // Song 1 of album 2 was deleted on the server; song 0 is still there.
    await _sync(
      _LegacyJsonNavidrome(albums: 5, songsPerAlbum: 2, oneSongAlbum: 2),
      db,
    );

    final Set<String> uris = await _subsonicUris(db);
    expect(uris, contains(SyntheticNavidrome.songUri('alice', 2, 0)));
    expect(uris, hasLength(9));
  });

  test('a re-sync keeps the album alone on the last album-list page', () async {
    // 501 albums: the second list page holds just album 500.
    final LinthraDatabase db = _openDatabase();
    await _sync(SyntheticNavidrome(albums: 501, songsPerAlbum: 1), db);
    expect(await _subsonicUris(db), hasLength(501));

    await _sync(_LegacyJsonNavidrome(albums: 501, songsPerAlbum: 1), db);

    final Set<String> uris = await _subsonicUris(db);
    expect(uris, contains(SyntheticNavidrome.songUri('alice', 500, 0)));
    expect(uris, hasLength(501));
  });
}
