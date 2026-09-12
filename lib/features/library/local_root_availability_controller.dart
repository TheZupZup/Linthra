import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/app_visibility.dart';
import '../../core/sources/local/local_root_availability.dart';
import '../../core/sources/local/local_root_availability_monitor.dart';
import '../../core/sources/local/local_root_probe.dart';
import '../../data/repositories/host_platform_provider.dart';
import 'library_controller.dart';
import 'library_providers.dart';
import 'selected_folder_controller.dart';

/// The seam that answers whether one configured local root is reachable now.
///
/// Composed from the probes that already exist per kind of selection, so there
/// is one set of rules for "can Linthra read this folder?" rather than one for
/// the Settings card and another for availability tracking.
final localRootProbeProvider = Provider<LocalRootProbe>((ref) {
  return PlatformLocalRootProbe(
    readability: ref.watch(directoryReadabilityProvider),
    safPermissions: ref.watch(safPermissionProbeProvider),
    mediaLibrary: ref.watch(androidMediaLibraryProvider),
    // A raw filesystem path is only a question worth asking where Linthra reads
    // paths. On Android the local library is a SAF tree or MediaStore, and a
    // path left over from an old selection could not be read either way.
    probesFilesystemPaths: ref.watch(hostPlatformProvider).isDesktop,
  );
});

/// How often an **unavailable** local root is re-probed, or null for no polling.
///
/// Defaults to no polling, so a bare container (every widget and unit test)
/// never carries a live timer. The running app applies
/// [localRootAvailabilityPollOverride], the same pattern the other
/// production-only bindings use.
final localRootAvailabilityPollIntervalProvider =
    Provider<Duration?>((ref) => null);

/// Production binding: re-ask an absent folder every few seconds *while the app
/// is on screen*.
///
/// Plugging a drive back in produces no event an app can subscribe to, so asking
/// again is the only way to notice. It is deliberately cheap and deliberately
/// narrow: one `stat`-shaped probe per **absent** folder, and nothing at all
/// while every configured folder is present, so a library that is all there
/// carries no timer, and a drive that spun down is never woken by a schedule.
///
/// Short enough that plugging the drive in feels like it just works, rather than
/// leaving the user to guess whether Rescan is needed.
final localRootAvailabilityPollOverride =
    localRootAvailabilityPollIntervalProvider.overrideWithValue(
  const Duration(seconds: 5),
);

/// Tracks which configured local folders are reachable, and refreshes the ones
/// that come back.
///
/// The selection controller answers "which folders did the user choose?" and
/// must keep saying the same thing while a drive is unplugged: that selection,
/// and the tracks it already contributed, are exactly what the user wants back
/// when they plug it in again. This answers the *other* question, "did that path
/// answer just now?".
///
/// Its only side effect is asking for the ordinary incremental scan when a
/// folder returns, which is how the library catches up on whatever changed while
/// the drive was away. Nothing here deletes anything: a folder that stops
/// answering changes one enum, and a folder is only ever removed by the user
/// removing it.
class LocalRootAvailabilityController
    extends Notifier<LocalLibraryAvailability> {
  LocalRootAvailabilityMonitor? _monitor;
  bool _disposed = false;

  @override
  LocalLibraryAvailability build() {
    _disposed = false;
    final LocalRootAvailabilityMonitor monitor = LocalRootAvailabilityMonitor(
      probe: ref.read(localRootProbeProvider),
      pollInterval: ref.read(localRootAvailabilityPollIntervalProvider),
      onChanged: _publish,
      onRootsReturned: _refreshAfterReconnect,
    );
    _monitor = monitor;
    ref.onDispose(() {
      _disposed = true;
      unawaited(monitor.dispose());
    });

    // Listened to rather than watched: this notifier must not be rebuilt when
    // the user adds or removes a folder, because rebuilding would forget that
    // one of the *other* folders is away, and the next probe would then read as
    // a reconnect and rescan for nothing.
    ref.listen<AsyncValue<List<String>>>(
      selectedFolderControllerProvider,
      (_, AsyncValue<List<String>> next) {
        unawaited(monitor.syncRoots(next.valueOrNull ?? const <String>[]));
      },
    );
    // A minimized or backgrounded app stands the return-trip poll down; coming
    // back re-probes at once, so a drive plugged in while the window was away is
    // picked up on the next frame rather than on the next tick.
    ref.listen<bool>(appVisibilityProvider, (_, bool visible) {
      monitor.setPollingEnabled(visible);
      if (visible) unawaited(monitor.refresh());
    });
    monitor.setPollingEnabled(ref.read(appVisibilityProvider));

    // Off the build, so the notifier never writes state while building.
    final List<String> roots =
        ref.read(selectedFolderControllerProvider).valueOrNull ??
            const <String>[];
    scheduleMicrotask(() {
      if (!_disposed) unawaited(monitor.syncRoots(roots));
    });
    return monitor.availability;
  }

  /// Re-probes every configured folder now. Safe to call at any rate: it cannot
  /// throw and cannot write anything but this enum map.
  Future<void> refresh() => _monitor?.refresh() ?? Future<void>.value();

  /// Re-probes one folder now, because something just failed on it. The
  /// filesystem watch on an unmounted drive dying is the case this exists for.
  Future<void> recheck(String root) =>
      _monitor?.recheck(root) ?? Future<void>.value();

  /// Adopts what a scan just learned about the folders it walked, so a scan that
  /// found a drive missing is reflected without waiting for a probe.
  void noteScanOutcome({
    required Iterable<String> readRoots,
    required Iterable<String> unreadableRoots,
  }) {
    _monitor?.noteScanOutcome(
      readRoots: readRoots,
      unreadableRoots: unreadableRoots,
    );
  }

  void _publish(LocalLibraryAvailability availability) {
    if (_disposed) return;
    state = availability;
  }

  /// A folder came back. Run the ordinary incremental scan over the current
  /// selection (the same entry point Rescan uses), so the returning folder is
  /// re-read and whatever changed while it was away lands in the catalog.
  ///
  /// The scan is incremental, so the folders that never left cost a walk and a
  /// stat rather than a re-parse, and it is the *only* way the local catalog is
  /// written, so a reconnect cannot drift from a manual rescan.
  Future<void> _refreshAfterReconnect(List<String> returned) async {
    if (_disposed || returned.isEmpty) return;
    final List<String> roots =
        ref.read(selectedFolderControllerProvider).valueOrNull ??
            const <String>[];
    if (roots.isEmpty) return;
    await ref.read(libraryControllerProvider.notifier).scanFolders(roots);
  }
}

/// The live availability of the configured local folders.
///
/// Read by the Settings ▸ Local music card (to flag the folder whose drive is
/// out rather than declaring the library broken), and by the watch service (so a
/// folder that returns gets its filesystem watch back).
final localRootAvailabilityProvider =
    NotifierProvider<LocalRootAvailabilityController, LocalLibraryAvailability>(
  LocalRootAvailabilityController.new,
);
