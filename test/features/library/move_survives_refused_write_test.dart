// A move the scan proved has to reach every store keyed on the song's path,
// even when one of them refuses its write at the time. The catalog is written
// at the new path either way, so the next scan no longer sees a move: unless
// the move is kept somewhere, a store that missed it keeps the old path for
// good. These run the app's wiring over preferences that can refuse writes,
// and rebuild it from what was saved, as a restart does.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/pending_track_move_store.dart';
import 'package:linthra/core/services/local_track_move_applier.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/pending_track_move_store_provider.dart';
import 'package:linthra/data/repositories/play_history_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/data/repositories/shared_preferences_favorites_store.dart';
import 'package:linthra/data/repositories/shared_preferences_library_added_store.dart';
import 'package:linthra/data/repositories/shared_preferences_pending_track_move_store.dart';
import 'package:linthra/data/repositories/shared_preferences_play_history_store.dart';
import 'package:linthra/data/repositories/shared_preferences_playlist_store.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// The preferences file on disk. Survives a restart; [refusing] names the keys
/// whose writes it turns down, the way a full disk would ([everything] for
/// all of them).
class _Disk extends InMemorySharedPreferencesStore {
  _Disk() : super.empty();

  static const String everything = '*';

  final Set<String> refusing = <String>{};

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (refusing.contains(everything) || refusing.contains(key)) return false;
    return super.setValue(valueType, key, value);
  }
}

/// The record of kept moves, failing to be read while [unreadable] is set, the
/// way storage that is there but not answering would.
class _Journal implements PendingTrackMoveStore {
  bool unreadable = false;

  static const PendingTrackMoveStore _disk =
      SharedPreferencesPendingTrackMoveStore();

  @override
  Future<List<PendingTrackMove>> load() {
    if (unreadable) {
      throw const PendingTrackMoveJournalUnreadable(
        PendingTrackMoveJournalFault.readFailed,
      );
    }
    return _disk.load();
  }

  @override
  Future<void> save(List<PendingTrackMove> moves) => _disk.save(moves);
}

class _MapMetadataReader implements LocalMetadataReader {
  _MapMetadataReader(this.byPath);

  Map<String, LocalAudioMetadata> byPath;

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => byPath[path];
}

const LocalAudioMetadata _holocene = LocalAudioMetadata(
  title: 'Holocene',
  artist: 'Bon Iver',
  albumArtist: 'Bon Iver',
  album: 'Bon Iver',
  trackNumber: 5,
  duration: Duration(milliseconds: 337000),
);

const LocalAudioMetadata _towers = LocalAudioMetadata(
  title: 'Towers',
  artist: 'Bon Iver',
  albumArtist: 'Bon Iver',
  album: 'Bon Iver',
  trackNumber: 6,
  duration: Duration(milliseconds: 188000),
);

const String _old = '/music/inbox/track05.flac';
const String _new = '/music/Bon Iver/05 Holocene.flac';
const String _newer = '/music/Bon Iver/Bon Iver/05 Holocene.flac';
const String _other = '/music/Bon Iver/06 Towers.flac';

const String _playlistsKey = 'flutter.playlists_v1';
const String _favoritesKey = 'flutter.favorites_v2';
const String _journalKey = 'flutter.pending_track_moves_v1';

