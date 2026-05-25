import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';

void main() {
  group('Playlist', () {
    test('defaults to a local, local-only, empty playlist', () {
      const Playlist playlist = Playlist(id: '1', name: 'Mix');
      expect(playlist.source, PlaylistSource.local);
      expect(playlist.syncState, PlaylistSyncState.localOnly);
      expect(playlist.trackIds, isEmpty);
      expect(playlist.isEmpty, isTrue);
      expect(playlist.isRemote, isFalse);
      expect(playlist.remoteId, isNull);
      expect(playlist.lastSyncError, isNull);
    });

    test('length reflects the track ids', () {
      const Playlist playlist =
          Playlist(id: '1', name: 'Mix', trackIds: <String>['a', 'b', 'c']);
      expect(playlist.length, 3);
      expect(playlist.isEmpty, isFalse);
    });

    test('equality is by id only', () {
      const Playlist a = Playlist(id: '1', name: 'A');
      const Playlist b = Playlist(id: '1', name: 'B different name');
      const Playlist c = Playlist(id: '2', name: 'A');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith updates scalar fields and leaves others intact', () {
      final DateTime created = DateTime(2024, 1, 1);
      final Playlist playlist = Playlist(
        id: '1',
        name: 'Mix',
        trackIds: const <String>['a'],
        createdAt: created,
      );
      final Playlist renamed = playlist.copyWith(name: 'New name');
      expect(renamed.name, 'New name');
      expect(renamed.id, '1');
      expect(renamed.trackIds, <String>['a']);
      expect(renamed.createdAt, created);
    });

    test('copyWith can set and clear nullable fields explicitly', () {
      const Playlist playlist = Playlist(id: '1', name: 'Mix');
      final Playlist withRemote = playlist.copyWith(
        remoteId: () => 'srv-1',
        description: () => 'A description',
        lastSyncError: () => 'Could not sync',
      );
      expect(withRemote.remoteId, 'srv-1');
      expect(withRemote.description, 'A description');
      expect(withRemote.lastSyncError, 'Could not sync');

      final Playlist cleared = withRemote.copyWith(
        lastSyncError: () => null,
        remoteId: () => null,
      );
      expect(cleared.lastSyncError, isNull);
      expect(cleared.remoteId, isNull);
      // Untouched nullable stays.
      expect(cleared.description, 'A description');
    });

    test('PlaylistSource round-trips through providerId', () {
      expect(PlaylistSource.local.providerId, 'local');
      expect(PlaylistSource.jellyfin.providerId, 'jellyfin');
      expect(
          PlaylistSource.fromProviderId('jellyfin'), PlaylistSource.jellyfin);
      // Unknown / null defaults to local so a forward/old record can't crash.
      expect(PlaylistSource.fromProviderId('spotify'), PlaylistSource.local);
      expect(PlaylistSource.fromProviderId(null), PlaylistSource.local);
    });

    test('PlaylistSyncState parses by name, defaulting to localOnly', () {
      expect(
        PlaylistSyncState.fromName('synced'),
        PlaylistSyncState.synced,
      );
      expect(
        PlaylistSyncState.fromName('pendingCreate'),
        PlaylistSyncState.pendingCreate,
      );
      expect(
        PlaylistSyncState.fromName('nonsense'),
        PlaylistSyncState.localOnly,
      );
      expect(PlaylistSyncState.fromName(null), PlaylistSyncState.localOnly);
    });
  });
}
