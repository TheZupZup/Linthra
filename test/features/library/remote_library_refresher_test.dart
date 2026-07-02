import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/remote_library_refresher.dart';

class _CountingFavorites implements FavoritesRepository {
  int refreshCount = 0;

  @override
  Future<FavoritesSyncResult> refreshFromRemote() async {
    refreshCount++;
    return const FavoritesSyncResult.synced(0);
  }

  @override
  Stream<Set<String>> get favoritesStream => const Stream<Set<String>>.empty();

  @override
  bool isFavorite(String trackUri) => false;

  @override
  Future<void> setFavorite(Track track, bool favorite) async {}

  @override
  Future<void> clearRemote({String? providerScheme}) async {}
}

class _CountingPlaylists implements PlaylistRepository {
  int refreshCount = 0;

  @override
  Future<PlaylistSyncResult> refreshFromRemote() async {
    refreshCount++;
    return const PlaylistSyncResult.synced(0);
  }

  @override
  Stream<List<Playlist>> get playlistsStream =>
      const Stream<List<Playlist>>.empty();

  @override
  Future<List<Playlist>> getAllPlaylists() async => const <Playlist>[];

  @override
  Future<Playlist?> getPlaylistById(String id) async => null;

  @override
  Future<Playlist> createPlaylist(String name,
          {String? description,
          PlaylistSource source = PlaylistSource.local}) =>
      throw UnimplementedError();

  @override
  Future<void> renamePlaylist(String id, String name, {String? description}) =>
      throw UnimplementedError();

  @override
  Future<void> deletePlaylist(String id) => throw UnimplementedError();

  @override
  Future<void> addTrack(String playlistId, String trackUri) =>
      throw UnimplementedError();

  @override
  Future<void> addTracks(String playlistId, List<String> trackUris) =>
      throw UnimplementedError();

  @override
  Future<void> removeTrack(String playlistId, String trackUri) =>
      throw UnimplementedError();

  @override
  Future<void> reorderTracks(String playlistId, int oldIndex, int newIndex) =>
      throw UnimplementedError();

  @override
  Future<void> markSyncState(String id, PlaylistSyncState state,
          {String? error}) =>
      throw UnimplementedError();

  @override
  Future<void> clearRemote({PlaylistSource? source}) =>
      throw UnimplementedError();
}

void main() {
  group('RemoteLibraryRefresher', () {
    late _CountingFavorites favorites;
    late _CountingPlaylists playlists;
    late Ref ref;
    late DateTime clock;

    ({RemoteLibraryRefresher refresher}) build() {
      favorites = _CountingFavorites();
      playlists = _CountingPlaylists();
      clock = DateTime(2024, 1, 1, 12);
      final container = ProviderContainer(
        overrides: <Override>[
          favoritesRepositoryProvider.overrideWithValue(favorites),
          playlistRepositoryProvider.overrideWithValue(playlists),
        ],
      );
      addTearDown(container.dispose);
      // Capture a real Ref so the refresher reads the overridden repositories,
      // with an injectable clock for the throttle.
      final probe = Provider<Ref>((r) => r);
      ref = container.read(probe);
      return (refresher: RemoteLibraryRefresher(ref, now: () => clock));
    }

    test('a single refresh reconciles both repositories', () async {
      final r = build().refresher;
      await r.refresh();
      expect(favorites.refreshCount, 1);
      expect(playlists.refreshCount, 1);
    });

    test('throttles a second refresh within the cooldown', () async {
      final r = build().refresher;
      await r.refresh();
      await r.refresh(); // same clock → within cooldown → skipped
      expect(favorites.refreshCount, 1);
      expect(playlists.refreshCount, 1);
    });

    test('force bypasses the cooldown', () async {
      final r = build().refresher;
      await r.refresh();
      await r.refresh(force: true);
      expect(favorites.refreshCount, 2);
      expect(playlists.refreshCount, 2);
    });

    test('refreshes again once the cooldown has elapsed', () async {
      final r = build().refresher;
      await r.refresh();
      clock = clock
          .add(RemoteLibraryRefresher.cooldown + const Duration(seconds: 1));
      await r.refresh();
      expect(favorites.refreshCount, 2);
      expect(playlists.refreshCount, 2);
    });
  });
}
