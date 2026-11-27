// A rescan into a network share whose server went away must end (#778).
//
// On an NFS hard mount (the default) or a stalled FUSE share, a listing or a
// `stat` on the share blocks for as long as the mount retries: forever. A
// rescan into such a share never returned, so the Local music card stayed busy
// and the library watcher stopped refreshing every folder.
//
// Staged over a temp folder with the real tag reader and the real Drift
// catalog. The walk and the stat reader read the share in the Rust core,
// past any IOOverrides, so the dead share is staged in front of them: a walk
// that answers, after its stall limit, the way the Rust walk does for a
// folder that stopped answering (native/linthra_core/src/scan/walk.rs), and
// stats that answer nothing (scan/files.rs). Anything else that still
// reaches the share through dart:io never answers either.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/core/sources/local/native_audio_file_scanner.dart';
import 'package:linthra/core/sources/local/native_file_reads.dart';
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

/// The production walk, until the share is [dead]: then a walk of a folder on
/// it gets no answer for its stall limit, and fails as the Rust walk fails a
/// folder that stopped answering.
class _ShareWalk implements AudioFileScanner {
  _ShareWalk(this.mount);

  final String mount;
  bool dead = false;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) async {
    if (dead && _on(mount, folder)) {
      await Future<void>.delayed(_stall);
      throw rootFaultException(folder, LocalRootFault.unavailable);
    }
    return const NativeAudioFileScanner(stallLimit: _stall).listFiles(
      folder,
      onUnreadableDirectory: onUnreadableDirectory,
      onUnopenableName: onUnopenableName,
    );
  }
}

/// The production stat reader, until the share is [dead]: then nothing on it
/// has a stamp, a batch stops at once, and nothing on it is known to be gone,
/// as the Rust reads answer for storage that stopped answering.
class _ShareStats
    implements LocalFileStatReader, LocalFileStampBatch, LocalFileAbsence {
  _ShareStats(this.mount);

  final String mount;
  bool dead = false;
  static const NativeLocalFileStatReader _real =
      NativeLocalFileStatReader(stallLimit: _stall);

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    if (!dead || !_on(mount, path)) return _real.stamp(path);
    await Future<void>.delayed(_stall);
    return null;
  }

  @override
  Future<List<LocalFileStamp?>> stampAll(List<String> paths) async =>
      dead ? const <LocalFileStamp?>[] : _real.stampAll(paths);

  @override
  Future<bool> isGone(String path, {required String root}) async =>
      dead && _on(mount, path) ? false : _real.isGone(path, root: root);
}

bool _on(String mount, String path) => path == mount || p.isWithin(mount, path);

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

    final _ShareWalk walk = _ShareWalk(mount);
    final _ShareStats stats = _ShareStats(mount);
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
        audioFileScannerProvider.overrideWithValue(walk),
        localMetadataReaderProvider.overrideWithValue(reader),
        localFileStatReaderProvider.overrideWithValue(stats),
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

    walk.dead = true;
    stats.dead = true;
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
