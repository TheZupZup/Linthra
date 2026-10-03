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
// Staged with the real walk (IoAudioFileScanner over a temp folder), the real
// stat reader, the real tag reader and artwork cache, the production
// Recording-over-Drift catalog, and the real favourites and play-history
// repositories. The only staged part is *when* the user's move happens: an
// IOOverrides Directory for the music folder performs it right after the walk
// has listed the music folder itself.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
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

/// The music folder as the walk sees it, except that once its own listing has
/// been read to the end, the user's move happens.
class _ListThenMove implements Directory {
  _ListThenMove(this._real, this._move);

  final Directory _real;
  final void Function() _move;

  @override
  String get path => _real.path;

  @override
  Directory get absolute => _real.absolute;

  @override
  Uri get uri => _real.uri;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    yield* _real.list(recursive: recursive, followLinks: followLinks);
    _move();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _MoveDuringWalk extends IOOverrides {
  _MoveDuringWalk({required this.root, required this.move});

  final String root;
  final void Function() move;
  bool moved = false;

  @override
  Directory createDirectory(String path) {
    final Directory real = super.createDirectory(path);
    if (moved || path != root) return real;
    return _ListThenMove(real, () {
      if (moved) return;
      moved = true;
      move();
    });
  }
}

/// One file the scan cannot stat or read for the length of a scan, though it
/// is still in its folder: a read that failed for a moment on a flaky drive.
final class _ReadFailsFor extends IOOverrides {
  _ReadFailsFor(this.path, this.notFound);

  final String path;
  final FileStat notFound;

  @override
  Future<FileStat> stat(String other) =>
      other == path ? Future<FileStat>.value(notFound) : super.stat(other);
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late Directory sandbox;
  late String music;
  late InMemoryLibraryAddedStore addedStore;
  late InMemoryFavoritesStore favoritesStore;
  late InMemoryPlayHistoryStore historyStore;
  late ProviderContainer c;

  setUp(() async {
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
        // The real walk and the real stat reader are the production defaults.
        localMetadataReaderProvider.overrideWithValue(reader),
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
    final _MoveDuringWalk move = _MoveDuringWalk(
      root: music,
      move: () => File(from).renameSync(to),
    );
    await IOOverrides.runWithIOOverrides(rescan, move);
    expect(move.moved, isTrue);

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

    final _MoveDuringWalk move = _MoveDuringWalk(
      root: music,
      move: () => Directory(album).renameSync(p.join(artist, 'Bon Iver')),
    );
    await IOOverrides.runWithIOOverrides(rescan, move);
    expect(move.moved, isTrue);
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

    final FileStat notFound =
        await FileStat.stat(p.join(sandbox.path, 'not-there'));
    await IOOverrides.runWithIOOverrides(
      rescan,
      _ReadFailsFor(original, notFound),
    );

    expect(await catalog(), <String>{original, copy});
    await expectHistoryAt(original);

    await rescan();

    expect(await catalog(), <String>{original, copy});
    await expectHistoryAt(original);
  });
}
