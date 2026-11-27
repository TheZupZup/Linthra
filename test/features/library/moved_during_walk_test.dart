// A file or an album folder moved while a scan's walk is listing folders keeps
// its heart, its play count and its "added on" date.
//
// The walk lists one folder at a time, so a move made in between can be seen
// twice: the old path in a folder listed before the move, the new path in one
// listed after it. The old path then cannot be read, and its row is kept,
// because a file that cannot be read is not known to be gone
// (file_moved_mid_scan_test.dart). Kept beside the file it is, though, it
// outlived the move: the next scan found the old path gone and the new one
// already indexed, with nothing to match it to.
//
// Staged on a real disk with the production walk, stat reader, tag reader and
// artwork cache (in the Rust core), the production Recording-over-Drift
// catalog, and the real favourites and play-history repositories. The only
// staged part is *when* the user's move happens: right after the music folder
// itself has been listed, before the folders in it are walked.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/native_audio_file_scanner.dart';
import 'package:linthra/core/sources/local/native_file_reads.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/play_history_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';
import 'package:path/path.dart' as p;

import '../../core/sources/local/audio_tag_fixtures.dart';
import 'fake_folder_picker_service.dart';

/// The production walk, one folder at a time as it walks, with [move] made
/// once the music folder's own listing has been read and before the folders
/// in it are walked.
class _MoveDuringWalk implements AudioFileScanner {
  void Function()? move;
  bool moved = false;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) async {
    final List<String> paths = <String>[];
    final List<String> folders = <String>[];
    for (final FileSystemEntity entity
        in Directory(folder).listSync(followLinks: false)) {
      if (entity is File) paths.add(entity.path);
      if (entity is Directory) folders.add(entity.path);
    }
    final void Function()? pending = move;
    if (pending != null && !moved) {
      moved = true;
      pending();
    }
    for (final String inner in folders) {
      try {
        paths.addAll(await const NativeAudioFileScanner().listFiles(
          inner,
          onUnreadableDirectory: onUnreadableDirectory,
          onUnopenableName: onUnopenableName,
        ));
      } on FolderScanException {
        // Moved away after the music folder listed it: skipped and reported,
        // as the walk skips a folder it can't list.
        onUnreadableDirectory?.call(inner);
      }
    }
    return paths;
  }
}

/// The production stat reader, except that [failing] can't be stat'ed: a file
/// a flaky drive fails to answer for the length of a scan, though it is
/// still in its folder.
class _Stats
    implements LocalFileStatReader, LocalFileStampBatch, LocalFileAbsence {
  String? failing;
  static const NativeLocalFileStatReader _real = NativeLocalFileStatReader();

  @override
  Future<LocalFileStamp?> stamp(String path) async =>
      path == failing ? null : _real.stamp(path);

  @override
  Future<List<LocalFileStamp?>> stampAll(List<String> paths) async {
    final List<LocalFileStamp?> stamps = await _real.stampAll(paths);
    return <LocalFileStamp?>[
      for (int i = 0; i < stamps.length; i++)
        paths[i] == failing ? null : stamps[i],
    ];
  }

  @override
  Future<bool> isGone(String path, {required String root}) =>
      _real.isGone(path, root: root);
}

/// The production tag reader, except that the file [stats] can't stat can't
/// be read either.
class _Reads implements LocalMetadataReader, LocalMetadataReadOutcomes {
  _Reads(this._real, this._stats);

  final FilesystemLocalMetadataReader _real;
  final _Stats _stats;

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async =>
      path == _stats.failing ? null : _real.readFromPath(path);

  @override
  Future<LocalMetadataRead> readWithOutcome(String path) async =>
      path == _stats.failing
          ? (metadata: null, failed: true)
          : _real.readWithOutcome(path);
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late Directory sandbox;
  late String music;
  late InMemoryLibraryAddedStore addedStore;
  late InMemoryFavoritesStore favoritesStore;
  late InMemoryPlayHistoryStore historyStore;
  late _MoveDuringWalk walk;
  late _Stats stats;
  late ProviderContainer c;

