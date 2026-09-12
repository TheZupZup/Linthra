// Music on a removable drive, wired into the app graph (#415).
//
// One promise, from the user's side: keeping music on a USB disk or an external
// SSD and pointing Linthra at it must not mean losing the configured library
// every time the drive is unplugged. So a folder that disappears becomes
// *temporarily unavailable*: its tracks stay indexed, its folder stays selected,
// the other folders and the servers keep working, and plugging the drive back in
// refreshes it without the user configuring anything again.
//
// The state rules themselves are unit-tested in
// core/sources/local/local_root_availability_monitor_test.dart. This is the
// wiring: the real providers, the real scanner merge, the real catalog writes.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_directory_watch.dart';
import 'package:linthra/core/sources/local/local_root_availability.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/library_state.dart';
import 'package:linthra/features/library/local_library_watch_service.dart';
import 'package:linthra/features/library/local_root_availability_controller.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_folder_picker_service.dart';

const String _usb = '/media/usb/Music';
const String _internal = '/home/me/Music';
const String _remounted = '/run/media/me/MUSIC';

/// One fake filesystem with drives that can be unplugged.
///
/// It stands in for all three seams the local library touches storage through
/// (the scan, the readability probe, and the recursive watch), because a
/// removable drive is a single fact all three have to agree about. Unplugging it
/// here does what unplugging does on a real machine: the path stops resolving,
/// and any watch on it ends.
class _FakeFilesystem
    implements AudioFileScanner, DirectoryReadability, DirectoryWatchFactory {
  final Map<String, List<String>> _files = <String, List<String>>{};
  final Set<String> _connected = <String>{};
  final Map<String, StreamController<LocalDirectoryChange>> _watches =
      <String, StreamController<LocalDirectoryChange>>{};

  /// Folders a watch is open on right now.
  Set<String> get watched => _watches.keys.toSet();

  void connect(String root, {List<String> files = const <String>[]}) {
    _connected.add(root);
    _files[root] = List<String>.of(files);
  }

  /// Adds a file to a connected folder, the way copying an album does.
  void addFile(String root, String path) => _files[root]!.add(path);

  /// The drive is pulled out: the path stops resolving and the watch ends.
  void unplug(String root) {
    _connected.remove(root);
    final StreamController<LocalDirectoryChange>? watch = _watches.remove(root);
    if (watch != null) unawaited(watch.close());
  }

  @override
  Future<List<String>> listFiles(String folder) async {
    if (!_connected.contains(folder)) {
      throw FolderScanException(
        "Linthra couldn't find the selected folder.",
        folder: folder,
      );
    }
    return List<String>.of(_files[folder] ?? const <String>[]);
  }

  @override
  Future<bool> canList(String path) async => _connected.contains(path);

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    if (!_connected.contains(root)) {
      throw const FolderScanException('no such directory');
    }
    final controller = StreamController<LocalDirectoryChange>();
    _watches[root] = controller;
    return controller.stream;
  }
}

