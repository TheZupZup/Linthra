// A drive that goes away after the walk, while the scan is still stat'ing and
// parsing the files it listed, must not cost the library their tags or covers.
//
// The walk checks the selected folder is still there once it is done (#415),
// so a drive pulled *during the walk* fails the folder and keeps its music.
// The files the walk listed are then stat'ed and parsed one at a time, and
// from the moment the drive is gone each of them can be neither stat'ed nor
// read. That is unknown, not "a file with no tags": the row already indexed
// for it is kept instead of one rebuilt from the file name, and the artwork
// sweep keeps the covers those rows still point at.
//
// Staged on a real disk with the production walk, stat reader, tag reader and
// artwork cache (all in the Rust core) and the real Drift catalog. The unplug
// is the drive's folder renamed away the moment the walk has answered, so
// every read after it meets a drive that is really gone.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/native_audio_file_scanner.dart';
import 'package:linthra/core/sources/local/native_file_reads.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';
import 'package:path/path.dart' as p;

import '../../core/sources/local/audio_tag_fixtures.dart';
import 'fake_folder_picker_service.dart';

/// The production walk, after which the drive is pulled when [armed]: its
/// folder renamed away, as an unmount takes every path on it.
class _PulledAfterWalk implements AudioFileScanner {
  _PulledAfterWalk(this.mount);

  final String mount;
  bool armed = false;
  bool pulled = false;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) async {
    final List<String> files = await const NativeAudioFileScanner().listFiles(
      folder,
      onUnreadableDirectory: onUnreadableDirectory,
      onUnopenableName: onUnopenableName,
    );
    if (armed && !pulled) {
      Directory(mount).renameSync('$mount-pulled');
      pulled = true;
    }
    return files;
  }
}

Future<Uint8List> _solidPng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  test(
      'a drive pulled after the walk keeps the tags and covers of the files '
      'the scan had not reached', () async {
    final Directory sandbox =
        await Directory.systemTemp.createTemp('linthra_pulled_drive_');
    addTearDown(() => sandbox.delete(recursive: true));
    final String mount = p.join(sandbox.path, 'usb');
    final Directory album = Directory(p.join(mount, 'Music', 'Disk A'))
      ..createSync(recursive: true);
    final Directory artwork = Directory(p.join(sandbox.path, 'artwork'))
      ..createSync();
    final String music = p.join(mount, 'Music');

    final Uint8List cover = await _solidPng(8, 8);
    for (final (String name, String title) in <(String, String)>[
      ('track01.mp3', 'Flume'),
      ('track02.mp3', 'Lump Sum'),
      ('track03.mp3', 'Skinny Love'),
    ]) {
      File(p.join(album.path, name)).writeAsBytesSync(
        AudioTagFixtures.mp3(
          title: title,
          artist: 'Bon Iver',
          album: 'For Emma, Forever Ago',
          coverImage: cover,
        ),
        flush: true,
      );
    }

    final _PulledAfterWalk drive = _PulledAfterWalk(mount);
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
        audioFileScannerProvider.overrideWithValue(drive),
        localMetadataReaderProvider.overrideWithValue(reader),
        localFileStatReaderProvider
            .overrideWithValue(const NativeLocalFileStatReader()),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);

    Future<List<Track>> catalog() async {
      final List<Track> tracks =
          await c.read(musicLibraryRepositoryProvider).getAllTracks();
      return tracks..sort((Track a, Track b) => a.uri.compareTo(b.uri));
    }

    List<String> cachedCovers() => <String>[
          for (final FileSystemEntity e in artwork.listSync())
            if (e.path.endsWith('.img')) e.path,
        ]..sort();

    // The library is indexed from the drive, tags and covers included.
    await c.read(localMusicControllerProvider.notifier).rescan();
    final List<Track> before = await catalog();
    expect(before.map((Track t) => t.title),
        <String>['Flume', 'Lump Sum', 'Skinny Love']);
    expect(before.every((Track t) => t.artworkUri != null), isTrue);
    expect(cachedCovers(), hasLength(3));

    // Another scan (the user's Rescan, a watcher refresh): the walk finishes
    // with the drive still there, and the drive is pulled right after.
    drive.armed = true;
    await c.read(localMusicControllerProvider.notifier).rescan();
    expect(drive.pulled, isTrue);

    final List<Track> after = await catalog();
    expect(
      after.map((Track t) => t.title),
      <String>['Flume', 'Lump Sum', 'Skinny Love'],
      reason: 'the scan could not see these files any more, which says '
          'nothing about their tags; it must not replace them with the '
          'file names',
    );
    expect(after.map((Track t) => t.artistName).toSet(), <String?>{'Bon Iver'});
    expect(
      cachedCovers(),
      hasLength(3),
      reason: "the drive going away must not delete the library's covers",
    );
  });
}
