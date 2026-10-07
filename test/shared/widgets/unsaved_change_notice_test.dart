import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/now_playing_actions.dart';
import 'package:linthra/features/playlists/widgets/add_to_playlist_sheet.dart';

import '../../features/player/fake_playback_controller.dart';

const Track _song = Track(id: 'a', title: 'A', uri: 'file:///a.mp3');

/// A full disk: reads work, every write is refused.
class _FullFavoritesStore implements FavoritesStore {
  @override
  Future<FavoritesData> load() async => FavoritesData.empty;

  @override
  Future<void> save(FavoritesData data) async =>
      throw const LocalStoreWriteException(LocalStoreArea.favorites);
}

class _FullPlaylistStore extends InMemoryPlaylistStore {
  bool refuse = false;

  @override
  Future<void> save(List<Playlist> playlists) async {
    if (refuse) throw const LocalStoreWriteException(LocalStoreArea.playlists);
    return super.save(playlists);
  }
}

void main() {
  testWidgets('a heart the device could not save says so (#808)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          favoritesStoreProvider.overrideWithValue(_FullFavoritesStore()),
          playbackControllerProvider.overrideWithValue(
            FakePlaybackController(
              initial: const PlaybackState(
                status: PlaybackStatus.playing,
                currentTrack: _song,
                source: PlaybackSource.localFile,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: NowPlayingActions(track: _song)),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Favorite'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining("Couldn't save that favorite"), findsOneWidget);
    // Not hearted: it wasn't saved.
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('an add to a playlist the device could not save says so (#808)',
      (tester) async {
    final _FullPlaylistStore store = _FullPlaylistStore();
    await store.save(const <Playlist>[Playlist(id: 'p1', name: 'My Mix')]);
    store.refuse = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[playlistStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showAddToPlaylistSheet(context, const <Track>[_song]),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My Mix'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining("Couldn't save that playlist change"),
      findsOneWidget,
    );
    expect(find.textContaining('Added to My Mix'), findsNothing);
  });
}