  setUp(() async {
    walk = _MoveDuringWalk();
    stats = _Stats();
    sandbox = await Directory.systemTemp.createTemp('linthra_moved_walk_');
    music = p.join(sandbox.path, 'Music');
    Directory(music).createSync();
    addedStore = InMemoryLibraryAddedStore();
    favoritesStore = InMemoryFavoritesStore();
    historyStore = InMemoryPlayHistoryStore();
    final FilesystemLocalMetadataReader reader = FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(
        directory: () async => Directory(p.join(sandbox.path, 'artwork')),
      ),
    );
    c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: <String>[music],
          ),
        ),
        linthraDatabaseExecutorProvider
            .overrideWithValue(NativeDatabase.memory()),
        libraryAddedStoreProvider.overrideWithValue(addedStore),
        recordingDriftMusicLibraryRepositoryOverride,
        favoritesStoreProvider.overrideWithValue(favoritesStore),
        playHistoryStoreProvider.overrideWithValue(historyStore),
        audioFileScannerProvider.overrideWithValue(walk),
        localFileStatReaderProvider.overrideWithValue(stats),
        localMetadataReaderProvider.overrideWithValue(_Reads(reader, stats)),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(() async {
      c.dispose();
      await reader.close();
      await sandbox.delete(recursive: true);
    });
    await c.read(selectedFolderControllerProvider.future);
  });

  Future<void> rescan() =>
      c.read(localMusicControllerProvider.notifier).rescan();

  Future<Set<String>> catalog() async => <String>{
        for (final Track t
            in await c.read(musicLibraryRepositoryProvider).getAllTracks())
          t.uri,
      };

  void writeHolocene(String path) {
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsBytesSync(
      AudioTagFixtures.flac(
        title: 'Holocene',
        artist: 'Bon Iver',
        albumArtist: 'Bon Iver',
        album: 'Bon Iver',
        track: '5',
      ),
      flush: true,
    );
  }

  /// [path] indexed long ago, hearted and played twice.
  Future<void> indexWithHistory(String path) async {
    await addedStore.save(<String, DateTime>{path: DateTime.utc(2021, 6, 1)});
    await rescan();
    expect(await catalog(), <String>{path});
    expect(
      (await c.read(musicLibraryRepositoryProvider).getTrackByUri(path))!
          .duration,
      greaterThan(Duration.zero),
      reason: 'precondition: real tags, so the track has a move identity',
    );
    await favoritesStore.save(FavoritesData(localIds: <String>{path}));
    await historyStore.save(PlayHistory(stats: <String, TrackPlayStats>{
      path: TrackPlayStats(playCount: 2, lastPlayedAt: DateTime.utc(2026, 3)),
    }));
  }

  Future<void> expectHistoryAt(String path) async {
    expect((await favoritesStore.load()).localIds, <String>{path},
        reason: 'the heart must follow the file');
    expect((await historyStore.load()).playCountFor(path), 2,
        reason: 'the play count must follow the file');
    expect((await addedStore.load())[path], DateTime.utc(2021, 6, 1),
        reason: '"added on" must follow the file, not become today');
  }

  test(
      'a file filed into its album folder while the walk lists keeps its '
      'history', () async {
    final String from = p.join(music, 'track05.flac');
    final String to = p.join(music, 'Bon Iver', 'Bon Iver', '05 Holocene.flac');
    writeHolocene(from);
    Directory(p.dirname(to)).createSync(recursive: true);
    await indexWithHistory(from);

    // A live-update scan is walking when the listener files the track into
    // its album folder: the music folder was already listed, the album folder
    // not yet.
    walk.move = () => File(from).renameSync(to);
    await rescan();
    expect(walk.moved, isTrue);

    expect(await catalog(), <String>{to});
    await expectHistoryAt(to);

    // The refresh the watcher queues for the events of the move.
    await rescan();

    expect(await catalog(), <String>{to});
    await expectHistoryAt(to);
  });

  test(
      'an album folder moved into an artist folder while the walk lists '
      'keeps its history', () async {
    final String album = p.join(music, 'Bon Iver');
    final String artist = p.join(music, 'Bon Iver (artist)');
    final String from = p.join(album, '05 Holocene.flac');
    final String to = p.join(artist, 'Bon Iver', '05 Holocene.flac');
    writeHolocene(from);
    Directory(artist).createSync();
    await indexWithHistory(from);

    walk.move = () => Directory(album).renameSync(p.join(artist, 'Bon Iver'));
    await rescan();
    expect(walk.moved, isTrue);
    await rescan();

    expect(await catalog(), <String>{to});
    await expectHistoryAt(to);
  });

  test(
      'a file that only failed to read, beside a new copy of it, is not '
      'taken for moved', () async {
    // The copy turns up in the same scan in which the original cannot be read
    // for a moment. The original is still in its folder, so it is not gone,
    // and its history stays with it.
    final String original = p.join(music, 'Bon Iver', '05 Holocene.flac');
    final String copy = p.join(music, 'Favourites', '05 Holocene.flac');
    writeHolocene(original);
    await indexWithHistory(original);
    writeHolocene(copy);

    stats.failing = original;
    await rescan();

    expect(await catalog(), <String>{original, copy});
    await expectHistoryAt(original);

    stats.failing = null;
    await rescan();

    expect(await catalog(), <String>{original, copy});
    await expectHistoryAt(original);
  });
}
