// The Albums grid's sort control, and "Date added" meaning when the server
// says a song was added rather than when Linthra first saw it (#909).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/library_added_store.dart';
import 'package:linthra/core/repositories/library_song_sort_store.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_library_song_sort_store.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/library_album_sort_store_provider.dart';
import 'package:linthra/data/repositories/library_song_sort_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/album_sort.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/song_sort.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/library/widgets/album_grid_card.dart';
import 'package:linthra/features/library/widgets/song_sort_button.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';
import 'fake_remote_track_downloader.dart';

/// "Ancient" has been on Jellyfin since 2020, but Linthra only synced it
/// yesterday. "Brand New" went up on Jellyfin this week, one song a day later
/// than the other. "Middle" is a local album first seen in 2024, and nothing
/// recorded when "Unstamped" arrived.
final List<Track> _tracks = <Track>[
  Track(
    id: 'a1',
    title: 'Old',
    uri: 'jellyfin:a1',
    artistName: 'Zed',
    albumName: 'Ancient',
    serverAddedAt: DateTime.utc(2020, 1, 1),
  ),
  Track(
    id: 'b1',
    title: 'B one',
    uri: 'jellyfin:b1',
    artistName: 'Abba',
    albumName: 'Brand New',
    trackNumber: 1,
    serverAddedAt: DateTime.utc(2026, 11, 20),
  ),
  Track(
    id: 'b2',
    title: 'B two',
    uri: 'jellyfin:b2',
    artistName: 'Abba',
    albumName: 'Brand New',
    trackNumber: 2,
    serverAddedAt: DateTime.utc(2026, 11, 21),
  ),
  const Track(
    id: '/music/mid.mp3',
    title: 'Mid',
    uri: '/music/mid.mp3',
    albumName: 'Middle',
  ),
  const Track(
    id: '/music/unstamped.mp3',
    title: 'Unst',
    uri: '/music/unstamped.mp3',
    artistName: 'Moby',
    albumName: 'Unstamped',
  ),
];

/// First-seen times: the whole Jellyfin library was stamped by yesterday's
/// first sync, which its server dates must win over.
final Map<String, DateTime> _firstSeen = <String, DateTime>{
  'jellyfin:a1': DateTime.utc(2026, 11, 23),
  'jellyfin:b1': DateTime.utc(2026, 11, 23),
  'jellyfin:b2': DateTime.utc(2026, 11, 23),
  '/music/mid.mp3': DateTime.utc(2024, 6, 1),
};

const Map<AlbumSort, List<String>> _expected = <AlbumSort, List<String>>{
  AlbumSort.titleAscending: <String>[
    'Ancient',
    'Brand New',
    'Middle',
    'Unstamped'
  ],
  AlbumSort.titleDescending: <String>[
    'Unstamped',
    'Middle',
    'Brand New',
    'Ancient'
  ],
  // "Middle" has no artist, so it comes last both ways.
  AlbumSort.artistAscending: <String>[
    'Brand New',
    'Unstamped',
    'Ancient',
    'Middle'
  ],
  AlbumSort.artistDescending: <String>[
    'Ancient',
    'Unstamped',
    'Brand New',
    'Middle'
  ],
  // Nobody knows when "Unstamped" arrived, so it comes last both ways.
  AlbumSort.newestAdded: <String>[
    'Brand New',
    'Middle',
    'Ancient',
    'Unstamped'
  ],
  AlbumSort.oldestAdded: <String>[
    'Ancient',
    'Middle',
    'Brand New',
    'Unstamped'
  ],
};

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

Future<void> _pump(
  WidgetTester tester, {
  LibrarySongSortStore? albumSortStore,
  LibrarySongSortStore? songSortStore,
  LibraryAddedStore? addedStore,
  bool openAlbums = true,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _tracks)),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
        libraryAlbumSortStoreProvider.overrideWithValue(
          albumSortStore ?? InMemoryLibrarySongSortStore(),
        ),
        librarySongSortStoreProvider.overrideWithValue(
          songSortStore ?? InMemoryLibrarySongSortStore(),
        ),
        libraryAddedStoreProvider.overrideWithValue(
          addedStore ?? InMemoryLibraryAddedStore(_firstSeen),
        ),
        unavailableSourceIdsProvider.overrideWithValue(const <String>{}),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
  if (openAlbums) {
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
  }
}

final Finder _albumSort = find.byKey(const Key('library_album_sort'));

Future<void> _sortAlbumsBy(WidgetTester tester, AlbumSort sort) async {
  await tester.tap(_albumSort);
  await tester.pumpAndSettle();
  // The current order's label is on the button too; the menu is drawn last.
  await tester.tap(find.text(albumSortLabel(sort)).last);
  await tester.pumpAndSettle();
}

List<String> _albums(WidgetTester tester) => tester
    .widgetList<AlbumGridCard>(find.byType(AlbumGridCard))
    .map((AlbumGridCard card) => card.album.title)
    .toList();

String _label(WidgetTester tester, Finder button) => tester
    .widget<Text>(find.descendant(of: button, matching: find.byType(Text)))
    .data!;