Track _serverTrack(String id) => Track(
      id: id,
      uri: 'jellyfin:$id',
      title: 'Server $id',
      artistName: 'Someone',
      albumName: 'Somewhere',
    );

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late _FakeFilesystem fs;
  late InMemoryMusicLibraryRepository catalog;
  late InMemorySelectedMusicFolderRepository selection;

  setUp(() {
    fs = _FakeFilesystem();
    catalog = InMemoryMusicLibraryRepository();
    fs.connect(_usb, files: <String>['$_usb/Bon Iver/Holocene.flac']);
    fs.connect(_internal,
        files: <String>['$_internal/Idles/Danny Nedelko.mp3']);
  });

  /// A container wired like the running app, with the removable-drive poll on so
  /// "the drive comes back" needs no help from the test.
  ProviderContainer container({
    List<String> roots = const <String>[_internal, _usb],
    Duration? poll = const Duration(milliseconds: 20),
  }) {
    selection = InMemorySelectedMusicFolderRepository(initialFolders: roots);
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(selection),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(fs),
        directoryReadabilityProvider.overrideWithValue(fs),
        directoryWatchFactoryProvider.overrideWithValue(fs),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        localRootAvailabilityPollIntervalProvider.overrideWithValue(poll),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Waits for [condition], so a test asserts on the outcome rather than on a
  /// guess at how long a probe plus a scan takes.
  Future<void> until(
    String what,
    FutureOr<bool> Function() condition,
  ) async {
    for (int i = 0; i < 200; i++) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('never reached: $what');
  }

  Future<Set<String>> catalogUris() async => <String>{
        for (final Track track in await catalog.getAllTracks()) track.uri,
      };

  LocalLibraryAvailability availabilityOf(ProviderContainer c) =>
      c.read(localRootAvailabilityProvider);

  /// Brings a container up the way startup does, and scans once.
  Future<void> start(ProviderContainer c, {bool scan = true}) async {
    await c.read(selectedFolderControllerProvider.future);
    c.read(localRootAvailabilityProvider);
    c.read(localLibraryWatchServiceProvider);
    if (scan) {
      await c
          .read(libraryControllerProvider.notifier)
          .scanFolders(c.read(selectedFolderControllerProvider).value!);
    } else {
      // What startup does on its own: load the catalog that is already there.
      // Nothing scans until something asks.
      await c.read(libraryControllerProvider.notifier).refresh();
    }
    await pumpEventQueue();
  }

  test('a folder on a removable drive indexes like any other', () async {
    final ProviderContainer c = container();

    await start(c);

    expect(await catalogUris(), <String>{
      '$_internal/Idles/Danny Nedelko.mp3',
      '$_usb/Bon Iver/Holocene.flac',
    });
    await until('both folders read as available', () {
      final LocalLibraryAvailability availability = availabilityOf(c);
      return availability.isAvailable(_usb) &&
          availability.isAvailable(_internal);
    });
  });

  group('while the drive is unplugged', () {
    test('its music stays indexed and the library still shows it', () async {
      final ProviderContainer c = container();
      await start(c);

      fs.unplug(_usb);
      fs.addFile(_internal, '$_internal/Idles/Mother.mp3');
      await c.read(libraryControllerProvider.notifier).scanFolders(
        <String>[_internal, _usb],
      );

      expect(
        await catalogUris(),
        <String>{
          '$_internal/Idles/Danny Nedelko.mp3',
          '$_internal/Idles/Mother.mp3',
          '$_usb/Bon Iver/Holocene.flac',
        },
        reason:
            'the folder that could be read is refreshed; the one that could '
            'not keeps exactly what it had',
      );
      // The screen keeps showing the library. An error page over an intact
      // catalog is the screen's way of saying "your music is gone", which is the
      // one thing an unplugged drive must never mean.
      final LibraryState state = c.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.tracks, hasLength(3));
    });

    test('the configured folder is kept, and no other path stands in for it',
        () async {
      final ProviderContainer c = container();
      await start(c);

      fs.unplug(_usb);
      await c.read(libraryControllerProvider.notifier).scanFolders(
        <String>[_internal, _usb],
      );

      expect(await selection.getSelectedFolders(), <String>[_internal, _usb]);
      expect(availabilityOf(c).isUnavailable(_usb), isTrue);
      expect(availabilityOf(c).stateFor(_usb)?.root, _usb);
    });

    test('a server source keeps every track', () async {
      // The unified library spans sources. A local drive going away may not cost
      // a Jellyfin or Navidrome library a single row, or a single row on screen.
      await catalog.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: <Track>[_serverTrack('1'), _serverTrack('2')],
        albums: const [],
        artists: const [],
      );
      final ProviderContainer c = container();
      await start(c);

      fs.unplug(_usb);
      await c.read(libraryControllerProvider.notifier).scanFolders(
        <String>[_internal, _usb],
      );

      expect(
          await catalogUris(),
          containsAll(<String>[
            'jellyfin:1',
            'jellyfin:2',
          ]));
      expect(c.read(libraryControllerProvider).status, LibraryStatus.loaded);
    });

    test('with every folder away, nothing is written at all', () async {
      final ProviderContainer c = container();
      await start(c);
      final Set<String> before = await catalogUris();

      fs.unplug(_usb);
      fs.unplug(_internal);
      await c.read(libraryControllerProvider.notifier).scanFolders(
        <String>[_internal, _usb],
      );

      expect(await catalogUris(), before);
      expect(c.read(libraryControllerProvider).tracks, hasLength(2));
    });

    test('a watch that ends with the mount marks that folder away', () async {
      // Nothing is scanning and nobody pressed anything: the user is just
      // browsing when the drive goes. The dying watch is the signal, and the
      // answer is one enum: no scan, and nothing touched in the catalog.
      final ProviderContainer c = container();
      await start(c);
      await until('both folders are watched', () async {
        return c.read(localLibraryWatcherProvider).watchedRoots.length == 2;
      });
      final Set<String> before = await catalogUris();

      fs.unplug(_usb);

      await until('the unplugged folder reads as away', () {
        return availabilityOf(c).isUnavailable(_usb);
      });
      expect(availabilityOf(c).isAvailable(_internal), isTrue);
      expect(await catalogUris(), before);
      expect(await selection.getSelectedFolders(), <String>[_internal, _usb]);
    });
  });

  group('when the drive comes back', () {
    test('at the same path, it refreshes with no reconfiguration', () async {
      final ProviderContainer c = container();
      await start(c);
      fs.unplug(_usb);
      await c.read(libraryControllerProvider.notifier).scanFolders(
        <String>[_internal, _usb],
      );
      await until('the folder reads as away', () {
        return availabilityOf(c).isUnavailable(_usb);
      });

      // The drive is plugged back in, with an album added on another machine
      // while it was gone. Nothing else happens: no Rescan, no re-selecting.
      fs.connect(_usb, files: <String>[
        '$_usb/Bon Iver/Holocene.flac',
        '$_usb/Bon Iver/Perth.flac',
      ]);

      await until('the returning folder is re-read', () async {
        return (await catalogUris()).contains('$_usb/Bon Iver/Perth.flac');
      });
      expect(await catalogUris(), <String>{
        '$_internal/Idles/Danny Nedelko.mp3',
        '$_usb/Bon Iver/Holocene.flac',
        '$_usb/Bon Iver/Perth.flac',
      });
      expect(availabilityOf(c).isAvailable(_usb), isTrue);
      expect(await selection.getSelectedFolders(), <String>[_internal, _usb]);
    });

    test('it is watched again, so the library stays live', () async {
      final ProviderContainer c = container();
      await start(c);
      await until('both folders are watched', () async {
        return c.read(localLibraryWatcherProvider).watchedRoots.length == 2;
      });

      fs.unplug(_usb);
      await until('the watch is released', () {
        return !c.read(localLibraryWatcherProvider).watchedRoots.contains(_usb);
      });

      fs.connect(_usb, files: <String>['$_usb/Bon Iver/Holocene.flac']);

      await until('the folder is watched again', () {
        return c.read(localLibraryWatcherProvider).watchedRoots.contains(_usb);
      });
      expect(fs.watched, contains(_usb));
    });

    test('at a different path, it is not adopted', () async {
      // The honest limitation. A drive can come back mounted somewhere else, and
      // Linthra cannot prove the folder now at that path is the same disk;
      // adopting it would point a configured library at whatever is there. So the
      // configured folder is kept, stays unavailable, and the user decides
      // (reselect, or remove). Nothing is guessed, and nothing is deleted.
      final ProviderContainer c = container();
      await start(c);
      final Set<String> indexed = await catalogUris();

      fs.unplug(_usb);
      await until('the folder reads as away', () {
        return availabilityOf(c).isUnavailable(_usb);
      });
      fs.connect(_remounted, files: <String>[
        '$_remounted/Bon Iver/Holocene.flac',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(availabilityOf(c).isUnavailable(_usb), isTrue);
      expect(availabilityOf(c).stateFor(_remounted), isNull);
      expect(await selection.getSelectedFolders(), <String>[_internal, _usb]);
      expect(
        await catalogUris(),
        indexed,
        reason: 'no track is silently re-pointed at a different path',
      );
    });
  });

  test('starting up with the drive absent keeps the library', () async {
    // The catalog from a previous session, with the drive left at home.
    final ProviderContainer first = container();
    await start(first);
    final Set<String> indexed = await catalogUris();
    first.dispose();
    fs.unplug(_usb);

    final ProviderContainer c = container();
    await start(c, scan: false);

    expect(await catalogUris(), indexed);
    expect(c.read(libraryControllerProvider).tracks, hasLength(2));
    await until('the absent folder reads as away', () {
      return availabilityOf(c).isUnavailable(_usb);
    });
    expect(availabilityOf(c).isAvailable(_internal), isTrue);
    expect(await selection.getSelectedFolders(), <String>[_internal, _usb]);
  });

  test('removing the folder removes only its music', () async {
    // The other half of the contract: an explicit removal is a decision, and it
    // is the only thing that drops a folder's tracks. It drops nothing else.
    await catalog.upsertCatalog(
      sourceId: 'jellyfin',
      tracks: <Track>[_serverTrack('1')],
      albums: const [],
      artists: const [],
    );
    final ProviderContainer c = container();
    await start(c);

    await c.read(localMusicControllerProvider.notifier).removeFolder(_usb);

    expect(await catalogUris(), <String>{
      '$_internal/Idles/Danny Nedelko.mp3',
      'jellyfin:1',
    });
    expect(await selection.getSelectedFolders(), <String>[_internal]);
    await until('the removed folder is no longer tracked', () {
      return availabilityOf(c).stateFor(_usb) == null;
    });
    expect(availabilityOf(c).isAvailable(_internal), isTrue);
  });

  test('removing a folder that is currently away still works', () async {
    // Removing an unplugged folder is a normal thing to want, and it must not
    // need the drive back: the tracks to drop are in the catalog, not on the
    // disk.
    final ProviderContainer c = container();
    await start(c);
    fs.unplug(_usb);
    await until('the folder reads as away', () {
      return availabilityOf(c).isUnavailable(_usb);
    });

    await c.read(localMusicControllerProvider.notifier).removeFolder(_usb);

    expect(await catalogUris(), <String>{
      '$_internal/Idles/Danny Nedelko.mp3',
    });
    expect(await selection.getSelectedFolders(), <String>[_internal]);
  });
}