final DateTime _addedLongAgo = DateTime.utc(2021, 6, 1);

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late _Disk disk;
  late InMemoryMusicLibraryRepository catalog;
  late FakeAudioFileScanner scanner;
  late _MapMetadataReader tags;
  late ProviderContainer c;
  late _Journal journal;

  /// Starts the app over what [disk] and [catalog] hold.
  Future<void> launch() async {
    SharedPreferences.resetStatic();
    c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: const <String>['/music'],
          ),
        ),
        favoritesStoreProvider
            .overrideWithValue(const SharedPreferencesFavoritesStore()),
        playlistStoreProvider
            .overrideWithValue(const SharedPreferencesPlaylistStore()),
        playHistoryStoreProvider
            .overrideWithValue(const SharedPreferencesPlayHistoryStore()),
        libraryAddedStoreProvider
            .overrideWithValue(const SharedPreferencesLibraryAddedStore()),
        pendingTrackMoveStoreProvider.overrideWithValue(journal),
        musicLibraryRepositoryProvider.overrideWith(
          (Ref ref) => RecordingMusicLibraryRepository(
            delegate: catalog,
            addedStore: ref.watch(libraryAddedStoreProvider),
            now: () => DateTime.utc(2026, 9, 10),
          ),
        ),
        audioFileScannerProvider.overrideWithValue(scanner),
        localMetadataReaderProvider.overrideWithValue(tags),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    await c.read(selectedFolderControllerProvider.future);
  }

  /// Closes the app. Nothing kept in memory survives this.
  Future<void> quit() async {
    c.dispose();
    await pumpEventQueue();
  }

  Future<void> rescan() =>
      c.read(localMusicControllerProvider.notifier).rescan();

  void onDisk(Map<String, LocalAudioMetadata> files) {
    tags.byPath = files;
    scanner.filesByFolder = <String, List<String>>{
      '/music': files.keys.toList(),
    };
  }

  /// What a fresh launch would read from the preferences.
  Future<
      ({
        List<String> playlist,
        Set<String> hearts,
        PlayHistory history,
        Map<String, DateTime> added,
      })> saved() async {
    SharedPreferences.resetStatic();
    final List<Playlist> playlists =
        await const SharedPreferencesPlaylistStore().load();
    return (
      playlist: playlists.single.trackIds,
      hearts: (await const SharedPreferencesFavoritesStore().load()).localIds,
      history: await const SharedPreferencesPlayHistoryStore().load(),
      added: await const SharedPreferencesLibraryAddedStore().load(),
    );
  }

  Future<void> expectAllAt(String uri, {required String gone}) async {
    final s = await saved();
    expect(s.playlist, <String>[uri, _other], reason: 'playlist');
    expect(s.hearts, <String>{uri}, reason: 'heart');
    expect(s.history.playCountFor(uri), 2, reason: 'play count');
    expect(s.history.hasPlayed(gone), isFalse, reason: 'play count');
    expect(s.added[uri]?.toUtc(), _addedLongAgo, reason: 'added on');
    expect(s.added.containsKey(gone), isFalse, reason: 'added on');
  }

  /// [_old] and [_other] indexed; [_old] hearted, played twice, added years
  /// ago, and first in a playlist.
  setUp(() async {
    disk = _Disk();
    SharedPreferencesStorePlatform.instance = disk;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });
    SafeEventLog.instance.clear();
    journal = _Journal();
    catalog = InMemoryMusicLibraryRepository();
    scanner = FakeAudioFileScanner();
    tags = _MapMetadataReader(const <String, LocalAudioMetadata>{});
    SharedPreferences.resetStatic();
    await const SharedPreferencesPlaylistStore().save(const <Playlist>[
      Playlist(id: 'mix', name: 'Mix', trackIds: <String>[_old, _other]),
    ]);
    await const SharedPreferencesFavoritesStore()
        .save(const FavoritesData(localIds: <String>{_old}));
    await const SharedPreferencesPlayHistoryStore().save(PlayHistory(
      stats: <String, TrackPlayStats>{
        _old: TrackPlayStats(playCount: 2, lastPlayedAt: DateTime.utc(2026, 3)),
      },
    ));
    await const SharedPreferencesLibraryAddedStore()
        .save(<String, DateTime>{_old: _addedLongAgo});

    onDisk(
        const <String, LocalAudioMetadata>{_old: _holocene, _other: _towers});
    await launch();
    await rescan();
    addTearDown(quit);
  });

  Future<List<String>> catalogUris() async => <String>[
        for (final Track t in await catalog.getAllTracks()) t.uri
      ]..sort();

  Future<List<PendingTrackMove>> kept() async {
    SharedPreferences.resetStatic();
    return const SharedPreferencesPendingTrackMoveStore().load();
  }

  void moveTheFile() => onDisk(
      const <String, LocalAudioMetadata>{_new: _holocene, _other: _towers});

  /// What the record of kept moves holds on disk, as it is stored.
  Future<Object?> journalOnDisk() async => (await disk.getAll())[_journalKey];

  List<String> reported() => <String>[
        for (final SafeEvent event in SafeEventLog.instance.events)
          if (event.category == 'track-move-journal') event.detail,
      ];

  test('a move the playlists missed reaches them after a restart', () async {
    moveTheFile();
    disk.refusing.add(_playlistsKey);
    await rescan();
    expect((await saved()).playlist, <String>[_old, _other]);
    // The catalog moved on, so no scan can find the move again: only the
    // playlists' part of it is kept, and that is what brings it back.
    expect(await catalogUris(), <String>[_new, _other]..sort());
    expect(await kept(), const <PendingTrackMove>[
      PendingTrackMove(
        from: _old,
        to: _new,
        targets: <String>{LocalTrackMoveApplier.playlists},
      ),
    ]);

    await quit();
    disk.refusing.clear();
    await launch();
    await rescan();

    await expectAllAt(_new, gone: _old);
    expect(await kept(), isEmpty);
  });

  test('a move the hearts missed reaches them after a restart', () async {
    moveTheFile();
    disk.refusing.add(_favoritesKey);
    await rescan();
    expect((await saved()).hearts, <String>{_old});

    await quit();
    disk.refusing.clear();
    await launch();
    await rescan();

    await expectAllAt(_new, gone: _old);
  });

  test('a move made while nothing could be saved is not lost', () async {
    moveTheFile();
    disk.refusing.add(_Disk.everything);
    await rescan();
    // Nothing could keep the move, so the catalog wasn't written: still at
    // the old path, it lets the next scan find the move again.
    expect(await catalogUris(), <String>[_old, _other]..sort());

    await quit();
    disk.refusing.clear();
    await launch();
    await rescan();

    await expectAllAt(_new, gone: _old);
  });

  test('a store that missed a move catches up without a restart', () async {
    moveTheFile();
    disk.refusing.add(_playlistsKey);
    await rescan();

    disk.refusing.clear();
    await rescan();

    await expectAllAt(_new, gone: _old);
  });

  test('every playlist with the song follows it, once, after a restart',
      () async {
    SharedPreferences.resetStatic();
    await const SharedPreferencesPlaylistStore().save(const <Playlist>[
      Playlist(id: 'mix', name: 'Mix', trackIds: <String>[_old, _other]),
      Playlist(id: 'b', name: 'B', trackIds: <String>[_new, _other, _old]),
      Playlist(id: 'c', name: 'C', trackIds: <String>[_other]),
    ]);
    await quit();
    await launch();

    moveTheFile();
    disk.refusing.add(_playlistsKey);
    await rescan();
    await quit();
    disk.refusing.clear();
    await launch();
    await rescan();

    SharedPreferences.resetStatic();
    final Map<String, List<String>> songs = <String, List<String>>{
      for (final Playlist p
          in await const SharedPreferencesPlaylistStore().load())
        p.id: p.trackIds,
    };
    expect(songs, <String, List<String>>{
      'mix': <String>[_new, _other],
      'b': <String>[_new, _other],
      'c': <String>[_other],
    });
  });

  group('a record of kept moves that is broken on disk', () {
    const Map<String, String> broken = <String, String>{
      'not JSON': '{this is broken',
      'cut short': '[{"f":"/a","t":"/b"',
      'a bad entry': '[{"f": "/a", "t": "/b", "s": ["playlists"]},'
          '{"garbage": true}]',
    };
    for (final MapEntry<String, String> record in broken.entries) {
      test(
          '${record.key}: is kept as it is, and a move it could not keep '
          'waits in the catalog', () async {
        await disk.setValue('String', _journalKey, record.value);
        await quit();
        await launch();

        moveTheFile();
        disk.refusing.add(_playlistsKey);
        await rescan();

        // Writing the catalog now would lose the playlists' part of the
        // move: the record can't take it, and the next scan wouldn't see it.
        expect(await catalogUris(), <String>[_old, _other]..sort());
        expect((await saved()).playlist, <String>[_old, _other]);
        expect(await journalOnDisk(), record.value);
        expect(reported(), containsAll(<String>['corrupt', 'held-back']));

        await quit();
        disk.refusing.clear();
        await launch();
        await rescan();

        // Every store takes it this time, so nothing has to be kept.
        await expectAllAt(_new, gone: _old);
        expect(await catalogUris(), <String>[_new, _other]..sort());
        expect(await journalOnDisk(), record.value);
      });
    }
  });

  test('once a broken record is gone, moves are kept again as before',
      () async {
    await disk.setValue('String', _journalKey, '{this is broken');
    await quit();
    await launch();
    moveTheFile();
    disk.refusing.add(_playlistsKey);
    await rescan();
    expect(await catalogUris(), <String>[_old, _other]..sort());

    // Cleared while the app was closed; the playlists still refuse.
    await quit();
    await disk.remove(_journalKey);
    await launch();
    await rescan();

    expect(await catalogUris(), <String>[_new, _other]..sort());
    expect(await kept(), const <PendingTrackMove>[
      PendingTrackMove(
        from: _old,
        to: _new,
        targets: <String>{LocalTrackMoveApplier.playlists},
      ),
    ]);

    await quit();
    disk.refusing.clear();
    await launch();
    await rescan();

    await expectAllAt(_new, gone: _old);
    expect(await journalOnDisk(), isNull);
  });

  test(
      'a record that cannot be read holds the scan back, and the moves land '
      'in order once it can', () async {
    moveTheFile();
    disk.refusing.add(_playlistsKey);
    await rescan();
    disk.refusing.clear();

    // The song moves again while the record, still holding the playlists'
    // part of the first move, cannot be read.
    journal.unreadable = true;
    onDisk(
        const <String, LocalAudioMetadata>{_newer: _holocene, _other: _towers});
    await rescan();

    // The playlists still need the first move before this one; with the
    // catalog left as it was, the next scan finds this one again.
    expect(await catalogUris(), <String>[_new, _other]..sort());
    expect((await saved()).playlist, <String>[_old, _other]);
    expect((await saved()).hearts, <String>{_new});
    expect(reported(), <String>['read-failed', 'held-back']);

    await quit();
    journal.unreadable = false;
    await launch();
    await rescan();

    await expectAllAt(_newer, gone: _new);
    expect((await saved()).playlist, isNot(contains(_old)));
    expect(await catalogUris(), <String>[_newer, _other]..sort());
    expect(await kept(), isEmpty);
  });
}
