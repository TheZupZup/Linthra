import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/data/repositories/shared_preferences_favorites_store.dart';
import 'package:linthra/data/repositories/shared_preferences_play_history_store.dart';
import 'package:linthra/data/repositories/shared_preferences_playlist_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// A preferences backend whose disk is full: reads still work, but every write
/// explicitly reports that it did not happen.
class _FullDisk extends InMemorySharedPreferencesStore {
  _FullDisk(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
      'playlist, favorite and play-history stores reject a write that the '
      'platform did not persist (#797)', () async {
    const SharedPreferencesPlaylistStore playlists =
        SharedPreferencesPlaylistStore();
    const SharedPreferencesFavoritesStore favorites =
        SharedPreferencesFavoritesStore();
    const SharedPreferencesPlayHistoryStore history =
        SharedPreferencesPlayHistoryStore();

    await playlists.save(const <Playlist>[
      Playlist(id: 'old-playlist', name: 'Saved'),
    ]);
    await favorites.save(const FavoritesData(
      localIds: <String>{'file:///saved.mp3'},
    ));
    await history.save(PlayHistory(
      stats: <String, TrackPlayStats>{
        'jellyfin:saved': TrackPlayStats(
          playCount: 2,
          lastPlayedAt: DateTime(2026, 1, 1),
        ),
      },
    ));

    final SharedPreferences saved = await SharedPreferences.getInstance();
    SharedPreferencesStorePlatform.instance = _FullDisk(<String, Object>{
      'flutter.playlists_v1': saved.getString('playlists_v1')!,
      'flutter.favorites_v2': saved.getString('favorites_v2')!,
      'flutter.play_history_v1': saved.getString('play_history_v1')!,
    });
    SharedPreferences.resetStatic();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });

    await expectLater(
      playlists.save(const <Playlist>[
        Playlist(id: 'new-playlist', name: 'Not saved'),
      ]),
      throwsA(
        isA<LocalStoreWriteException>().having(
          (LocalStoreWriteException error) => error.area,
          'area',
          LocalStoreArea.playlists,
        ),
      ),
    );
    await expectLater(
      favorites.save(const FavoritesData(
        localIds: <String>{'file:///not-saved.mp3'},
      )),
      throwsA(
        isA<LocalStoreWriteException>().having(
          (LocalStoreWriteException error) => error.area,
          'area',
          LocalStoreArea.favorites,
        ),
      ),
    );
    await expectLater(
      history.save(PlayHistory(
        stats: <String, TrackPlayStats>{
          'jellyfin:not-saved': TrackPlayStats(
            playCount: 1,
            lastPlayedAt: DateTime(2026, 2, 1),
          ),
        },
      )),
      throwsA(
        isA<LocalStoreWriteException>().having(
          (LocalStoreWriteException error) => error.area,
          'area',
          LocalStoreArea.playHistory,
        ),
      ),
    );

    // A relaunch still sees the last successfully persisted documents. The
    // failed writes were reported instead of being mistaken for durable state.
    SharedPreferences.resetStatic();
    expect((await playlists.load()).single.id, 'old-playlist');
    expect(
      (await favorites.load()).localIds,
      <String>{'file:///saved.mp3'},
    );
    expect((await history.load()).playCountFor('jellyfin:saved'), 2);
    expect((await history.load()).playCountFor('jellyfin:not-saved'), 0);
  });
}
