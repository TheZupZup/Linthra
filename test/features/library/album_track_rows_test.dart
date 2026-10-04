import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/widgets/album_track_number.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/now_playing.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/track_artwork.dart';
import 'package:linthra/shared/widgets/now_playing_indicator.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

const Track _opener = Track(
  id: '1',
  title: 'One More Time',
  uri: 'jellyfin:1',
  artistName: 'Daft Punk',
  albumArtistName: 'Daft Punk',
  albumName: 'Discovery',
  trackNumber: 1,
);

const Track _guest = Track(
  id: '2',
  title: 'Digital Love',
  uri: 'jellyfin:2',
  artistName: 'Daft Punk feat. DJ Sneak',
  albumArtistName: 'Daft Punk',
  albumName: 'Discovery',
  trackNumber: 10,
);

const Track _unnumbered = Track(
  id: '3',
  title: 'Hidden Track',
  uri: 'jellyfin:3',
  artistName: 'Daft Punk',
  albumArtistName: 'Daft Punk',
  albumName: 'Discovery',
);

Future<void> _openAlbum(
  WidgetTester tester, {
  required TargetPlatform platform,
  NowPlaying nowPlaying = const NowPlaying(),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(
            tracks: const <Track>[_opener, _guest, _unnumbered],
          ),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
        nowPlayingProvider.overrideWithValue(nowPlaying),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        home: AlbumDetailScreen(albumId: albumIdForTrack(_opener)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inRow(String title, Finder matching) => find.descendant(
      of: find.widgetWithText(TrackTile, title),
      matching: matching,
    );

void main() {
  group('on a desktop', () {
    testWidgets('rows lead with their track number, not the cover again',
        (tester) async {
      await _openAlbum(tester, platform: TargetPlatform.linux);

      expect(find.byType(TrackArtwork), findsNothing);
      expect(_inRow('One More Time', find.text('1')), findsOneWidget);
      expect(_inRow('Digital Love', find.text('10')), findsOneWidget);
    });

    testWidgets('a song with no number still lines up with the rest',
        (tester) async {
      await _openAlbum(tester, platform: TargetPlatform.linux);

      expect(
        _inRow('Hidden Track', find.byType(AlbumTrackNumber)),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('Hidden Track')).dx,
        tester.getTopLeft(find.text('One More Time')).dx,
      );
    });

    testWidgets('only a song by someone else gets an artist line',
        (tester) async {
      await _openAlbum(tester, platform: TargetPlatform.linux);

      expect(
        _inRow('Digital Love', find.text('Daft Punk feat. DJ Sneak')),
        findsOneWidget,
      );
      // The album's own artist and the album's name are the page's title
      // already.
      expect(
          _inRow('One More Time', find.textContaining('Daft')), findsNothing);
      expect(
        _inRow('One More Time', find.textContaining('Discovery')),
        findsNothing,
      );
    });

    testWidgets('the playing song shows the bars in place of its number',
        (tester) async {
      await _openAlbum(
        tester,
        platform: TargetPlatform.linux,
        nowPlaying: const NowPlaying(currentTrack: _guest),
      );

      expect(
        _inRow('Digital Love', find.byType(NowPlayingIndicator)),
        findsOneWidget,
      );
      expect(_inRow('Digital Love', find.text('10')), findsNothing);
      expect(_inRow('One More Time', find.text('1')), findsOneWidget);
    });
  });

  testWidgets('a phone keeps its artwork rows', (tester) async {
    await _openAlbum(tester, platform: TargetPlatform.android);

    expect(_inRow('One More Time', find.byType(TrackArtwork)), findsOneWidget);
    expect(find.byType(AlbumTrackNumber), findsNothing);
    expect(
      _inRow('One More Time', find.text('Daft Punk • Discovery')),
      findsOneWidget,
    );
  });
}
