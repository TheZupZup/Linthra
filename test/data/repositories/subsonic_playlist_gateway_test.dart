import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/subsonic_playlist_gateway.dart';

import '../../core/sources/subsonic/fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

void main() {
  group('SubsonicPlaylistGateway', () {
    late FakeSubsonicClient client;

    setUp(() => client = FakeSubsonicClient());

    SubsonicPlaylistGateway build({SubsonicSession? session}) =>
        SubsonicPlaylistGateway(client: client, session: () => session);

    test('serves the subsonic source and pushes rename + reorder', () {
      final SubsonicPlaylistGateway gateway = build(session: _session);
      expect(gateway.source, PlaylistSource.subsonic);
      expect(gateway.pushesRename, isTrue);
      expect(gateway.pushesReorder, isTrue);
    });

    test('isConnected reflects the live session', () {
      expect(build(session: _session).isConnected, isTrue);
      expect(build(session: null).isConnected, isFalse);
    });

    test('fetchPlaylists imports headers + ordered, namespaced membership',
        () async {
      client.playlists = <SubsonicPlaylistDto>[
        const SubsonicPlaylistDto(id: 'p-1', name: 'Road Trip'),
      ];
      client.playlistSongIds = <String, List<String>>{
        'p-1': <String>['mf-3', 'mf-1'],
      };

      final List<RemotePlaylistData> playlists =
          await build(session: _session).fetchPlaylists();
      expect(playlists, hasLength(1));
      expect(playlists.single.remoteId, 'p-1');
      expect(playlists.single.name, 'Road Trip');
      expect(playlists.single.trackUris,
          <String>['subsonic:mf-3', 'subsonic:mf-1']);
    });

    test('createRemotePlaylist maps uris to song ids and returns the id',
        () async {
      client.createdPlaylistId = 'p-new';
      final String id = await build(session: _session).createRemotePlaylist(
        'Fresh',
        <String>['subsonic:mf-1', 'subsonic:mf-2'],
      );
      expect(id, 'p-new');
      expect(client.createCalls.single.name, 'Fresh');
      expect(client.createCalls.single.songIds, <String>['mf-1', 'mf-2']);
    });

    test('syncMembership replaces the full ordered list (add/remove/reorder)',
        () async {
      await build(session: _session).syncMembership(
        'p-1',
        orderedTrackUris: <String>['subsonic:mf-2', 'subsonic:mf-1'],
        added: const <String>['subsonic:mf-2'],
        removed: const <String>[],
      );
      // A single ordered replace, ignoring the delta.
      expect(client.setSongsCalls.single.playlistId, 'p-1');
      expect(client.setSongsCalls.single.songIds, <String>['mf-2', 'mf-1']);
    });

    test('non-subsonic uris are dropped at the request boundary', () async {
      client.createdPlaylistId = 'p-1';
      await build(session: _session).createRemotePlaylist(
        'Mixed',
        <String>['subsonic:mf-1', 'jellyfin:j-1', '/local/song.mp3'],
      );
      expect(client.createCalls.single.songIds, <String>['mf-1']);
    });

    test('renameRemote renames on the server', () async {
      await build(session: _session).renameRemote('p-1', 'Renamed');
      expect(client.renameCalls.single, (playlistId: 'p-1', name: 'Renamed'));
    });

    test('deleteRemote deletes on the server', () async {
      await build(session: _session).deleteRemote('p-1');
      expect(client.deletedPlaylistIds, <String>['p-1']);
    });

    test('a server failure surfaces as a friendly RemoteSyncException',
        () async {
      client.playlistError = SubsonicException.notReachable();
      await expectLater(
        () => build(session: _session).fetchPlaylists(),
        throwsA(isA<RemoteSyncException>()),
      );
      await expectLater(
        () => build(session: _session)
            .createRemotePlaylist('X', const <String>[]),
        throwsA(isA<RemoteSyncException>()),
      );
    });
  });
}
