// The artwork half of a local scan's commit (#408), wired the way the app
// wires it: a scan writes the catalog, then tells the reader that owns the
// local artwork cache which covers are still referenced, so the entries left
// behind by deleted, moved and re-tagged files stop accumulating.
//
// The cache's own safety rules are covered in
// test/core/services/local_artwork_cache_test.dart; what is under test here is
// that the sweep is asked for at all, with the right set, and only on the
// platforms whose covers this cache holds.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/mp4_box_guard.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';
import 'package:path/path.dart' as p;

import '../../core/sources/local/audio_tag_fixtures.dart';
import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// A desktop-shaped reader: tags keyed by path, and an artwork cache it owns,
/// recorded rather than written to disk.
class _MaintainingMetadataReader
    implements LocalMetadataReader, LocalArtworkMaintainer {
  _MaintainingMetadataReader(this.byPath);

  Map<String, LocalAudioMetadata> byPath;

  /// One entry per sweep, so a test can tell "never asked" from "asked with
  /// the wrong set" — and can see a superseded scan not sweeping at all.
  final List<Set<Uri>> sweeps = <Set<Uri>>[];

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => byPath[path];

  @override
  Future<void> retainArtwork(Set<Uri> live) async => sweeps.add(live);
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

/// The real guard, on a drive that answers every read of a song with an I/O
/// error while `<song>.eio` sits next to it. Top-level, so it can cross to the
/// parse isolate.
bool _readFailsWhileMarked(File file) {
  if (File('${file.path}.eio').existsSync()) {
    throw FileSystemException(
      'Input/output error',
      file.path,
      const OSError('Input/output error', 5),
    );
  }
  return Mp4BoxGuard.isSafeToParse(file);
}

LocalAudioMetadata _tagged(String title, {Uri? artwork}) => LocalAudioMetadata(
      title: title,
      artist: 'Someone',
      album: 'An Album',
      duration: const Duration(seconds: 180),
      artworkUri: artwork,
    );

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late InMemoryMusicLibraryRepository catalog;
  late FakeAudioFileScanner scanner;
  late _MaintainingMetadataReader reader;

  ProviderContainer container({HostPlatform platform = HostPlatform.linux}) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: const <String>['/music'],
          ),
        ),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(scanner),
        localMetadataReaderProvider.overrideWithValue(reader),
        hostPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    catalog = InMemoryMusicLibraryRepository();
    scanner = FakeAudioFileScanner();
    reader = _MaintainingMetadataReader(<String, LocalAudioMetadata>{});
  });

  Future<void> rescan(ProviderContainer c) =>
      c.read(localMusicControllerProvider.notifier).rescan();

  test('a scan sweeps with exactly the covers the catalog now references',
      () async {
    final Uri coverA = Uri.file('/cache/local_artwork/aaa.img');
    final Uri coverB = Uri.file('/cache/local_artwork/bbb.img');
    scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
      '/music': <String>['/music/a.mp3', '/music/b.mp3', '/music/c.mp3'],
    });
    reader = _MaintainingMetadataReader(<String, LocalAudioMetadata>{
      '/music/a.mp3': _tagged('A', artwork: coverA),
      '/music/b.mp3': _tagged('B', artwork: coverB),
      // c.mp3 has no embedded art at all: it contributes nothing to keep, and
      // must not contribute a null either.
      '/music/c.mp3': _tagged('C'),
    });
    final ProviderContainer c = container();
    await c.read(selectedFolderControllerProvider.future);

    await rescan(c);

    expect(reader.sweeps, hasLength(1));
    expect(reader.sweeps.single, <Uri>{coverA, coverB});
  });

  test('a file that left the library stops keeping its cover alive', () async {
    final Uri coverA = Uri.file('/cache/local_artwork/aaa.img');
    final Uri coverB = Uri.file('/cache/local_artwork/bbb.img');
    scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
      '/music': <String>['/music/a.mp3', '/music/b.mp3'],
    });
    reader = _MaintainingMetadataReader(<String, LocalAudioMetadata>{
      '/music/a.mp3': _tagged('A', artwork: coverA),
      '/music/b.mp3': _tagged('B', artwork: coverB),
    });
    final ProviderContainer c = container();
    await c.read(selectedFolderControllerProvider.future);
    await rescan(c);

    // b.mp3 is deleted from disk.
    scanner.filesByFolder = <String, List<String>>{
      '/music': <String>['/music/a.mp3'],
    };
    await rescan(c);

    expect(reader.sweeps, hasLength(2));
    expect(reader.sweeps.last, <Uri>{coverA});
  });

  test('an unreadable folder sweeps with its retained covers still kept',
      () async {
    // The dangerous case for a live-set sweep: an unplugged drive's tracks are
    // retained rather than deleted, so their covers must be retained too, or
    // plugging the drive back in would mean re-extracting the whole thing.
    final Uri onDisk = Uri.file('/cache/local_artwork/aaa.img');
    final Uri onUsb = Uri.file('/cache/local_artwork/bbb.img');
    scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
      '/music': <String>['/music/a.mp3'],
      '/media/usb': <String>['/media/usb/b.mp3'],
    });
    reader = _MaintainingMetadataReader(<String, LocalAudioMetadata>{
      '/music/a.mp3': _tagged('A', artwork: onDisk),
      '/media/usb/b.mp3': _tagged('B', artwork: onUsb),
    });
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: const <String>['/music', '/media/usb'],
          ),
        ),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(scanner),
        localMetadataReaderProvider.overrideWithValue(reader),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    await rescan(c);

    scanner.unavailable = <String>{'/media/usb'};
    await rescan(c);

    expect(reader.sweeps.last, <Uri>{onDisk, onUsb});
  });

  test('a scan that wrote nothing sweeps nothing', () async {
    // Every folder failed, so the catalog was not rewritten and the live set
    // would be empty: sweeping on it would delete every cover in the cache.
    scanner = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
      '/music': <String>['/music/a.mp3'],
    });
    reader = _MaintainingMetadataReader(<String, LocalAudioMetadata>{
      '/music/a.mp3': _tagged(
        'A',
        artwork: Uri.file('/cache/local_artwork/aaa.img'),
      ),
    });
    final ProviderContainer c = container();
    await c.read(selectedFolderControllerProvider.future);
    await rescan(c);
    expect(reader.sweeps, hasLength(1));

    scanner.unavailable = <String>{'/music'};
    await rescan(c);

    expect(reader.sweeps, hasLength(1));
  });

  test(
      'a cover the system reclaimed is extracted again on the next scan, '
      'though its file did not change', () async {
    // The cache lives in the XDG cache directory, which the user or a cleanup
    // tool may empty at any time. An incremental scan reuses an unchanged
    // file's row as it is, cover included, so without asking the cache which
    // covers are gone, every one of them stayed a placeholder for good.
    // Staged with the real walk, stat, tag reader and artwork cache, and the
    // real Drift catalog.
    final Directory sandbox =
        await Directory.systemTemp.createTemp('linthra_reclaimed_covers_');
    addTearDown(() => sandbox.delete(recursive: true));
    final String music = p.join(sandbox.path, 'Music');
    final Directory album = Directory(p.join(music, 'Bon Iver', 'For Emma'))
      ..createSync(recursive: true);
    final Directory covers = Directory(p.join(sandbox.path, 'cache', 'art'));
    final String song = p.join(album.path, '01 Flume.mp3');
    File(song).writeAsBytesSync(
      AudioTagFixtures.mp3(
        title: 'Flume',
        artist: 'Bon Iver',
        album: 'For Emma, Forever Ago',
        coverImage: await _solidPng(8, 8),
      ),
      flush: true,
    );
    final FilesystemLocalMetadataReader tagReader =
        FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(directory: () async => covers),
    );
    addTearDown(tagReader.close);
    final ProviderContainer c = ProviderContainer(
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
        driftMusicLibraryRepositoryOverride,
        localMetadataReaderProvider.overrideWithValue(tagReader),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    Future<Uri?> coverOf() async =>
        (await c.read(musicLibraryRepositoryProvider).getTrackByUri(song))!
            .artworkUri;

    await rescan(c);
    final Uri? first = await coverOf();
    expect(first, isNotNull);
    expect(File(first!.toFilePath()).existsSync(), isTrue);

    covers.deleteSync(recursive: true);
    await rescan(c);

    final Uri? after = await coverOf();
    expect(after, isNotNull);
    expect(
      File(after!.toFilePath()).existsSync(),
      isTrue,
      reason: 'the cover is still embedded in the file, so the rescan must '
          'not keep pointing the track at a cache entry that is gone',
    );
    final Track track =
        (await c.read(musicLibraryRepositoryProvider).getTrackByUri(song))!;
    expect(track.title, 'Flume');
  });

  test(
      'a song read again for a reclaimed cover keeps its tags when that read '
      'fails', () async {
    // Once the cache is reclaimed, the next scan reads every song with a cover
    // again, though no file changed. One of those reads can fail (a USB drive
    // or a network share answering with an I/O error, a read that runs out of
    // time): the song's tags are no less there for it, and its unchanged file
    // is never read again afterwards. Staged with the real walk, stat, tag
    // reader and artwork cache, and the real Drift catalog. The failing read
    // is the reader's own guard, which reads the file on the parse isolate
    // right before the parse, getting the I/O error the drive gives.
    final Directory sandbox =
        await Directory.systemTemp.createTemp('linthra_cover_reread_');
    addTearDown(() => sandbox.delete(recursive: true));
    final String music = p.join(sandbox.path, 'Music');
    final Directory unsorted = Directory(p.join(music, 'Unsorted'))
      ..createSync(recursive: true);
    final Directory covers = Directory(p.join(sandbox.path, 'cache', 'art'));
    final String song = p.join(unsorted.path, 'track05.flac');
    File(song).writeAsBytesSync(
      AudioTagFixtures.flac(
        title: 'Holocene',
        artist: 'Bon Iver',
        albumArtist: 'Bon Iver',
        album: 'Bon Iver',
        track: '5',
        coverImage: await _solidPng(8, 8),
      ),
      flush: true,
    );
    final FilesystemLocalMetadataReader tagReader =
        FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(directory: () async => covers),
      guard: _readFailsWhileMarked,
    );
    addTearDown(tagReader.close);
    final ProviderContainer c = ProviderContainer(
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
        driftMusicLibraryRepositoryOverride,
        localMetadataReaderProvider.overrideWithValue(tagReader),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    Future<Track> stored() async =>
        (await c.read(musicLibraryRepositoryProvider).getTrackByUri(song))!;

    await rescan(c);
    expect((await stored()).title, 'Holocene');
    expect((await stored()).artworkUri, isNotNull);

    covers.deleteSync(recursive: true);
    final File failing = File('$song.eio')..writeAsStringSync('');
    await rescan(c);

    final Track kept = await stored();
    expect(
      kept.title,
      'Holocene',
      reason: 'the file did not change: one read of it failing says nothing '
          'about the tags it was indexed with',
    );
    expect(kept.albumName, 'Bon Iver');
    expect(kept.duration, greaterThan(Duration.zero));

    // The drive answers again: the cover comes back, the tags stay.
    failing.deleteSync();
    await rescan(c);

    final Track after = await stored();
    expect(after.title, 'Holocene');
    expect(after.artworkUri, isNotNull);
    expect(File(after.artworkUri!.toFilePath()).existsSync(), isTrue);
  });

  test('Android sweeps nothing: its reader owns no artwork cache', () {
    // The platform seam, spelled out. Android's tags and covers come from the
    // native SAF walk, which manages its own cache; the `is` check at the
    // scan's commit is therefore false there and nothing on that side is
    // touched by any of this.
    expect(
      const UnsupportedLocalMetadataReader(),
      isNot(isA<LocalArtworkMaintainer>()),
    );
  });
}
