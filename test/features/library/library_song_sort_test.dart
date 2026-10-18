import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/library_added_store.dart';
import 'package:linthra/core/repositories/library_song_sort_store.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_library_song_sort_store.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/library_song_sort_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/song_sort.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/library/widgets/alphabet_track_list.dart';
import 'package:linthra/features/library/widgets/song_sort_button.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';
import 'fake_remote_track_downloader.dart';

const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Zombie',
    uri: 'file:///1.mp3',
    artistName: 'The Cranberries',
    albumName: 'No Need to Argue',
    trackNumber: 7,
  ),
  Track(
    id: '2',
    title: 'Around the World',
    uri: 'file:///2.mp3',
    artistName: 'Daft Punk',
    albumName: 'Homework',
    trackNumber: 7,
  ),
  Track(
    id: '3',
    title: 'La vie en rose',
    uri: 'file:///3.mp3',
    artistName: 'Édith Piaf',
    albumName: 'Best Of',
    trackNumber: 1,
  ),
  Track(id: '4', title: 'Untitled', uri: 'file:///4.mp3'),
  Track(
    id: '5',
    title: '99 Luftballons',
    uri: 'file:///5.mp3',
    artistName: 'Nena',
    albumName: '99 Luftballons',
    trackNumber: 1,
  ),
  Track(
    id: '6',
    title: 'Linger',
    uri: 'file:///6.mp3',
    artistName: 'The Cranberries',
    albumName: 'Everybody Else Is Doing It',
    trackNumber: 2,
  ),
];

/// First-seen times, as RecordingMusicLibraryRepository would have stamped
/// them. "Untitled" was never stamped.
final Map<String, DateTime> _addedAt = <String, DateTime>{
  'file:///1.mp3': DateTime(2026, 4, 1),
  'file:///2.mp3': DateTime(2026, 1, 1),
  'file:///3.mp3': DateTime(2026, 3, 1),
  'file:///5.mp3': DateTime(2026, 2, 1),
  'file:///6.mp3': DateTime(2026, 3, 1),
};

/// What each order shows for [_tracks], written out by hand.
const Map<SongSort, List<String>> _expected = <SongSort, List<String>>{
  SongSort.titleAscending: <String>[
    '99 Luftballons',
    'Around the World',
    'La vie en rose',
    'Linger',
    'Untitled',
    'Zombie',
  ],
  SongSort.titleDescending: <String>[
    'Zombie',
    'Untitled',
    'Linger',
    'La vie en rose',
    'Around the World',
    '99 Luftballons',
  ],
  SongSort.artistAscending: <String>[
    'Around the World',
    'La vie en rose',
    '99 Luftballons',
    'Linger',
    'Zombie',
    'Untitled',
  ],
  SongSort.artistDescending: <String>[
    'Linger',
    'Zombie',
    '99 Luftballons',
    'La vie en rose',
    'Around the World',
    'Untitled',
  ],
  SongSort.albumAscending: <String>[
    '99 Luftballons',
    'La vie en rose',
    'Linger',
    'Around the World',
    'Zombie',
    'Untitled',
  ],
  SongSort.albumDescending: <String>[
    'Zombie',
    'Around the World',
    'Linger',
    'La vie en rose',
    '99 Luftballons',
    'Untitled',
  ],
  SongSort.newestAdded: <String>[
    'Zombie',
    'La vie en rose',
    'Linger',
    '99 Luftballons',
    'Around the World',
    'Untitled',
  ],
  SongSort.oldestAdded: <String>[
    'Around the World',
    '99 Luftballons',
    'La vie en rose',
    'Linger',
    'Zombie',
    'Untitled',
  ],
};

/// A sort store whose read resolves when the test says so, and which records
/// what was written.
class _ManualSortStore implements LibrarySongSortStore {
  final Completer<String?> _read = Completer<String?>();
  final List<String?> writes = <String?>[];

  void completeWith(String? name) => _read.complete(name);

  @override
  Future<String?> read() => _read.future;

  @override
  Future<void> write(String? sortName) async => writes.add(sortName);
}

/// A sort store whose first write is slow, the shape that lets a stale write
/// land last when writes are allowed to race.
class _RacyWriteSortStore implements LibrarySongSortStore {
  int _writes = 0;
  String? stored;

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String? sortName) async {
    // Longer than the menu animations between two picks, so the second
    // write really does start while the first is still running.
    if (_writes++ == 0) await Future<void>.delayed(const Duration(seconds: 5));
    stored = sortName;
  }
}

class _FailingSortStore implements LibrarySongSortStore {
  @override
  Future<String?> read() async => throw StateError('prefs unavailable');

  @override
  Future<void> write(String? sortName) async =>
      throw StateError('prefs unavailable');
}

