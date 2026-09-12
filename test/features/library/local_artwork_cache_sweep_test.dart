// The artwork half of a local scan's commit (#408), wired the way the app
// wires it: a scan writes the catalog, then tells the reader that owns the
// local artwork cache which covers are still referenced, so the entries left
// behind by deleted, moved and re-tagged files stop accumulating.
//
// The cache's own safety rules are covered in
// test/core/services/local_artwork_cache_test.dart; what is under test here is
// that the sweep is asked for at all, with the right set, and only on the
// platforms whose covers this cache holds.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

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
