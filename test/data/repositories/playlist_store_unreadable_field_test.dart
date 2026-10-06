// One playlist field that can't be read must not cost the playlists.
//
// The store promises a corrupt record reads as "no playlists" rather than
// crashing, and drops a playlist without an id or name. But an optional field
// of another type than a string (a damaged or hand-edited record, or one from
// another build) threw out of the whole load: every playlist was then out of
// reach, and making a new one failed too.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/data/repositories/shared_preferences_playlist_store.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _key = 'playlists_v1';

final String _document = jsonEncode(<Object>[
  <String, Object>{
    'id': 'p1',
    'name': 'Road Trip',
    'trackIds': <String>['/music/a.flac'],
    'syncState': 'localOnly',
  },
  <String, Object>{
    'id': 'p2',
    'name': 'Gym',
    'description': 5,
    'source': 7,
    'remoteId': <String>['x'],
    'syncState': false,
    'lastSyncError': 3.5,
    'trackIds': <String>['/music/b.flac'],
  },
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{_key: _document});
  });

  test('the store reads every playlist, leaving out what it cannot read',
      () async {
    final List<Playlist> loaded =
        await const SharedPreferencesPlaylistStore().load();

    expect(loaded.map((Playlist p) => p.name), <String>['Road Trip', 'Gym']);
    final Playlist gym = loaded.last;
    expect(gym.trackIds, <String>['/music/b.flac']);
    expect(gym.description, isNull);
    expect(gym.remoteId, isNull);
    expect(gym.lastSyncError, isNull);
  });

  test('the playlists stay usable', () async {
    final SyncedPlaylistRepository repository = SyncedPlaylistRepository(
      store: const SharedPreferencesPlaylistStore(),
    );

    final List<Playlist> playlists = await repository.getAllPlaylists();
    expect(playlists.map((Playlist p) => p.name), <String>['Road Trip', 'Gym']);

    await repository.createPlaylist('New');
    SharedPreferences.resetStatic();
    expect(
      (await const SharedPreferencesPlaylistStore().load())
          .map((Playlist p) => p.name),
      <String>['Road Trip', 'Gym', 'New'],
    );
  });
}
