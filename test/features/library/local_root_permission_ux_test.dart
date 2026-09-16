// A configured music folder that becomes unreadable, wired into the app graph
// (#414).
//
// The promise, from the user's side: a folder Linthra cannot read says *which*
// problem it has and offers the way out, instead of leaving a library that
// quietly looks empty. Three problems, three fixes, and none of them costs
// anything: the indexed music stays, the other folders stay, the server sources
// stay, and no file on disk is ever touched.
//
// The classification rules are unit-tested in
// core/sources/local/local_root_fault_test.dart and the words in
// local_root_problem_test.dart. This is the wiring: the real providers, the real
// scanner merge, the real catalog writes, and the real Retry / Reselect / Remove
// actions the card calls.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/folder_picker_service.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/library_state.dart';
import 'package:linthra/features/library/local_root_availability_controller.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

const String _usb = '/media/usb/Music';
const String _internal = '/home/me/Music';
const String _elsewhere = '/home/me/Archive';

const String _usbTrack = '$_usb/Bon Iver/Holocene.flac';
const String _internalTrack = '$_internal/Idles/Danny Nedelko.mp3';
const String _elsewhereTrack = '$_elsewhere/Portico/Memory Of Newness.mp3';

/// One fake filesystem whose folders can fail the three ways a real one does.
///
/// It stands in for both seams the local library reads storage through (the scan
/// and the readability probe), because how a folder fails is a single fact both
/// have to agree about, exactly as on a real machine, where the walk and the
/// probe see the same errno.
///
/// It has no way to delete or write anything, which is the point: the seams the
/// app reaches storage through are read-only, so [files] cannot change no matter
/// what the UI does. Tests assert on that.
class _FakeFilesystem implements AudioFileScanner, DirectoryReadability {
  final Map<String, List<String>> files = <String, List<String>>{};
  final Map<String, LocalRootFault?> _faults = <String, LocalRootFault?>{};

  /// Every folder a scan was asked to walk, so a test can prove that a broken
  /// folder cost the *other* folders nothing.
  final List<String> walked = <String>[];

  void connect(String root, {List<String> contents = const <String>[]}) {
    files[root] = List<String>.of(contents);
    _faults[root] = null;
  }

  /// The folder stops being readable, for [fault]. The files are still listed
  /// here: a drive that is unplugged has not lost anything, which is what makes
  /// the recovery a reconnect rather than a restore.
  void breakRoot(String root, LocalRootFault fault) => _faults[root] = fault;

  /// The folder answers again, exactly as it was.
  void restore(String root) => _faults[root] = null;

  /// Copying an album onto a drive.
  void addFile(String root, String path) => files[root]!.add(path);

  /// A snapshot a test can compare against later, to prove nothing on disk
  /// moved.
  Map<String, List<String>> snapshot() => <String, List<String>>{
        for (final MapEntry<String, List<String>> entry in files.entries)
          entry.key: List<String>.of(entry.value),
      };

  @override
  Future<List<String>> listFiles(String folder) async {
    walked.add(folder);
    final LocalRootFault? fault = _faults[folder];
    if (fault != null) {
      // The production wording and code for this fault, so the test exercises
      // the same mapping the real scanner uses rather than a parallel one.
      throw rootFaultException(folder, fault);
    }
    return List<String>.of(files[folder] ?? const <String>[]);
  }

  @override
  Future<LocalRootFault?> inspect(String path) async =>
      files.containsKey(path) ? _faults[path] : LocalRootFault.missing;
}

/// A picker whose answer a test can change between calls, so "the user chose a
/// different folder" and "the user cancelled" are both reachable.
class _StagedPicker implements FolderPickerService {
  String? folder;
  int pickCount = 0;

