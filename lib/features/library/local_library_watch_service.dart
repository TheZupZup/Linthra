import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/sources/local/local_directory_watch.dart';
import '../../core/sources/local/local_library_watcher.dart';
import '../../core/sources/local/local_root_availability.dart';
import '../../data/repositories/host_platform_provider.dart';
import 'library_controller.dart';
import 'local_root_availability_controller.dart';
import 'selected_folder_controller.dart';

/// Keeps the [LocalLibraryWatcher]'s watched folders in step with the user's
/// selection, and points it at the incremental scan.
///
/// A side-effect-only service in the same shape as the media prewarm and
/// precache services: instantiating it wires the listener, and it is disposed
/// with the container. Bootstrap reads it once.
///
/// It deliberately owns no catalog logic. A filesystem change turns into
/// `scanFolders(...)`, the same call the Rescan button makes, so there is one
/// way the local catalog is written and the watcher cannot drift from it.
class LocalLibraryWatchService {
  LocalLibraryWatchService({
    required LocalLibraryWatcher watcher,
    required List<String> Function() selectedRoots,
  })  : _watcher = watcher,
        _selectedRoots = selectedRoots;

  final LocalLibraryWatcher _watcher;
  final List<String> Function() _selectedRoots;

  /// Watches whatever is selected right now. Safe to call repeatedly; the
  /// watcher only opens and closes what actually changed.
  Future<void> syncToSelection() => _watcher.syncRoots(_selectedRoots());

  LocalLibraryWatcher get watcher => _watcher;

  Future<void> dispose() => _watcher.dispose();
}

/// The seam that opens a recursive filesystem watch.
///
/// Android is on [UnsupportedDirectoryWatchFactory] deliberately: its local
/// library is a Storage Access Framework tree or a MediaStore query, not a
/// directory Linthra may walk, so there is no path to watch. Refusing is the
/// honest answer and leaves manual refresh exactly as it is.
final directoryWatchFactoryProvider = Provider<DirectoryWatchFactory>((ref) {
  return ref.watch(hostPlatformProvider).isAndroid
      ? const UnsupportedDirectoryWatchFactory()
      : const IoDirectoryWatchFactory();
});

/// The watcher itself. Session-pinned and disposed with the container, so the
/// watches it holds are released when the app shuts down rather than left to
/// the process exit.
final localLibraryWatcherProvider = Provider<LocalLibraryWatcher>((ref) {
  final LocalLibraryWatcher watcher = LocalLibraryWatcher(
    watchFactory: ref.watch(directoryWatchFactoryProvider),
    // A watch that dies is the first thing that happens when a drive is
    // unmounted, and it names the folder it was watching. Probing that folder
    // right away is what turns an unplug into "this folder is away" while the
    // user is only browsing, with no scan and nothing touched in the catalog.
    // A watch can also fail for reasons that have nothing to do with the drive
    // (an exhausted inotify budget, a filesystem that cannot be watched), which
    // is why this asks rather than concludes: the probe decides.
    onWatchFailed: (String root, Object _) {
      unawaited(
        ref.read(localRootAvailabilityProvider.notifier).recheck(root),
      );
    },
    onLibraryChanged: () async {
      final List<String> roots =
          ref.read(selectedFolderControllerProvider).valueOrNull ??
              const <String>[];
      if (roots.isEmpty) return;
      await ref.read(libraryControllerProvider.notifier).scanFolders(roots);
    },
  );
  ref.onDisposeAsync(watcher.dispose);
  return watcher;
});

/// Starts the watcher and keeps it pointed at the current selection.
///
/// Reading this provider is what turns library watching on; bootstrap does it
/// once. The listener fires immediately, so the folders already selected at
/// startup are watched without waiting for the user to change anything.
final localLibraryWatchServiceProvider =
    Provider<LocalLibraryWatchService>((ref) {
  final LocalLibraryWatchService service = LocalLibraryWatchService(
    watcher: ref.watch(localLibraryWatcherProvider),
    selectedRoots: () =>
        ref.read(selectedFolderControllerProvider).valueOrNull ??
        const <String>[],
  );
  ref.listen<AsyncValue<List<String>>>(
    selectedFolderControllerProvider,
    (_, __) => unawaited(service.syncToSelection()),
    fireImmediately: true,
  );
  // A folder that was away and is back needs its watch again: the old one died
  // with the mount, and nothing else re-opens it. Syncing the whole selection is
  // how that is done, because the watcher only opens what it is not already
  // watching, so the folders that never left are left alone. Only a folder
  // *gaining* availability is worth it; one that just went away has already lost
  // its watch, and retrying it on every probe would ask the kernel to watch a
  // path that is not there.
  ref.listen<LocalLibraryAvailability>(
    localRootAvailabilityProvider,
    (LocalLibraryAvailability? previous, LocalLibraryAvailability next) {
      final Set<String> returned = next.availableRoots
          .difference(previous?.availableRoots ?? const <String>{});
      if (returned.isEmpty) return;
      unawaited(service.syncToSelection());
    },
  );
  return service;
});
