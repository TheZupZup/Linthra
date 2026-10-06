// A rescan into a network share whose server went away must end (#778).
//
// On an NFS hard mount (the default) or a stalled FUSE share, a listing or a
// `stat` on the share blocks for as long as the mount retries: forever. A
// rescan into such a share never returned, so the Local music card stayed busy
// and the library watcher stopped refreshing every folder.
//
// Staged with the real walk, stat reader and tag reader over a temp folder and
// the real Drift catalog. The share going away is an IOOverrides under which
// every listing and every `stat` on it never answers.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';
import 'package:path/path.dart' as p;

import '../../core/sources/local/audio_tag_fixtures.dart';
import 'fake_folder_picker_service.dart';

/// How long the walk lets the share go without an answer here.
const Duration _stall = Duration(milliseconds: 200);

/// A folder on the share: its listing never yields, fails or ends.
class _Silent implements Directory {
  _Silent(this._real);

  final Directory _real;

  @override
  String get path => _real.path;

  @override
  Directory get absolute => this;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      StreamController<FileSystemEntity>().stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The share's server went away: nothing on [mount] answers any more.
final class _DeadShare extends IOOverrides {
  _DeadShare(this.mount);

  final String mount;

  bool _on(String path) => path == mount || p.isWithin(mount, path);

  @override
  Future<FileStat> stat(String path) =>
      _on(path) ? Completer<FileStat>().future : super.stat(path);

  @override
  Directory createDirectory(String path) {
    final Directory real = super.createDirectory(path);
    return _on(path) ? _Silent(real) : real;
  }
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  test('a rescan into a share that stopped answering ends, and keeps its music',
      () async {
    final Directory sandbox =
        await Directory.systemTemp.createTemp('linthra_dead_share_');
    addTearDown(() => sandbox.delete(recursive: true));
    final String mount = p.join(sandbox.path, 'nas');
    final String music = p.join(mount, 'Music');
    final Directory album = Directory(p.join(music, 'Bon Iver'))
      ..createSync(recursive: true);
    final Directory artwork = Directory(p.join(sandbox.path, 'artwork'))
      ..createSync();
    for (final (String name, String title) in <(String, String)>[
      ('01.mp3', 'Flume'),
      ('02.mp3', 'Lump Sum'),
    ]) {
      File(p.join(album.path, name)).writeAsBytesSync(
        AudioTagFixtures.mp3(
          title: title,
          artist: 'Bon Iver',
          album: 'For Emma, Forever Ago',
        ),
        flush: true,
      );
    }

    final FilesystemLocalMetadataReader reader = FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(directory: () async => artwork),
    );
    addTearDown(reader.close);
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
              initialFolders: <String>[music]),
        ),
        linthraDatabaseExecutorProvider
            .overrideWithValue(NativeDatabase.memory()),
        driftMusicLibraryRepositoryOverride,
        audioFileScannerProvider
            .overrideWithValue(const IoAudioFileScanner(stallLimit: _stall)),
        localMetadataReaderProvider.overrideWithValue(reader),
        localFileStatReaderProvider
            .overrideWithValue(const IoLocalFileStatReader(stallLimit: _stall)),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);

    Future<List<String?>> titles() async {
      final List<Track> tracks =
          await c.read(musicLibraryRepositoryProvider).getAllTracks();
      return (tracks..sort((Track a, Track b) => a.uri.compareTo(b.uri)))
          .map((Track t) => t.title)
          .toList();
    }

    await c.read(localMusicControllerProvider.notifier).rescan();
    expect(await titles(), <String>['Flume', 'Lump Sum']);

    await IOOverrides.runWithIOOverrides(
      () => c.read(localMusicControllerProvider.notifier).rescan(),
      _DeadShare(mount),
    );

    expect(await titles(), <String>['Flume', 'Lump Sum'],
        reason: 'a share that stopped answering is not one that was emptied');
    expect(c.read(localMusicControllerProvider).busy, isFalse);
    final LocalScanReport report = c.read(localScanReportProvider)!;
    expect(report.rootsUnavailable, 1);
    expect(report.fault, LocalRootFault.unavailable);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
