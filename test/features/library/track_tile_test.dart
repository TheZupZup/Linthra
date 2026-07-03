import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_remote_track_downloader.dart';

Future<void> _pump(
  WidgetTester tester,
  List<Track> tracks, {
  FakePlaybackController? controller,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        if (controller != null)
          playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < tracks.length; i++)
                TrackTile(tracks: tracks, index: i),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TrackTile', () {
    testWidgets('shows the title and a clean artist • album subtitle', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(
          id: '1',
          title: 'Song One',
          uri: 'file:///s1.mp3',
          artistName: 'Artist A',
          albumName: 'Album X',
        ),
      ]);

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A • Album X'), findsOneWidget);
    });

    testWidgets('falls back to the uri when metadata is missing', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(id: '2', title: 'Song Two', uri: 'file:///s2.mp3'),
      ]);

      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('file:///s2.mp3'), findsOneWidget);
    });

    testWidgets('exposes a trailing overflow menu', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      expect(find.byTooltip('More actions'), findsOneWidget);
      // No dedicated, always-visible download button on the row anymore.
      expect(find.byTooltip('Download'), findsNothing);
    });

    testWidgets('overflow menu offers add-to-playlist and remove-from-Linthra',
        (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Remove from Linthra'), findsOneWidget);
    });

    testWidgets('overflow menu offers queue actions', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
    });

    testWidgets(
        'overflow menu offers Add to favorites with an outline heart when not '
        'favorited', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Add to favorites'), findsOneWidget);
      expect(find.text('Remove from favorites'), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });

    testWidgets(
        'choosing Add to favorites likes the track and flips to a filled-heart '
        'Remove — without starting playback or changing the queue',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      await _pump(
        tester,
        const <Track>[Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3')],
        controller: controller,
      );

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to favorites'));
      await tester.pumpAndSettle();

      // Favoriting is a pure like: no track played, no queue change.
      expect(controller.playedTracks, isEmpty);
      expect(controller.state.upNext, isEmpty);

      // Reopening the menu now shows the filled-heart "Remove from favorites".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from favorites'), findsOneWidget);
      expect(find.text('Add to favorites'), findsNothing);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });
  });

  group('TrackTile selection', () {
    testWidgets('long-press starts selection', (tester) async {
      Track? started;
      await _pumpSelectable(
        tester,
        selectionActive: false,
        onSelectStart: (Track t) => started = t,
      );

      await tester.longPress(find.text('Song One'));
      await tester.pumpAndSettle();
      expect(started?.id, '1');
    });

    testWidgets('shows a checkbox and toggles while selecting', (tester) async {
      Track? toggled;
      await _pumpSelectable(
        tester,
        selectionActive: true,
        selected: false,
        onSelectToggle: (Track t) => toggled = t,
      );

      expect(find.byType(Checkbox), findsOneWidget);
      await tester.tap(find.text('Song One'));
      await tester.pumpAndSettle();
      expect(toggled?.id, '1');
    });
  });
}

Future<void> _pumpSelectable(
  WidgetTester tester, {
  required bool selectionActive,
  bool selected = false,
  void Function(Track track)? onSelectStart,
  void Function(Track track)? onSelectToggle,
}) async {
  const List<Track> tracks = <Track>[
    Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TrackTile(
            tracks: tracks,
            index: 0,
            selectable: true,
            selectionActive: selectionActive,
            selected: selected,
            onSelectStart:
                onSelectStart == null ? null : () => onSelectStart(tracks[0]),
            onSelectToggle:
                onSelectToggle == null ? null : () => onSelectToggle(tracks[0]),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
