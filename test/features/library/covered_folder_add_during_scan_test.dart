// Adding a folder that is already part of the library, while a scan is
// running, must not leave the Library on "Loading your library".
//
// Every local scan first sets the Library state to loading, and a scan that is
// superseded returns before it publishes anything. That is safe only when
// whatever superseded it publishes a state itself. A covered folder changes
// nothing ("That folder is already part of your library.") and starts no scan,
// so it must not supersede the one running either.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/library_state.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_folder_picker_service.dart';

/// A walk that answers at once until [hold] is called, then waits for
/// [release]. [walking] completes when a held walk has really started.
class _HeldScanner implements AudioFileScanner {
  _HeldScanner(this.files);

  final List<String> files;
  Completer<void>? _gate;
  Completer<void>? _started;

  void hold() {
    _gate = Completer<void>();
    _started = Completer<void>();
  }

  Future<void> get walking => _started!.future;

  void release() => _gate?.complete();

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
  }) async {
    final Completer<void>? started = _started;
    if (started != null && !started.isCompleted) started.complete();
    final Completer<void>? gate = _gate;
    if (gate != null) await gate.future;
    return files;
  }
}

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  test(
      'adding an already-covered folder while a scan runs does not leave the '
      'Library loading forever', () async {
    final _HeldScanner scanner = _HeldScanner(<String>[
      '/music/Artist/Album/01 - One.mp3',
      '/music/Live/02 - Two.mp3',
    ]);
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(InMemoryMusicLibraryRepository()),
        audioFileScannerProvider.overrideWithValue(scanner),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(
            initialFolders: const <String>['/music'],
          ),
        ),
        // The user picks a subfolder of the folder already selected.
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService(folder: '/music/Live')),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(c.dispose);
    await c.read(selectedFolderControllerProvider.future);
    final LibraryController library =
        c.read(libraryControllerProvider.notifier);

    // The library is indexed and on screen.
    await library.scanFolders(const <String>['/music']);
    expect(c.read(libraryControllerProvider).status, LibraryStatus.loaded);
    expect(c.read(libraryControllerProvider).tracks, hasLength(2));

    // A scan starts: the call the folder watcher, the reconnect refresh and the
    // Library screen's Rescan all make.
    scanner.hold();
    final Future<void> running = library.scanFolders(const <String>['/music']);
    await scanner.walking;

    // Meanwhile the user adds a folder that is already part of the library
    // (Settings > Local music, or the Folders screen's Add folder action).
    await c.read(localMusicControllerProvider.notifier).addFolder();
    expect(
      c.read(localMusicControllerProvider).message,
      'That folder is already part of your library.',
    );

    scanner.release();
    await running;
    // Let anything still queued settle.
    await Future<void>.delayed(Duration.zero);

    final LibraryState state = c.read(libraryControllerProvider);
    expect(
      state.status,
      LibraryStatus.loaded,
      reason: 'nothing was changed, so the scan that was running reports as '
          'usual and the library stays on screen',
    );
    expect(state.tracks, hasLength(2));
  });
}