  @override
  Future<String?> pickFolder() async {
    pickCount++;
    return folder;
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
  late _StagedPicker picker;

  setUp(() {
    fs = _FakeFilesystem();
    catalog = InMemoryMusicLibraryRepository();
    picker = _StagedPicker();
    fs.connect(_usb, contents: <String>[_usbTrack]);
    fs.connect(_internal, contents: <String>[_internalTrack]);
    fs.connect(_elsewhere, contents: <String>[_elsewhereTrack]);
  });

  /// A container wired like the running desktop app. Polling is off: every test
  /// here drives recovery through the Retry button, which is the thing under
  /// test.
  ProviderContainer container({
    List<String> roots = const <String>[_internal, _usb],
  }) {
    selection = InMemorySelectedMusicFolderRepository(initialFolders: roots);
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider.overrideWithValue(picker),
        selectedMusicFolderRepositoryProvider.overrideWithValue(selection),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
        audioFileScannerProvider.overrideWithValue(fs),
        directoryReadabilityProvider.overrideWithValue(fs),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<Set<String>> catalogUris() async => <String>{
        for (final Track track in await catalog.getAllTracks()) track.uri,
      };

  /// Brings a container up the way startup does, and scans once.
  Future<void> start(ProviderContainer c) async {
    await c.read(selectedFolderControllerProvider.future);
    c.read(localRootAvailabilityProvider);
    await c
        .read(libraryControllerProvider.notifier)
        .scanFolders(c.read(selectedFolderControllerProvider).value!);
    await pumpEventQueue();
  }

  /// A rescan, the way the card's Rescan button runs one.
  Future<void> rescan(ProviderContainer c) async {
    await c.read(localMusicControllerProvider.notifier).rescan();
    await pumpEventQueue();
  }

  LocalRootFault? faultFor(ProviderContainer c, String root) =>
      c.read(localRootAvailabilityProvider).faultFor(root);

  group('a folder that stops being readable', () {
    test('a missing folder is reported as missing, not as an empty library',
        () async {
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);

      expect(faultFor(c, _usb), LocalRootFault.missing);
      // Its music is still there, and so is the folder's place in the
      // selection. Nothing about this looks like an empty library.
      expect(await catalogUris(), contains(_usbTrack));
      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _usb,
      ]);
      expect(c.read(libraryControllerProvider).status, LibraryStatus.loaded);
    });

    test('a folder this process may not read is a permission problem',
        () async {
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.permissionDenied);
      await rescan(c);

      expect(faultFor(c, _usb), LocalRootFault.permissionDenied);
      expect(await catalogUris(), contains(_usbTrack));
    });