/// An added store whose load resolves when the test says so.
class _ManualAddedStore implements LibraryAddedStore {
  final Completer<Map<String, DateTime>> _load =
      Completer<Map<String, DateTime>>();

  void complete(Map<String, DateTime> addedAt) => _load.complete(addedAt);

  @override
  Future<Map<String, DateTime>> load() => _load.future;

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {}
}

class _UnreadableAddedStore implements LibraryAddedStore {
  @override
  Future<Map<String, DateTime>> load() async =>
      throw const FormatException('corrupt');

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {}
}

Future<FakePlaybackController> _pump(
  WidgetTester tester, {
  List<Track> tracks = _tracks,
  LibrarySongSortStore? sortStore,
  LibraryAddedStore? addedStore,
  Set<String> unavailableSources = const <String>{},
  TargetPlatform platform = TargetPlatform.linux,
  Size size = const Size(800, 1400),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final FakePlaybackController playback = FakePlaybackController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        playbackControllerProvider.overrideWithValue(playback),
        librarySongSortStoreProvider
            .overrideWithValue(sortStore ?? InMemoryLibrarySongSortStore()),
        libraryAddedStoreProvider.overrideWithValue(
          addedStore ?? InMemoryLibraryAddedStore(_addedAt),
        ),
        unavailableSourceIdsProvider.overrideWithValue(unavailableSources),
      ],
      child: MaterialApp(
        // On a desktop a tap plays in place rather than pushing the player.
        theme: ThemeData(platform: platform),
        home: const LibraryScreen(),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return playback;
}

final Finder _sortButton = find.byKey(const Key('library_song_sort'));
final Finder _rail = find.byKey(const Key('library_alphabet_index'));

Future<void> _sortBy(WidgetTester tester, SongSort sort) async {
  await tester.tap(_sortButton);
  await tester.pumpAndSettle();
  // The current order's label is on the button too; the menu is drawn last.
  await tester.tap(find.text(songSortLabel(sort)).last);
  await tester.pumpAndSettle();
}

List<String> _rows(WidgetTester tester) => tester
    .widgetList<TrackTile>(find.byType(TrackTile))
    .map((TrackTile tile) => tile.tracks[tile.index].title)
    .toList();

String _buttonLabel(WidgetTester tester) => tester
    .widget<Text>(find.descendant(of: _sortButton, matching: find.byType(Text)))
    .data!;

void main() {
  group('Songs sort control (#893)', () {
    testWidgets('shows the current order and offers all eight', (tester) async {
      await _pump(tester);

      expect(_buttonLabel(tester), 'Title (A to Z)');
      expect(_rows(tester), _expected[SongSort.titleAscending]);

      await tester.tap(_sortButton);
      await tester.pumpAndSettle();

      final List<CheckedPopupMenuItem<SongSort>> items = tester
          .widgetList<CheckedPopupMenuItem<SongSort>>(
            find.byType(CheckedPopupMenuItem<SongSort>),
          )
          .toList();
      expect(
        items.map((CheckedPopupMenuItem<SongSort> item) => item.value),
        SongSort.values,
      );
      expect(
        items
            .where((CheckedPopupMenuItem<SongSort> item) => item.checked)
            .map((CheckedPopupMenuItem<SongSort> item) => item.value),
        <SongSort>[SongSort.titleAscending],
      );
      for (final String label in <String>[
        'Title (Z to A)',
        'Artist (A to Z)',
        'Artist (Z to A)',
        'Album (A to Z)',
        'Album (Z to A)',
        'Date added (newest first)',
        'Date added (oldest first)',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('every order is drawn and queued the same way', (tester) async {
      final FakePlaybackController playback = await _pump(tester);

      for (final SongSort sort in SongSort.values) {
        await _sortBy(tester, sort);

        expect(_buttonLabel(tester), songSortLabel(sort));
        final List<String> shown = _rows(tester);
        expect(shown, _expected[sort], reason: '$sort');
        // The rail indexes letters; a timeline has none to jump to.
        expect(
          _rail,
          sort.field == SongSortField.dateAdded ? findsNothing : findsOneWidget,
          reason: '$sort',
        );

        // A row from the middle, so the start index matters as much as the
        // order: what plays next is what is drawn next.
        await tester.tap(find.text(shown[2]));
        await tester.pumpAndSettle();
        expect(playback.state.currentTrack?.title, shown[2], reason: '$sort');
        expect(
          playback.state.upNext.map((Track t) => t.title).toList(),
          shown.sublist(3),
          reason: '$sort',
        );
      }
    });

    testWidgets('a search is sorted too, and keeps its text across orders',
        (tester) async {
      final FakePlaybackController playback = await _pump(tester);

      // "the" matches a title ("Around the World") and an artist (The
      // Cranberries), so the result mixes both.
      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'the',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(_rows(tester), <String>['Around the World', 'Linger', 'Zombie']);

      await _sortBy(tester, SongSort.artistDescending);
      expect(_rows(tester), <String>['Linger', 'Zombie', 'Around the World']);
      expect(find.widgetWithText(TextField, 'the'), findsOneWidget);

      await _sortBy(tester, SongSort.newestAdded);
      expect(_rows(tester), <String>['Zombie', 'Linger', 'Around the World']);

      await tester.tap(find.text('Linger'));
      await tester.pumpAndSettle();
      expect(playback.state.currentTrack?.title, 'Linger');
      expect(
        playback.state.upNext.map((Track t) => t.title).toList(),
        <String>['Around the World'],
        reason: 'only the songs the search shows are queued',
      );

      await tester.tap(find.byKey(const Key('library_search_clear')));
      await tester.pumpAndSettle();
      expect(_rows(tester), _expected[SongSort.newestAdded]);
    });

    testWidgets('a selection survives a new order', (tester) async {
      await _pump(tester);

      await tester.longPress(find.text('Linger'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zombie'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await _sortBy(tester, SongSort.albumAscending);

      expect(find.text('2 selected'), findsOneWidget);
      expect(_rows(tester), _expected[SongSort.albumAscending]);
      final List<String> checked = <String>[
        for (final TrackTile tile
            in tester.widgetList<TrackTile>(find.byType(TrackTile)))
          if (tile.selected) tile.tracks[tile.index].title,
      ];
      expect(checked, <String>['Linger', 'Zombie']);
    });

    testWidgets('a new order starts at its top; the same order keeps its place',
        (tester) async {
      final List<Track> many = <Track>[
        for (int i = 0; i < 80; i++)
          Track(
            id: 's$i',
            title: 'Song ${i.toString().padLeft(2, '0')}',
            uri: 'file:///s$i.mp3',
            artistName: 'Artist ${String.fromCharCode(65 + i % 26)}',
          ),
      ];
      await _pump(tester, tracks: many, size: const Size(800, 700));
      Finder scrollable() => find
          .descendant(
            of: find.byType(AlphabetTrackList),
            matching: find.byType(Scrollable),
          )
          .first;
      double offset() =>
          tester.state<ScrollableState>(scrollable()).position.pixels;

      await tester.drag(scrollable(), const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(offset(), greaterThan(0));

      await _sortBy(tester, SongSort.artistAscending);
      expect(offset(), 0);

      // Within one order the list holds still, selection included (#582).
      await tester.drag(scrollable(), const Offset(0, -900));
      await tester.pumpAndSettle();
      final double before = offset();
      expect(before, greaterThan(0));
      await tester.longPress(find.byType(TrackTile).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(offset(), before);
    });

    testWidgets('lays out above the list on a phone', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.android,
        size: const Size(360, 740),
      );

      expect(tester.takeException(), isNull);
      final Rect button = tester.getRect(_sortButton);
      final Rect list = tester.getRect(find.byType(AlphabetTrackList));
      expect(button.bottom, lessThanOrEqualTo(list.top));
      expect(button.left, list.left);
    });
  });

  group('Songs order is remembered (#893)', () {
    testWidgets('reopens in the order last used', (tester) async {
      await _pump(
        tester,
        sortStore: InMemoryLibrarySongSortStore('artistDescending'),
      );

      expect(_buttonLabel(tester), 'Artist (Z to A)');
      expect(_rows(tester), _expected[SongSort.artistDescending]);
    });

    testWidgets('picking an order stores it by name', (tester) async {
      final InMemoryLibrarySongSortStore store = InMemoryLibrarySongSortStore();
      await _pump(tester, sortStore: store);

      await _sortBy(tester, SongSort.oldestAdded);

      expect(await store.read(), 'oldestAdded');
    });

    testWidgets('an order picked before the stored one loads wins',
        (tester) async {
      final _ManualSortStore store = _ManualSortStore();
      await _pump(tester, sortStore: store);

      await _sortBy(tester, SongSort.newestAdded);
      store.completeWith('artistAscending');
      await tester.pumpAndSettle();

      expect(_buttonLabel(tester), 'Date added (newest first)');
      expect(_rows(tester), _expected[SongSort.newestAdded]);
      expect(store.writes, <String>['newestAdded']);
    });

    testWidgets(
        'picking the order already shown before the stored one loads is '
        'stored', (tester) async {
      final _ManualSortStore store = _ManualSortStore();
      await _pump(tester, sortStore: store);

      // The list shows the fallback while a different order is still being
      // read, and the user picks the fallback on purpose.
      await _sortBy(tester, SongSort.titleAscending);
      store.completeWith('artistDescending');
      await tester.pumpAndSettle();

      expect(_buttonLabel(tester), 'Title (A to Z)');
      expect(store.writes, <String>['titleAscending']);
    });

    testWidgets('an unknown stored order falls back to title', (tester) async {
      await _pump(tester, sortStore: InMemoryLibrarySongSortStore('bogus'));

      expect(_buttonLabel(tester), 'Title (A to Z)');
      expect(_rows(tester), _expected[SongSort.titleAscending]);
    });

    testWidgets('a store that fails keeps the order for the session',
        (tester) async {
      await _pump(tester, sortStore: _FailingSortStore());
      expect(_buttonLabel(tester), 'Title (A to Z)');

      await _sortBy(tester, SongSort.albumDescending);

      expect(tester.takeException(), isNull);
      expect(_buttonLabel(tester), 'Album (Z to A)');
      expect(_rows(tester), _expected[SongSort.albumDescending]);
    });

    testWidgets('the last order picked is the one stored', (tester) async {
      final _RacyWriteSortStore store = _RacyWriteSortStore();
      await _pump(tester, sortStore: store);

      await _sortBy(tester, SongSort.artistAscending);
      await _sortBy(tester, SongSort.albumAscending);
      await tester.pump(const Duration(seconds: 6));

      expect(store.stored, 'albumAscending');
    });
  });

  group('Songs by date added (#893)', () {
    testWidgets('waits for the first-seen times, keeping the control',
        (tester) async {
      final _ManualAddedStore added = _ManualAddedStore();
      await _pump(tester, addedStore: added);

      await tester.tap(_sortButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Date added (newest first)'));
      await tester.pump();
      await tester.pump();

      expect(find.bySemanticsLabel('Sorting your songs'), findsOneWidget);
      expect(find.byType(AlphabetTrackList), findsNothing);
      expect(_buttonLabel(tester), 'Date added (newest first)');

      added.complete(_addedAt);
      await tester.pumpAndSettle();

      expect(_rows(tester), _expected[SongSort.newestAdded]);
    });

    testWidgets('an unreadable store still shows every song', (tester) async {
      await _pump(tester, addedStore: _UnreadableAddedStore());

      await _sortBy(tester, SongSort.newestAdded);

      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Sorting your songs'), findsNothing);
      // With nothing known about when anything arrived, it reads by title.
      expect(_rows(tester), _expected[SongSort.titleAscending]);
    });

    testWidgets('a server that drops out does not move its songs',
        (tester) async {
      // "Shared" has been on Jellyfin since January and turned up in the local
      // folder in May. "Other" is local only, from March.
      const Track jellyfinShared = Track(
        id: 'j1',
        title: 'Shared',
        uri: 'jellyfin:j1',
        artistName: 'Band',
        albumName: 'Record',
        trackNumber: 1,
        duration: Duration(minutes: 3),
      );
      const Track localShared = Track(
        id: '/music/shared.mp3',
        title: 'Shared',
        uri: '/music/shared.mp3',
        artistName: 'Band',
        albumName: 'Record',
        trackNumber: 1,
        duration: Duration(minutes: 3),
      );
      const Track localOther = Track(
        id: '/music/other.mp3',
        title: 'Other',
        uri: '/music/other.mp3',
        artistName: 'Someone',
        albumName: 'Else',
        duration: Duration(minutes: 4),
      );
      final InMemoryLibraryAddedStore added =
          InMemoryLibraryAddedStore(<String, DateTime>{
        'jellyfin:j1': DateTime(2026, 1, 1),
        '/music/shared.mp3': DateTime(2026, 5, 1),
        '/music/other.mp3': DateTime(2026, 3, 1),
      });

      // With Jellyfin unreachable only the local copy is on screen, but the
      // song arrived in January all the same.
      await _pump(
        tester,
        tracks: const <Track>[jellyfinShared, localShared, localOther],
        addedStore: added,
        unavailableSources: const <String>{'jellyfin'},
      );
      await _sortBy(tester, SongSort.newestAdded);

      expect(_rows(tester), <String>['Other', 'Shared']);
    });

    testWidgets('songs nobody stamped stay last in both directions',
        (tester) async {
      await _pump(
        tester,
        addedStore: InMemoryLibraryAddedStore(<String, DateTime>{
          'file:///3.mp3': DateTime(2026, 5, 1),
          'file:///1.mp3': DateTime(2026, 1, 1),
        }),
      );

      await _sortBy(tester, SongSort.newestAdded);
      expect(_rows(tester), <String>[
        'La vie en rose',
        'Zombie',
        '99 Luftballons',
        'Around the World',
        'Linger',
        'Untitled',
      ]);

      await _sortBy(tester, SongSort.oldestAdded);
      expect(_rows(tester), <String>[
        'Zombie',
        'La vie en rose',
        '99 Luftballons',
        'Around the World',
        'Linger',
        'Untitled',
      ]);
    });
  });
}
