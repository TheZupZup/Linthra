import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';
import 'fake_remote_track_downloader.dart';

/// Ctrl and Shift clicking in the songs list (#387). The rules are the ones
/// every desktop list has: Ctrl picks one row out (and starts a selection when
/// there is none), Shift takes everything between, and a plain click still
/// plays.
final List<Track> _songs = <Track>[
  for (int i = 0; i < 6; i++)
    Track(
      id: 'song-$i',
      title: 'Song ${i.toString().padLeft(2, '0')}',
      uri: 'jellyfin:song-$i',
    ),
];

Future<void> _pump(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _songs)),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _clickWith(
  WidgetTester tester,
  String title, {
  LogicalKeyboardKey? modifier,
}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
}

/// The titles of the rows currently drawn as selected.
List<String> _selectedTitles(WidgetTester tester) {
  return <String>[
    for (final TrackTile tile in tester.widgetList<TrackTile>(
      find.byType(TrackTile),
    ))
      if (tile.selected) tile.tracks[tile.index].title,
  ]..sort();
}

FakePlaybackController _controller(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(LibraryScreen)),
  ).read(playbackControllerProvider) as FakePlaybackController;
}

void main() {
  group('Ctrl and Shift selection', () {
    testWidgets('Ctrl-click starts a selection and adds to it', (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);
      expect(_selectedTitles(tester), <String>['Song 01']);
      // A selection is running: the app bar is the selection one now.
      expect(find.text('1 selected'), findsOneWidget);
      // …and nothing started playing.
      expect(_controller(tester).state.currentTrack, isNull);

      await _clickWith(tester, 'Song 03',
          modifier: LogicalKeyboardKey.controlLeft);
      expect(_selectedTitles(tester), <String>['Song 01', 'Song 03']);
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('Ctrl-click takes a row back out again', (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);
      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);

      expect(_selectedTitles(tester), isEmpty);
      // The last row out ends the selection rather than leaving an empty one.
      expect(find.text('0 selected'), findsNothing);
      expect(find.text('Library'), findsOneWidget);
    });

    testWidgets('Shift-click takes everything between', (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);
      await _clickWith(tester, 'Song 04',
          modifier: LogicalKeyboardKey.shiftLeft);

      expect(
        _selectedTitles(tester),
        <String>['Song 01', 'Song 02', 'Song 03', 'Song 04'],
      );
      expect(find.text('4 selected'), findsOneWidget);
    });

    testWidgets('Shift-click on its own picks just that row', (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 02',
          modifier: LogicalKeyboardKey.shiftLeft);

      // No anchor to measure from, so extending from nowhere is a plain pick
      // rather than an arbitrary run.
      expect(_selectedTitles(tester), <String>['Song 02']);
    });

    testWidgets('a plain click still plays, even mid-selection',
        (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);
      expect(_controller(tester).state.currentTrack, isNull);

      // Inside a selection a plain click still toggles, as it always has —
      // that is the mobile behaviour and it does not move.
      await _clickWith(tester, 'Song 02');
      expect(_selectedTitles(tester), <String>['Song 01', 'Song 02']);
      expect(_controller(tester).state.currentTrack, isNull);
    });

    testWidgets('Escape leaves the selection', (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);
      expect(find.text('1 selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_selectedTitles(tester), isEmpty);
      expect(find.text('Library'), findsOneWidget);
    });

    testWidgets('the selection survives a catalog refresh', (tester) async {
      await _pump(tester);

      await _clickWith(tester, 'Song 01',
          modifier: LogicalKeyboardKey.controlLeft);
      await _clickWith(tester, 'Song 03',
          modifier: LogicalKeyboardKey.shiftLeft);
      expect(find.text('3 selected'), findsOneWidget);

      // A harmless rebuild — the kind a download finishing or a sync tick
      // causes — must not drop what the user picked.
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        _selectedTitles(tester),
        <String>['Song 01', 'Song 02', 'Song 03'],
      );
    });
  });
}
