import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/jellyfin_playlist_gateway.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: '5f0e1a2b3c4d5e6f708192a3b4c5d6e7',
  accessToken: 'tok-abc-secret',
  deviceId: 'device-1',
);

const String _playlistId = 'aa11bb22cc33dd44ee55ff6677889900';

/// A Jellyfin item id: 32 hex characters.
String _itemId(int n) => n.toRadixString(16).padLeft(32, '0');

List<String> _itemIds(int count) =>
    <String>[for (int i = 0; i < count; i++) _itemId(i)];

List<String> _uris(List<String> ids) =>
    <String>[for (final String id in ids) 'jellyfin:$id'];

/// A Jellyfin server behind the usual 8 KB request-line limit (Kestrel's
/// default, and nginx's): a longer request line is turned away with a 414
/// before Jellyfin sees it. Holds one playlist, and appends every add to it
/// as Jellyfin does, repeats included.
class _FakeJellyfinServer {
  final List<String> entries = <String>[];
  int addsReceived = 0;

  /// The add request (counting from 1) answered with a 500 instead of
  /// landing, once.
  int? failAdd;

  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final String line =
        '${request.method} ${request.url.path}?${request.url.query} HTTP/1.1';
    if (line.length > 8192) return http.Response('', 414);
    final String path = request.url.path;
    if (request.method == 'POST' && path == '/Playlists') {
      return _json(<String, dynamic>{'Id': _playlistId});
    }
    if (request.method == 'POST' && path == '/Playlists/$_playlistId/Items') {
      addsReceived++;
      if (addsReceived == failAdd) return http.Response('', 500);
      entries.addAll(request.url.queryParameters['Ids']!.split(','));
      return http.Response('', 204);
    }
    if (request.method == 'GET' && path == '/Items') {
      return _json(<String, dynamic>{
        'Items': <dynamic>[
          <String, dynamic>{'Id': _playlistId, 'Name': 'Everything'},
        ],
      });
    }
    if (request.method == 'GET' && path == '/Playlists/$_playlistId/Items') {
      return _json(<String, dynamic>{
        'Items': <dynamic>[
          for (int i = 0; i < entries.length; i++)
            <String, dynamic>{'Id': entries[i], 'PlaylistItemId': 'e$i'},
        ],
      });
    }
    return http.Response('', 404);
  }

  static http.Response _json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
}

void main() {
  late _FakeJellyfinServer server;
  late SyncedPlaylistRepository repository;

  setUp(() {
    server = _FakeJellyfinServer();
    int counter = 0;
    repository = SyncedPlaylistRepository(
      store: InMemoryPlaylistStore(),
      gateways: <RemotePlaylistGateway>[
        JellyfinPlaylistGateway(
          client: HttpJellyfinClient(httpClient: server.client),
          session: () => _session,
        ),
      ],
      idGenerator: () => 'pl-${counter++}',
      now: () => DateTime(2024, 1, 1),
    );
  });

  Future<Playlist> syncedPlaylist() async {
    final Playlist created = await repository.createPlaylist(
      'Everything',
      source: PlaylistSource.jellyfin,
    );
    expect(created.remoteId, _playlistId);
    return created;
  }

  Future<Playlist> reload(Playlist playlist) async =>
      (await repository.getPlaylistById(playlist.id))!;

  test(
      'a few hundred songs added to a synced Jellyfin playlist are still '
      'there after the next refresh (#876)', () async {
    final Playlist created = await syncedPlaylist();
    final List<String> ids = _itemIds(300);

    await repository.addTracks(created.id, _uris(ids));

    expect((await reload(created)).syncState, PlaylistSyncState.synced);
    expect(server.entries, ids);

    await repository.refreshFromRemote();

    final Playlist refreshed = await reload(created);
    expect(refreshed.trackIds, _uris(ids));
    expect(refreshed.syncState, PlaylistSyncState.synced);
  });

  test(
      'a batch failing part way is reported, keeps what landed, and adding '
      'again sends only what is missing', () async {
    final Playlist created = await syncedPlaylist();
    final List<String> ids = _itemIds(300);
    server.failAdd = 2;

    await repository.addTracks(created.id, _uris(ids));

    // Not reported as synced: only the first batch reached the server.
    final Playlist failed = await reload(created);
    expect(failed.syncState, PlaylistSyncState.syncFailed);
    expect(failed.lastSyncError, isNotNull);
    expect(server.entries, ids.sublist(0, 100));

    // The refresh shows what is really on the server, the landed batch
    // included.
    await repository.refreshFromRemote();
    expect((await reload(created)).trackIds, _uris(ids.sublist(0, 100)));

    // Adding them all again sends only the songs that never got there, so
    // none of the landed ones ends up on the server twice.
    await repository.addTracks(created.id, _uris(ids));

    expect(server.entries, ids);
    final Playlist retried = await reload(created);
    expect(retried.syncState, PlaylistSyncState.synced);
    expect(retried.trackIds, _uris(ids));
  });
}