void main() {
  group('libraryAddedAt (#909)', () {
    test("the server's date wins over the first-seen time", () {
      expect(libraryAddedAt(_tracks[0], _firstSeen), DateTime.utc(2020, 1, 1));
    });

    test('a song its server gives no date falls back on first seen', () {
      expect(libraryAddedAt(_tracks[3], _firstSeen), DateTime.utc(2024, 6, 1));
      expect(libraryAddedAt(_tracks[4], _firstSeen), isNull);
    });
  });

  group('sortAlbums (#909)', () {
    List<Album> albums() => <Album>[
          const Album(id: 'c', title: 'Same', artistName: 'B'),
          const Album(id: 'a', title: 'same', artistName: 'A'),
          const Album(id: 'b', title: 'Same', artistName: 'A'),
          const Album(id: 'd', title: 'Other', artistName: '  '),
        ];

    test('title A to Z is the grouped order, untouched', () {
      final List<Album> grouped = albums();
      expect(identical(sortAlbums(grouped, AlbumSort.titleAscending), grouped),
          isTrue);
    });

    test('only the sorted-by value follows the direction', () {
      // Equal titles stay by artist, then id, whichever way titles run.
      expect(
        sortAlbums(albums(), AlbumSort.titleDescending).map((Album a) => a.id),
        <String>['a', 'b', 'c', 'd'],
      );
      // A blank artist is no artist: last, both ways.
      expect(
        sortAlbums(albums(), AlbumSort.artistDescending).map((Album a) => a.id),
        <String>['c', 'a', 'b', 'd'],
      );
      expect(
        sortAlbums(albums(), AlbumSort.artistAscending).map((Album a) => a.id),
        <String>['a', 'b', 'c', 'd'],
      );
    });

    test('the input list is left alone', () {
      final List<Album> input = albums();
      sortAlbums(input, AlbumSort.artistAscending);
      expect(input.map((Album a) => a.id), <String>['c', 'a', 'b', 'd']);
    });
  });

  group('Albums sort control (#909)', () {
    testWidgets('offers every order and draws each one', (tester) async {
      await _pump(tester);

      expect(_label(tester, _albumSort), 'Title (A to Z)');
      expect(_albums(tester), _expected[AlbumSort.titleAscending]);

      await tester.tap(_albumSort);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckedPopupMenuItem<AlbumSort>>(
              find.byType(CheckedPopupMenuItem<AlbumSort>),
            )
            .map((CheckedPopupMenuItem<AlbumSort> item) => item.value),
        AlbumSort.values,
      );
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      for (final AlbumSort sort in AlbumSort.values) {
        await _sortAlbumsBy(tester, sort);
        expect(_label(tester, _albumSort), albumSortLabel(sort));
        expect(_albums(tester), _expected[sort], reason: '$sort');
      }
    });

    testWidgets('is remembered apart from the Songs order', (tester) async {
      final InMemoryLibrarySongSortStore albumStore =
          InMemoryLibrarySongSortStore();
      final InMemoryLibrarySongSortStore songStore =
          InMemoryLibrarySongSortStore('artistAscending');
      await _pump(
        tester,
        albumSortStore: albumStore,
        songSortStore: songStore,
      );

      await _sortAlbumsBy(tester, AlbumSort.newestAdded);

      expect(await albumStore.read(), 'newestAdded');
      expect(await songStore.read(), 'artistAscending');
    });

    testWidgets('opens on the stored order', (tester) async {
      await _pump(
        tester,
        albumSortStore: InMemoryLibrarySongSortStore('oldestAdded'),
      );

      expect(_label(tester, _albumSort), 'Date added (oldest first)');
      expect(_albums(tester), _expected[AlbumSort.oldestAdded]);
    });

    testWidgets('waits for the dates, keeping the control', (tester) async {
      final _ManualAddedStore added = _ManualAddedStore();
      await _pump(tester, addedStore: added);

      await tester.tap(_albumSort);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Date added (newest first)'));
      await tester.pump();
      await tester.pump();

      expect(find.bySemanticsLabel('Sorting your albums'), findsOneWidget);
      expect(find.byType(AlbumGridCard), findsNothing);
      expect(_label(tester, _albumSort), 'Date added (newest first)');

      added.complete(_firstSeen);
      await tester.pumpAndSettle();

      expect(_albums(tester), _expected[AlbumSort.newestAdded]);
    });
  });

  testWidgets("Songs by date added follow the server's dates (#909)",
      (tester) async {
    await _pump(
      tester,
      songSortStore: InMemoryLibrarySongSortStore(SongSort.newestAdded.name),
      openAlbums: false,
    );

    expect(
      tester
          .widgetList<TrackTile>(find.byType(TrackTile))
          .map((TrackTile tile) => tile.tracks[tile.index].title),
      <String>['B two', 'B one', 'Mid', 'Old', 'Unst'],
    );
    expect(
      _label(tester, find.byKey(const Key('library_song_sort'))),
      songSortLabel(SongSort.newestAdded),
    );
  });
}
