// A music folder that is itself a mount point (#737): an fstab NAS share, or a
// USB disk with a fixed folder under /mnt or /media. While nothing is mounted
// on it the folder stays behind, empty and readable, so a rescan used to read
// it as a library that was emptied and drop every track under it.
//
// The rules are unit-tested in core/sources/local (the scanner merge, the
// monitor, the probe). This is the wiring: the real providers, the real
// catalog writes, the real return-trip poll.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_directory_watch.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_root_probe.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_library_watch_service.dart';
import 'package:linthra/features/library/local_root_availability_controller.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_folder_picker_service.dart';

const String _nas = '/mnt/nas';
const String _home = '/home/me/Music';

/// Shares that can be mounted and unmounted. Unlike an unplugged udisks
/// drive, an unmounted share's folder doesn't go away: it is still there,
/// readable, and empty.
class _Mounts
    implements AudioFileScanner, DirectoryReadability, DirectoryWatchFactory {
  final Map<String, List<String>> _files = <String, List<String>>{};
  final Set<String> _mounted = <String>{};

  /// How many times each folder was walked.
  final Map<String, int> walks = <String, int>{};

  void mount(String root, {List<String>? files}) {
    _mounted.add(root);
    if (files != null) _files[root] = List<String>.of(files);
  }

  void unmount(String root) => _mounted.remove(root);

  List<String> _visible(String root) => _mounted.contains(root)
      ? List<String>.of(_files[root] ?? const <String>[])
      : const <String>[];

  /// The probe's question, asked of what is visible right now.
  Future<bool> holdsNoFiles(String path) async => _visible(path).isEmpty;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
  }) async {
    walks.update(folder, (int n) => n + 1, ifAbsent: () => 1);
    return _visible(folder);
  }

  @override
  Future<LocalRootFault?> inspect(String path) async => null;

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    if (root.isEmpty) throw const FolderScanException('no such directory');
    return StreamController<LocalDirectoryChange>().stream;
  }
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late _Mounts mounts;
  late InMemoryMusicLibraryRepository catalog;

  setUp(() {
    mounts = _Mounts()
      ..mount(_home, files: <String>['$_home/Idles/Danny Nedelko.mp3'])
      ..mount(_nas, files: <String>[
        '$_nas/Bon Iver/Holocene.flac',
        '$_nas/Bon Iver/Perth.flac',
        '$_nas/Big Thief/Not.flac',
      ]);
    catalog = InMemoryMusicLibraryRepository();
  });

  ProviderContainer container({
    Duration? poll = const Duration(milliseconds: 20),
  }) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: const <String>[_home, _nas],
          ),
        ),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(mounts),
        directoryReadabilityProvider.overrideWithValue(mounts),
        directoryWatchFactoryProvider.overrideWithValue(mounts),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        localRootAvailabilityPollIntervalProvider.overrideWithValue(poll),
        localRootProbeProvider.overrideWith(
          (Ref ref) => PlatformLocalRootProbe(
            readability: mounts,
            safPermissions: ref.watch(safPermissionProbeProvider),
            mediaLibrary: ref.watch(androidMediaLibraryProvider),
            probesFilesystemPaths: true,
            holdsNoFiles: mounts.holdsNoFiles,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> until(String what, FutureOr<bool> Function() condition) async {
    for (int i = 0; i < 200; i++) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('never reached: $what');
  }

  Future<Set<String>> catalogUris() async => <String>{
        for (final Track track in await catalog.getAllTracks()) track.uri,
      };

  Future<void> start(ProviderContainer c) async {
    await c.read(selectedFolderControllerProvider.future);
    c.read(localRootAvailabilityProvider);
    c.read(localLibraryWatchServiceProvider);
    await c
        .read(libraryControllerProvider.notifier)
        .scanFolders(c.read(selectedFolderControllerProvider).value!);
    await pumpEventQueue();
  }

  /// The share is unmounted and something rescans: the watcher on the other
  /// folder firing, say.
  Future<void> unmountAndRescan(ProviderContainer c) async {
    mounts.unmount(_nas);
    await c.read(libraryControllerProvider.notifier).refreshConfiguredFolders();
    await pumpEventQueue();
  }

  test('an unmounted share keeps its music and reads as empty', () async {
    final ProviderContainer c = container();
    await start(c);
    expect(await catalogUris(), hasLength(4));

    await unmountAndRescan(c);

    expect(await catalogUris(), <String>{
      '$_home/Idles/Danny Nedelko.mp3',
      '$_nas/Bon Iver/Holocene.flac',
      '$_nas/Bon Iver/Perth.flac',
      '$_nas/Big Thief/Not.flac',
    });
    expect(
      c.read(localRootAvailabilityProvider).faultFor(_nas),
      LocalRootFault.empty,
    );
    expect(c.read(localRootAvailabilityProvider).isAvailable(_home), isTrue);
  });

  test('while it stays unmounted, the poll asks but never rescans', () async {
    final ProviderContainer c = container();
    await start(c);
    await unmountAndRescan(c);
    final int walksBefore = mounts.walks[_nas]!;

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(mounts.walks[_nas], walksBefore);
    expect(
      c.read(localRootAvailabilityProvider).faultFor(_nas),
      LocalRootFault.empty,
    );
    expect(await catalogUris(), hasLength(4));
  });

  test('mounting it again brings it back with one rescan', () async {
    final ProviderContainer c = container();
    await start(c);
    await unmountAndRescan(c);
    final int walksBefore = mounts.walks[_nas]!;

    mounts.mount(_nas, files: <String>[
      '$_nas/Bon Iver/Holocene.flac',
      '$_nas/Bon Iver/Perth.flac',
      '$_nas/Big Thief/Not.flac',
      '$_nas/Big Thief/Masterpiece.flac',
    ]);
    await until(
      'the share is back',
      () => c.read(localRootAvailabilityProvider).isAvailable(_nas),
    );
    await until(
      'the new song is indexed',
      () async => (await catalogUris()).contains(
        '$_nas/Big Thief/Masterpiece.flac',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(mounts.walks[_nas], walksBefore + 1);
    expect(await catalogUris(), hasLength(5));
  });

  test("It's empty on purpose takes its music out", () async {
    final ProviderContainer c = container();
    await start(c);
    await unmountAndRescan(c);

    await c
        .read(localMusicControllerProvider.notifier)
        .confirmFolderEmpty(_nas);
    await pumpEventQueue();

    expect(await catalogUris(), <String>{'$_home/Idles/Danny Nedelko.mp3'});
    expect(c.read(localRootAvailabilityProvider).isAvailable(_nas), isTrue);

    // Nothing is expected from it any more, so the next rescan is ordinary.
    await c.read(libraryControllerProvider.notifier).refreshConfiguredFolders();
    expect(c.read(localRootAvailabilityProvider).isAvailable(_nas), isTrue);
  });

  test("It's empty on purpose reads a share that was mounted meanwhile",
      () async {
    final ProviderContainer c = container(poll: null);
    await start(c);
    await unmountAndRescan(c);

    mounts.mount(_nas);
    await c
        .read(localMusicControllerProvider.notifier)
        .confirmFolderEmpty(_nas);
    await pumpEventQueue();

    expect(await catalogUris(), hasLength(4));
    expect(c.read(localRootAvailabilityProvider).isAvailable(_nas), isTrue);
  });

  test('Retry on a share still unmounted says so and rescans nothing',
      () async {
    final ProviderContainer c = container(poll: null);
    await start(c);
    await unmountAndRescan(c);
    final int walksBefore = mounts.walks[_nas]!;

    await c.read(localMusicControllerProvider.notifier).retryFolder(_nas);

    expect(mounts.walks[_nas], walksBefore);
    expect(
      c.read(localMusicControllerProvider).message,
      contains('still empty'),
    );
    expect(await catalogUris(), hasLength(4));
  });
}
