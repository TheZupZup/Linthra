import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/album_tile.dart';
import 'package:linthra/features/library/widgets/artist_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

// No artworkUri anywhere, so these widget tests never reach for the network —
// artwork falls back to the placeholder (mirrors the player screen tests).
List<Track> _sampleTracks() => const <Track>[
      Track(
        id: '1',
        title: 'Alpha',
        uri: 'jellyfin:1',
        artistName: 'Daft Punk',
        albumName: 'Discovery',
      ),
      Track(
        id: '2',
        title: 'Beta',
        uri: 'jellyfin:2',
        artistName: 'Daft Punk',
        albumName: 'Discovery',
      ),
      Track(
        id: '3',
        title: 'Gamma',
        uri: 'jellyfin:3',
        artistName: 'Adele',
        albumName: '25',
      ),
    ];

Future<void> _pump(
  WidgetTester tester, {
  List<Track>? tracks,
  FakePlaybackController? playback,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: tracks ?? _sampleTracks()),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        if (playback != null)
          playbackControllerProvider.overrideWithValue(playback),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const Key('library_search_field')),
    text,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Library search', () {
    testWidgets('the search bar renders once the catalog is loaded',
        (tester) async {
      await _pump(tester);
      expect(find.byKey(const Key('library_search_field')), findsOneWidget);
    });

    testWidgets('typing filters songs by title', (tester) async {
      await _pump(tester);
      await _enter(tester, 'alpha');

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      expect(find.text('Gamma'), findsNothing);
    });

    testWidgets('typing filters songs by artist', (tester) async {
      await _pump(tester);
      await _enter(tester, 'adele');

      // Only Gamma is by Adele.
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('typing filters songs by album', (tester) async {
      await _pump(tester);
      await _enter(tester, 'discovery');

      // Alpha and Beta are both on Discovery; Gamma (album "25") is hidden.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsNothing);
    });

    testWidgets('a query with no matches shows the empty state',
        (tester) async {
      await _pump(tester);
      await _enter(tester, 'zzzzz');

      expect(find.text('No results found.'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('clearing the search restores the full list', (tester) async {
      await _pump(tester);
      await _enter(tester, 'alpha');
      expect(find.text('Beta'), findsNothing);

      await tester.tap(find.byKey(const Key('library_search_clear')));
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
    });

    testWidgets('searching never touches playback', (tester) async {
      final Track playing = _sampleTracks().first;
      final FakePlaybackController controller = FakePlaybackController(
        initial: PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: playing,
        ),
      );
      await _pump(tester, playback: controller);

      await _enter(tester, 'gamma');

      // Filtering the list started nothing and changed nothing about playback.
      expect(controller.playedTracks, isEmpty);
      expect(controller.playCount, 0);
      expect(controller.state.currentTrack?.id, '1');
      expect(controller.state.isPlaying, isTrue);
    });

    testWidgets('search does not expose tokens or authenticated URLs',
        (tester) async {
      await _pump(tester);
      await _enter(tester, 'alpha');

      expect(find.textContaining('api_key'), findsNothing);
      expect(find.textContaining('AccessToken'), findsNothing);
      // The row shows friendly metadata, not the opaque uri.
      expect(find.text('Daft Punk • Discovery'), findsOneWidget);
    });
  });

  group('Library tabs', () {
    testWidgets('the Songs tab renders the tracks', (tester) async {
      await _pump(tester);

      expect(find.text('Songs'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
    });

    testWidgets('the Albums tab renders grouped albums with title/artist/count',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      expect(find.byType(AlbumTile), findsNWidgets(2));
      expect(find.text('Discovery'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      // Album row subtitle: artist + track count.
      expect(find.text('Daft Punk • 2 songs'), findsOneWidget);
    });

    testWidgets('long-pressing an album opens its bulk playlist sheet',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Discovery'));
      await tester.pumpAndSettle();

      expect(find.text('Add 2 songs to playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('the Artists tab renders grouped artists with name/count',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();

      expect(find.byType(ArtistTile), findsNWidgets(2));
      expect(find.text('Daft Punk'), findsOneWidget);
      expect(find.text('Adele'), findsOneWidget);
      // Artist row subtitle: album + track count.
      expect(find.text('1 album • 2 songs'), findsOneWidget);
    });

    testWidgets('long-pressing an artist opens their bulk playlist sheet',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Daft Punk'));
      await tester.pumpAndSettle();

      expect(find.text('Add 2 songs to playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('switching tabs clears the active search', (tester) async {
      await _pump(tester);
      await _enter(tester, 'alpha');
      expect(find.text('Beta'), findsNothing);

      // Move to Albums (clears the query), then back to Songs.
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();

      // The full song list is back — the query did not survive the switch.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
    });

    testWidgets('missing album/artist metadata groups under Unknown',
        (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'x', title: 'Untagged', uri: 'file:///x.mp3'),
        ],
      );

      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      expect(find.text('Unknown Album'), findsOneWidget);

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('Unknown Artist'), findsOneWidget);
    });
  });
}