    test('storage that stopped answering is its own, temporary state',
        () async {
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.unavailable);
      await rescan(c);

      expect(faultFor(c, _usb), LocalRootFault.unavailable);
      expect(await catalogUris(), contains(_usbTrack));
    });

    test('a transient failure writes nothing away', () async {
      // The rule the whole feature rests on: the catalog after a folder goes
      // away is byte-for-byte the catalog before it, for every folder.
      final ProviderContainer c = container();
      await start(c);
      final Set<String> before = await catalogUris();

      for (final LocalRootFault fault in LocalRootFault.values) {
        fs.breakRoot(_usb, fault);
        await rescan(c);

        expect(
          await catalogUris(),
          before,
          reason: '$fault must not cost the library a track',
        );
      }
    });

    test('the other folders keep working', () async {
      final ProviderContainer c = container(
        roots: <String>[_internal, _usb, _elsewhere],
      );
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.permissionDenied);
      fs.addFile(_internal, '$_internal/Idles/Mother.mp3');
      await rescan(c);

      // Only the broken one is flagged…
      expect(
        c.read(localRootAvailabilityProvider).faults.keys,
        <String>[_usb],
      );
      expect(faultFor(c, _internal), isNull);
      expect(faultFor(c, _elsewhere), isNull);
      // …and the others were really scanned, not merely left alone.
      expect(await catalogUris(), contains('$_internal/Idles/Mother.mp3'));
      expect(await catalogUris(), contains(_elsewhereTrack));
    });

    test('a server source is untouched by any of it', () async {
      await catalog.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: <Track>[_serverTrack('1')],
        albums: const [],
        artists: const [],
      );
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.unavailable);
      fs.breakRoot(_internal, LocalRootFault.missing);
      await rescan(c);

      expect(await catalogUris(), contains('jellyfin:1'));
    });

    test('the diagnostics line records the kind, and still no path', () async {
      // Useful internally, safe to attach to a bug report: a failure *kind*,
      // never a folder name or an OS message.
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.permissionDenied);
      await rescan(c);

      final LocalScanReport report = c.read(localScanReportProvider)!;
      final String line = LocalScanDiagnostics.describe(report);

      expect(report.fault, LocalRootFault.permissionDenied);
      expect(line, contains('fault=permissionDenied'));
      expect(line, isNot(contains(_usb)));
      expect(line, isNot(contains('Holocene')));
    });
  });

  group('Retry', () {
    test('after the folder comes back, it refreshes without reconfiguring',
        () async {
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);
      expect(faultFor(c, _usb), LocalRootFault.missing);

      // The drive goes back in, with an album added while it was away.
      fs.restore(_usb);
      fs.addFile(_usb, '$_usb/Bon Iver/Perth.flac');
      await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
      await pumpEventQueue();

      expect(faultFor(c, _usb), isNull);
      expect(await catalogUris(), contains('$_usb/Bon Iver/Perth.flac'));
      expect(c.read(localMusicControllerProvider).isError, isFalse);
      // Nothing was reconfigured to get here.
      expect(picker.pickCount, 0);
      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _usb,
      ]);
    });

    test('while it is still away, it says so and changes nothing', () async {
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.permissionDenied);
      await rescan(c);
      final Set<String> before = await catalogUris();

      await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
      await pumpEventQueue();

      final LocalMusicActionState action = c.read(localMusicControllerProvider);
      expect(action.isError, isTrue);
      expect(action.message, contains("isn't allowed to read"));
      expect(faultFor(c, _usb), LocalRootFault.permissionDenied);
      expect(await catalogUris(), before);
      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _usb,
      ]);
    });

    test('a folder that came back is walked once, not twice', () async {
      // Coming back is what the return trip exists to notice, and noticing it
      // already runs the incremental scan. A Retry that ran its own on top
      // would read every configured folder a second time, which on a large
      // library is the difference between Retry feeling instant and feeling
      // broken.
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);

      fs.restore(_usb);
      fs.walked.clear();
      await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
      await pumpEventQueue();

      expect(faultFor(c, _usb), isNull);
      expect(fs.walked, <String>[_internal, _usb]);
    });

    test('its message matches the problem', () async {
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);
      await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
      expect(
        c.read(localMusicControllerProvider).message,
        contains("still isn't there"),
      );

      fs.breakRoot(_usb, LocalRootFault.unavailable);
      await rescan(c);
      await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
      expect(
        c.read(localMusicControllerProvider).message,
        contains('still is not responding'),
      );
    });
  });

  group('Reselect', () {
    test('it replaces only the folder it was asked about', () async {
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);

      picker.folder = _elsewhere;
      await c.read(localMusicControllerProvider.notifier).reselectFolder(_usb);
      await pumpEventQueue();

      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _elsewhere,
      ]);
      // The new folder's music is in, the replaced folder's is out, and the
      // folder nobody touched is exactly as it was.
      final Set<String> uris = await catalogUris();
      expect(uris, contains(_elsewhereTrack));
      expect(uris, contains(_internalTrack));
      expect(uris, isNot(contains(_usbTrack)));
    });

    test('a replacement that cannot be read is not adopted', () async {
      // The replacement is scanned before it is saved, the same way switching
      // to device-wide music is. A scan that could read nothing writes nothing,
      // so saving the new folder anyway would leave the library holding the old
      // folder's tracks while naming a folder that never contributed any:
      // music the app can no longer place, and no way back to where it came
      // from.
      final ProviderContainer c = container();
      await start(c);
      final Set<String> indexed = await catalogUris();

      // Everything is away, so nothing the scan finds can be written.
      fs.breakRoot(_usb, LocalRootFault.missing);
      fs.breakRoot(_internal, LocalRootFault.missing);
      await rescan(c);

      fs.breakRoot(_elsewhere, LocalRootFault.permissionDenied);
      picker.folder = _elsewhere;
      await c.read(localMusicControllerProvider.notifier).reselectFolder(_usb);
      await pumpEventQueue();

      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _usb,
      ]);
      expect(await catalogUris(), indexed);
      expect(c.read(localMusicControllerProvider).isError, isTrue);
    });

    test(
        'a scan of a source that is not configured is not the library\'s '
        'failure', () async {
      // Trying a source out before committing it (device-wide music, a
      // replacement being checked) runs a scan over folders that are not the
      // selection. Its failure is not the configured library's, and marking it
      // as one would offer the configured folders' recovery for something else
      // entirely.
      final ProviderContainer c = container();
      await start(c);

      fs.breakRoot(_elsewhere, LocalRootFault.missing);
      await c
          .read(libraryControllerProvider.notifier)
          .scanFoldersWithReport(<String>[_elsewhere]);
      await pumpEventQueue();

      expect(c.read(libraryControllerProvider).localRootsUnreadable, isFalse);

      // The same failure on the folders the user actually configured is.
      fs.breakRoot(_usb, LocalRootFault.missing);
      fs.breakRoot(_internal, LocalRootFault.missing);
      await catalog.upsertCatalog(
        sourceId: 'local',
        tracks: const <Track>[],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await rescan(c);

      expect(c.read(libraryControllerProvider).localRootsUnreadable, isTrue);
    });

    test('nothing stands in for the configured folder on its own', () async {
      // The folder came back at a different mount point. Linthra cannot prove
      // it is the same hardware, so it stays unavailable until the user says
      // otherwise. This is the case that would point a library at somebody
      // else's files if it were guessed.
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);

      fs.connect('/run/media/me/MUSIC', contents: <String>[
        '/run/media/me/MUSIC/Bon Iver/Holocene.flac',
      ]);
      await rescan(c);

      expect(faultFor(c, _usb), LocalRootFault.missing);
      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _usb,
      ]);
      expect(picker.pickCount, 0);
    });

    test('cancelling the chooser changes nothing at all', () async {
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);
      final Set<String> before = await catalogUris();

      picker.folder = null;
      await c.read(localMusicControllerProvider.notifier).reselectFolder(_usb);
      await pumpEventQueue();

      expect(picker.pickCount, 1);
      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _usb,
      ]);
      expect(await catalogUris(), before);
    });
  });

  group('Remove', () {
    test('it takes out that folder and nothing else', () async {
      final ProviderContainer c = container(
        roots: <String>[_internal, _usb, _elsewhere],
      );
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.permissionDenied);
      await rescan(c);

      await c.read(localMusicControllerProvider.notifier).removeFolder(_usb);
      await pumpEventQueue();

      expect(c.read(selectedFolderControllerProvider).value, <String>[
        _internal,
        _elsewhere,
      ]);
      final Set<String> uris = await catalogUris();
      expect(uris, isNot(contains(_usbTrack)));
      expect(uris, contains(_internalTrack));
      expect(uris, contains(_elsewhereTrack));
      // The folder stops being tracked at all, rather than lingering as a
      // problem the user already dealt with.
      expect(c.read(localRootAvailabilityProvider).faults, isEmpty);
    });

    test('it says plainly that no files were deleted', () async {
      final ProviderContainer c = container();
      await start(c);
      fs.breakRoot(_usb, LocalRootFault.missing);
      await rescan(c);

      await c.read(localMusicControllerProvider.notifier).removeFolder(_usb);
      await pumpEventQueue();

      expect(
        c.read(localMusicControllerProvider).message,
        contains('Your files were not deleted'),
      );
    });
  });

  test('nothing in the whole flow touches a file on disk', () async {
    // Breaking a folder, retrying it, pointing it somewhere else and removing
    // it: every action the recovery UI offers, against one filesystem that is
    // compared with itself at the end. The storage seams are read-only by
    // construction, and this is the test that keeps them that way.
    final ProviderContainer c = container();
    await start(c);
    final Map<String, List<String>> before = fs.snapshot();

    fs.breakRoot(_usb, LocalRootFault.permissionDenied);
    await rescan(c);
    await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
    fs.restore(_usb);
    await c.read(localMusicControllerProvider.notifier).retryFolder(_usb);
    picker.folder = _elsewhere;
    await c.read(localMusicControllerProvider.notifier).reselectFolder(_usb);
    await c
        .read(localMusicControllerProvider.notifier)
        .removeFolder(_elsewhere);
    await pumpEventQueue();

    expect(fs.snapshot(), before);
  });

  test('a folder that is away is never scanned in place of another', () async {
    // The independence rule, from the scan side: a broken folder is attempted
    // and fails on its own, and the walk of the others is unaffected.
    final ProviderContainer c = container();
    await start(c);
    fs.breakRoot(_usb, LocalRootFault.unavailable);
    fs.walked.clear();

    await rescan(c);

    expect(fs.walked, <String>[_internal, _usb]);
  });

  test('a library whose only folder is away is explained, not blanked',
      () async {
    // The case the issue is named for: nothing indexed yet, the folder cannot
    // be read, and the screen has to say why rather than showing an empty
    // library with no explanation.
    final ProviderContainer c = container(roots: <String>[_usb]);
    fs.breakRoot(_usb, LocalRootFault.permissionDenied);

    await start(c);

    expect(faultFor(c, _usb), LocalRootFault.permissionDenied);
    final LibraryState state = c.read(libraryControllerProvider);
    expect(state.status, LibraryStatus.error);
    expect(state.errorMessage, contains("isn't allowed to read"));
    // Recoverable, and the folder is still configured.
    expect(c.read(selectedFolderControllerProvider).value, <String>[_usb]);
  });
}
