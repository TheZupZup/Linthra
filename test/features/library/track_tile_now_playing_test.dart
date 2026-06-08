import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/now_playing.dart';
import 'package:linthra/shared/widgets/now_playing_indicator.dart';

import 'fake_remote_track_downloader.dart';

Track _jelly(String id, {String title = 'Careful'}) => Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'NF',
      albumName: 'Perception',
      duration: const Duration(seconds: 200),
    );

Track _sub(String id, {String title = 'Careful'}) => Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: 'NF',
      albumName: 'Perception',
      duration: const Duration(seconds: 200),
    );

/// Pumps one list of [tracks] with [nowPlaying] overridden. Uses a single
/// [WidgetTester.pump] (not pumpAndSettle) because a *playing* indicator animates
/// forever, just like a progress spinner.
Future<void> _pump(
  WidgetTester tester, {
  required List<Track> tracks,
  required NowPlaying nowPlaying,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        nowPlayingProvider.overrideWithValue(nowPlaying),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              for (int i = 0; i < tracks.length; i++)
                TrackTile(tracks: tracks, index: i),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('TrackTile now-playing indicator', () {
    testWidgets('only the current track row shows the indicator',
        (WidgetTester tester) async {
      final Track a = _jelly('a', title: 'Alpha');
      final Track b = _jelly('b', title: 'Beta');
      await _pump(
        tester,
        tracks: <Track>[a, b],
        nowPlaying: NowPlaying(currentTrack: a, isPlaying: true),
      );

      expect(find.byType(NowPlayingIndicator), findsOneWidget);
      expect(
        tester
            .widget<NowPlayingIndicator>(find.byType(NowPlayingIndicator))
            .animating,
        isTrue,
      );
    });

    testWidgets('a paused current track shows a static indicator',
        (WidgetTester tester) async {
      final Track a = _jelly('a');
      await _pump(
        tester,
        tracks: <Track>[a],
        nowPlaying: NowPlaying(currentTrack: a, isPlaying: false),
      );
      // Static: the tree settles.
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<NowPlayingIndicator>(find.byType(NowPlayingIndicator))
            .animating,
        isFalse,
      );
    });

    testWidgets('no indicator when nothing is playing',
        (WidgetTester tester) async {
      await _pump(
        tester,
        tracks: <Track>[_jelly('a')],
        nowPlaying: const NowPlaying(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingIndicator), findsNothing);
    });

    testWidgets('a Jellyfin row marks the Navidrome fallback as current',
        (WidgetTester tester) async {
      // What plays is the Navidrome copy; the displayed Jellyfin row still reads
      // as currently playing.
      await _pump(
        tester,
        tracks: <Track>[_jelly('j1')],
        nowPlaying: NowPlaying(currentTrack: _sub('s1'), isPlaying: true),
      );

      expect(find.byType(NowPlayingIndicator), findsOneWidget);
    });

    testWidgets('the same logical song is marked in two separate lists',
        (WidgetTester tester) async {
      final Track current = _jelly('a');
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            remoteTrackDownloaderProvider
                .overrideWithValue(FakeRemoteTrackDownloader()),
            nowPlayingProvider.overrideWithValue(
              NowPlaying(currentTrack: current, isPlaying: false),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: <Widget>[
                  // "Library" list.
                  TrackTile(tracks: <Track>[_jelly('a')], index: 0),
                  // "Playlist" list: same logical song (same id), own instance.
                  TrackTile(
                    tracks: <Track>[_jelly('a', title: 'Careful (playlist)')],
                    index: 0,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingIndicator), findsNWidgets(2));
    });

    testWidgets('the current row is accessible as now playing',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final Track a = _jelly('a');
      await _pump(
        tester,
        tracks: <Track>[a],
        nowPlaying: NowPlaying(currentTrack: a, isPlaying: true),
      );

      // The tappable row merges its parts' semantics, so "Now playing" is part
      // of the row's combined label (announced when the row is focused).
      expect(find.bySemanticsLabel(RegExp('Now playing')), findsOneWidget);
      handle.dispose();
    });
  });
}
