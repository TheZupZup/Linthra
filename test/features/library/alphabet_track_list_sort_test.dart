import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/song_sort.dart';
import 'package:linthra/features/library/widgets/alphabet_track_list.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';

// The list in the orders the Songs tab offers (#893): the sections and the
// rail follow the sorted-by value, a timeline has neither, and a tap always
// queues what is on screen in the order it is on screen.

const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Zombie',
    uri: 'file:///1.mp3',
    artistName: 'The Cranberries',
    albumName: 'No Need to Argue',
  ),
  Track(
    id: '2',
    title: 'Around the World',
    uri: 'file:///2.mp3',
    artistName: 'Daft Punk',
    albumName: 'Homework',
  ),
  Track(
    id: '3',
    title: 'La vie en rose',
    uri: 'file:///3.mp3',
    artistName: 'Édith Piaf',
    albumName: 'Best Of',
  ),
  Track(id: '4', title: 'Untitled', uri: 'file:///4.mp3'),
  Track(
    id: '5',
    title: 'Help',
    uri: 'file:///5.mp3',
    artistName: '2Pac',
    albumName: '2Pacalypse Now',
  ),
];

final Map<String, DateTime> _addedAt = <String, DateTime>{
  'file:///1.mp3': DateTime(2026, 4, 1),
  'file:///2.mp3': DateTime(2026, 1, 1),
  'file:///3.mp3': DateTime(2026, 3, 1),
  'file:///5.mp3': DateTime(2026, 2, 1),
};

final Finder _list = find.byKey(const Key('library_track_list'));
final Finder _rail = find.byKey(const Key('library_alphabet_index'));

Future<FakePlaybackController> _pump(
  WidgetTester tester, {
  required SongSort sort,
  List<Track> tracks = _tracks,
  Map<String, DateTime>? addedAt,
  double height = 1000,
}) async {
  // Tall enough to build every row and header at once.
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final FakePlaybackController controller = FakePlaybackController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        // On a desktop a tap plays in place, with no player route to push.
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: height,
              child: AlphabetTrackList(
                tracks: tracks,
                sort: sort,
                addedAt: addedAt ?? _addedAt,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

List<String> _rowTitles(WidgetTester tester) => tester
    .widgetList<TrackTile>(find.byType(TrackTile))
    .map((TrackTile tile) => tile.tracks[tile.index].title)
    .toList();

List<String?> _railLetters(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: _rail, matching: find.byType(Text)))
    .map((Text text) => text.data)
    .toList();

Finder _header(String text) =>
    find.descendant(of: _list, matching: find.text(text));

void main() {
  testWidgets('by artist, the rail indexes artists and the untagged go last',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(tester, sort: SongSort.artistAscending);

    expect(_rowTitles(tester), <String>[
      'Help',
      'Around the World',
      'La vie en rose',
      'Zombie',
      'Untitled',
    ]);
    expect(_railLetters(tester), <String>['#', 'D', 'E', 'T', '?']);
    expect(_header('Unknown Artist'), findsOneWidget);
    expect(_header('E'), findsOneWidget, reason: 'Édith files under E');
    expect(
      find.bySemanticsLabel('Jump to artists starting with a number or symbol'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Jump to songs with no artist'), findsOne);
    handle.dispose();
  });

  testWidgets('by album Z to A, the rail runs in the order of the list',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(tester, sort: SongSort.albumDescending);

    expect(_rowTitles(tester), <String>[
      'Zombie',
      'Around the World',
      'La vie en rose',
      'Help',
      'Untitled',
    ]);
    expect(_railLetters(tester), <String>['N', 'H', 'B', '#', '?']);
    expect(_header('Unknown Album'), findsOneWidget);
    expect(find.bySemanticsLabel('Jump to songs with no album'), findsOne);
    expect(
      find.bySemanticsLabel('Jump to albums starting with a number or symbol'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('the unknown section can be jumped to like any letter',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final List<Track> many = <Track>[
      for (int i = 0; i < 30; i++)
        Track(
          id: 'a$i',
          title: 'Song $i',
          uri: 'file:///a$i.mp3',
          artistName: 'Artist ${String.fromCharCode(65 + i % 26)}',
        ),
      const Track(id: 'x', title: 'Mystery', uri: 'file:///x.mp3'),
    ];
    await _pump(
      tester,
      sort: SongSort.artistAscending,
      tracks: many,
      height: 300,
    );
    expect(find.text('Mystery'), findsNothing);

    tester.semantics
        .tap(find.semantics.byLabel('Jump to songs with no artist'));
    await tester.pumpAndSettle();

    expect(find.text('Mystery'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a date order shows neither section headers nor the rail',
      (tester) async {
    await _pump(tester, sort: SongSort.newestAdded);

    expect(_rowTitles(tester), <String>[
      'Zombie',
      'La vie en rose',
      'Help',
      'Around the World',
      'Untitled',
    ]);
    expect(_rail, findsNothing);
    for (final String letter in <String>['#', 'A', 'H', 'L', 'U', 'Z']) {
      expect(_header(letter), findsNothing, reason: 'no $letter header');
    }
  });

  testWidgets('every order queues the rest of the list as it is shown',
      (tester) async {
    for (final SongSort sort in SongSort.values) {
      final FakePlaybackController controller = await _pump(tester, sort: sort);
      final List<String> shown = _rowTitles(tester);

      // A row from the middle, so the start index matters as much as the
      // order.
      await tester.tap(find.text(shown[1]));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.title, shown[1], reason: '$sort');
      expect(
        controller.state.upNext.map((Track t) => t.title).toList(),
        shown.sublist(2),
        reason: '$sort',
      );
    }
  });

  testWidgets('a new order re-sorts the rows already on screen',
      (tester) async {
    await _pump(tester, sort: SongSort.titleAscending);
    expect(_railLetters(tester), <String>['A', 'H', 'L', 'U', 'Z']);

    await _pump(tester, sort: SongSort.artistDescending);

    expect(_rowTitles(tester), <String>[
      'Zombie',
      'La vie en rose',
      'Around the World',
      'Help',
      'Untitled',
    ]);
    expect(_railLetters(tester), <String>['T', 'E', 'D', '#', '?']);

    await _pump(tester, sort: SongSort.oldestAdded);

    expect(_rowTitles(tester).first, 'Around the World');
    expect(_rail, findsNothing);
  });

  testWidgets('new first-seen times re-sort a date order', (tester) async {
    await _pump(tester, sort: SongSort.newestAdded);
    expect(_rowTitles(tester).first, 'Zombie');

    // A rescan stamped the untagged song as the newest arrival.
    await _pump(
      tester,
      sort: SongSort.newestAdded,
      addedAt: <String, DateTime>{
        ..._addedAt,
        'file:///4.mp3': DateTime(2026, 9, 1),
      },
    );

    expect(_rowTitles(tester).first, 'Untitled');
  });
}
