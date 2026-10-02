// A drive that goes away after the walk, while the scan is still stat'ing and
// parsing the files it listed, must not cost the library their tags or covers.
//
// IoAudioFileScanner checks the selected folder is still there once the walk
// is done (#415), so a drive pulled *during the walk* fails the folder and
// keeps its music. The files the walk listed are then stat'ed and parsed one
// at a time, and from the moment the drive is gone each of them can be neither
// stat'ed nor read. That is unknown, not "a file with no tags": the row already
// indexed for it is kept instead of one rebuilt from the file name, and the
// artwork sweep keeps the covers those rows still point at.
//
// Staged with the real walk (IoAudioFileScanner over a temp folder), the real
// stat reader, the real tag reader and artwork cache, and the real Drift
// catalog. The unplug is an IOOverrides `stat` that answers "not found" for the
// music folder from the moment the walk's own presence check has passed.
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
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
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

/// The walk's end-of-walk presence check. It answers "still there", and when
/// [armed] the drive is pulled right after it has answered.
class _PulledAfterWalk implements DirectoryReadability {
  bool armed = false;
  bool pulled = false;

  @override
  Future<LocalRootFault?> inspect(String path) async {
    if (armed) pulled = true;
    return null;
  }
}

/// Once the drive is pulled, every path on it stats as not found, which is
/// what `stat` answers for a mount point that udisks has torn down.
final class _PulledDrive extends IOOverrides {
  _PulledDrive({
    required this.mount,
    required this.notFound,
    required this.drive,
  });

  final String mount;
  final FileStat notFound;
  final _PulledAfterWalk drive;

  @override
  Future<FileStat> stat(String path) {
    if (drive.pulled && (path == mount || p.isWithin(mount, path))) {
      return Future<FileStat>.value(notFound);
    }
    return super.stat(path);
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

    final _PulledAfterWalk drive = _PulledAfterWalk();
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
            .overrideWithValue(IoAudioFileScanner(presence: drive)),
        localMetadataReaderProvider.overrideWithValue(reader),
        localFileStatReaderProvider
            .overrideWithValue(const IoLocalFileStatReader()),
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
    final FileStat notFound =
        await FileStat.stat(p.join(sandbox.path, 'not-there'));
    drive.armed = true;
    await IOOverrides.runWithIOOverrides(
      () => c.read(localMusicControllerProvider.notifier).rescan(),
      _PulledDrive(mount: mount, notFound: notFound, drive: drive),
    );
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
