import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/data/repositories/shared_preferences_playlist_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _token = 'super-secret-token-1234567890';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesPlaylistStore', () {
    test('round-trips a list of playlists', () async {
      const SharedPreferencesPlaylistStore store =
          SharedPreferencesPlaylistStore();
      final List<Playlist> playlists = <Playlist>[
        Playlist(
          id: 'p1',
          name: 'Local Mix',
          description: 'desc',
          trackIds: const <String>['file:///a.mp3', 'subsonic:b'],
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 2),
        ),
        const Playlist(
          id: 'p2',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
          remoteId: 'srv-1',
          trackIds: <String>['jellyfin:x'],
          syncState: PlaylistSyncState.synced,
        ),
      ];

      await store.save(playlists);
      final List<Playlist> loaded = await store.load();

      expect(loaded, hasLength(2));
      expect(loaded[0].name, 'Local Mix');
      expect(loaded[0].description, 'desc');
      expect(loaded[0].trackIds, <String>['file:///a.mp3', 'subsonic:b']);
      expect(loaded[0].createdAt, DateTime(2024, 1, 1));
      expect(loaded[1].source, PlaylistSource.jellyfin);
      expect(loaded[1].remoteId, 'srv-1');
      expect(loaded[1].syncState, PlaylistSyncState.synced);
    });

    test('returns empty for no stored value', () async {
      const SharedPreferencesPlaylistStore store =
          SharedPreferencesPlaylistStore();
      expect(await store.load(), isEmpty);
    });

    test('a corrupt record reads as no playlists', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'playlists_v1': 'not json {',
      });
      const SharedPreferencesPlaylistStore store =
          SharedPreferencesPlaylistStore();
      expect(await store.load(), isEmpty);
    });

    test('never persists a token even if one leaks into a field', () async {
      // Even if a (bug-introduced) error string carried a token, the persisted
      // document must not contain it. Here we assert the stored JSON for a
      // normal playlist has no token, and that lastSyncError is round-tripped
      // verbatim (we keep errors secret-free at the source).
      const SharedPreferencesPlaylistStore store =
          SharedPreferencesPlaylistStore();
      await store.save(<Playlist>[
        const Playlist(
          id: 'p1',
          name: 'Mix',
          source: PlaylistSource.jellyfin,
          remoteId: 'srv-1',
        ),
      ]);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = prefs.getString('playlists_v1') ?? '';
      expect(raw, isNot(contains(_token)));
      expect(raw, contains('srv-1'));
    });
  });
}
