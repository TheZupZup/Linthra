import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/local/android_media_library.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_music_roots.dart';
import '../../../core/sources/local/local_root_fault.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../library/library_controller.dart';
import '../../library/library_providers.dart';
import '../../library/local_root_availability_controller.dart';
import '../../library/selected_folder_controller.dart';

/// Transient state for the Settings ▸ Local music card.
class LocalMusicActionState {
  const LocalMusicActionState({
    this.busy = false,
    this.message,
    this.isError = false,
  });

  final bool busy;
  final String? message;
  final bool isError;
}

/// Drives the Settings ▸ Local music source card.
///
/// Desktop treats local music as a set of folders: they are added and removed
/// one at a time and scanned together as a single library.
///
/// Android exposes two deliberate choices instead, and exactly one at a time:
///  - a targeted SAF folder grant; or
///  - device-wide MediaStore access, backed by READ_MEDIA_AUDIO on Android 13+
///    and the legacy shared-storage read permission on older Android releases.
/// The second path is only requested when the user explicitly chooses it.
class LocalMusicController extends Notifier<LocalMusicActionState> {
  @override
  LocalMusicActionState build() => const LocalMusicActionState();

  /// Picks a folder and makes it the only local source. This is the Android
  /// path (one SAF grant at a time) and the first-run/empty-library prompt.
  Future<void> pickFolder() async {
    state = const LocalMusicActionState(busy: true);
    final String? picked = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (picked == null || picked.isEmpty) {
      state = const LocalMusicActionState();
      return;
    }
    await _scan(<String>[picked]);
  }

  /// Picks another folder and adds it to the library, keeping the folders
  /// already selected. Desktop only: Android's local access is a single grant.
  Future<void> addFolder() async {
    if (ref.read(hostPlatformProvider).isAndroid) {
      await pickFolder();
      return;
    }
    final List<String> before = _selectedFolders();
    state = const LocalMusicActionState(busy: true);
    final String? picked =
        await ref.read(selectedFolderControllerProvider.notifier).pickAndAdd();
    if (picked == null || picked.isEmpty) {
      state = const LocalMusicActionState();
      return;
    }
    if (LocalMusicRoots.isCoveredBy(picked, before)) {
      // Adding a folder already covered by another one would scan the same
      // files twice, so the selection was left alone. Say so, rather than
      // looking like nothing happened.
      state = const LocalMusicActionState(
        message: 'That folder is already part of your library.',
      );
      return;
    }
    await _scan(_selectedFolders());
  }

  /// Removes one folder from the library and rescans what is left, so only that
  /// folder's tracks go away.
  Future<void> removeFolder(String folder) async {
    state = const LocalMusicActionState(busy: true);
    await ref
        .read(selectedFolderControllerProvider.notifier)
        .removeAndPersist(folder);
    final List<String> remaining = _selectedFolders();
    if (remaining.isEmpty) {
      await ref.read(libraryControllerProvider.notifier).clearLocalCatalog();
      state = const LocalMusicActionState(
        message: 'Folder removed. Your files were not deleted.',
      );
      return;
    }
    final LocalScanReport? report = await _scan(remaining);
    // Keep the scan's own message when it has something to warn about; the
    // removal succeeded either way.
    if (report == null || report.hadError || report.isPartial) return;
    state = const LocalMusicActionState(
      message: 'Folder removed. Your files were not deleted.',
    );
  }

  /// Asks one folder again, because the user says it should be back.
  ///
  /// The probe first, then a scan: a folder that is still away must not cost a
  /// full walk of the library to say so, and a folder that *is* back needs the
  /// ordinary incremental scan to pick up whatever changed while it was gone.
  /// The scan covers the whole selection because that is the only entry point
  /// that writes the local catalog. A folder-specific write would be a second
  /// way to build the same slice, and the two would drift.
  ///
  /// Nothing here can remove a folder, change the selection, or substitute a
  /// path. The worst case is "still can't reach it", said plainly.
  Future<void> retryFolder(String folder) async {
    state = const LocalMusicActionState(busy: true);
    await ref.read(localRootAvailabilityProvider.notifier).recheck(folder);
    final LocalRootFault? fault =
        ref.read(localRootAvailabilityProvider).faultFor(folder);
    if (fault != null) {
      state = LocalMusicActionState(
        message: _stillUnreachable(fault),
        isError: true,
      );
      return;
    }
    final List<String> folders = _selectedFolders();
    if (folders.isEmpty) {
      state = const LocalMusicActionState();
      return;
    }
    await _scan(folders);
  }

  /// Replaces one folder with a folder the user picks, leaving the others
  /// alone.
  ///
  /// This is the *only* way a configured folder's path ever changes, and it
  /// goes through the system chooser every time: a drive that came back at a
  /// different mount point is a different path, Linthra cannot prove it is the
  /// same hardware, and adopting it silently would point a library at somebody
  /// else's files. Cancelling changes nothing at all.
  Future<void> reselectFolder(String folder) async {
    state = const LocalMusicActionState(busy: true);
    final String? picked = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndReplace(folder);
    if (picked == null || picked.isEmpty) {
      // Cancelled. The folder that could not be read is still selected, its
      // music is still indexed, and nothing was written.
      state = const LocalMusicActionState();
      return;
    }
    final List<String> remaining = _selectedFolders();
    if (remaining.isEmpty) {
      // Only possible if the picked folder normalized away to nothing; there is
      // no local source left to scan, so clear the slice the way Remove does.
      await ref.read(libraryControllerProvider.notifier).clearLocalCatalog();
      state = const LocalMusicActionState();
      return;
    }
    // Picking the *same* folder again is a real fix, not a no-op: it is how a
    // revoked portal document is re-granted, so this scans either way.
    await _scan(remaining);
  }

  /// Opts into Android's device-wide shared music library.
  ///
  /// The switch is transactional: the permission is requested, the first
  /// MediaStore scan runs, and only a scan that actually succeeded persists the
  /// MediaStore sentinel. A denial or a failed first scan therefore leaves an
  /// existing folder selection *and* its indexed catalog exactly as they were,
  /// rather than stranding the app in MediaStore mode while it still shows
  /// tracks from a folder it can no longer name.
  Future<void> useAllDeviceMusic() async {
    if (!ref.read(hostPlatformProvider).isAndroid) return;
    state = const LocalMusicActionState(busy: true);
    final AndroidMusicPermissionStatus status =
        await ref.read(androidMediaLibraryProvider).requestPermission();
    ref.invalidate(androidMusicPermissionStatusProvider);
    unawaited(ref.read(localRootAvailabilityProvider.notifier).refresh());
    if (status != AndroidMusicPermissionStatus.allowed) {
      state = const LocalMusicActionState(
        message: 'Device music access was not granted. You can keep using a '
            'selected folder instead.',
        isError: true,
      );
      return;
    }

    // Scan before persisting. The scan takes the location explicitly, so
    // nothing has to be saved first, and a failure leaves the stored selection
    // untouched: no restore step, and no window where a crash could strand a
    // half-applied switch.
    final LocalScanReport? report =
        await _scan(<String>[FolderLocation.androidMediaStoreAudio]);
    if (report == null || report.hadError) {
      return;
    }
    await ref
        .read(selectedFolderControllerProvider.notifier)
        .setAndPersist(FolderLocation.androidMediaStoreAudio);
  }

  Future<void> refreshAndroidPermissionStatus() async {
    ref.invalidate(androidMusicPermissionStatusProvider);
    await ref.read(localRootAvailabilityProvider.notifier).refresh();
  }

  Future<void> openAndroidPermissions() async {
    await ref.read(androidMediaLibraryProvider).openAppSettings();
  }

  Future<void> rescan() async {
    final List<String> folders = _selectedFolders();
    if (folders.isEmpty) {
      return;
    }
    state = const LocalMusicActionState(busy: true);
    await _scan(folders);
  }

  Future<void> forget() async {
    final library = ref.read(libraryControllerProvider.notifier);
    // Invalidate immediately, before the first await. The selection controller
    // also invalidates source changes, and clearLocalCatalog serializes the
    // actual clear after any already-started local catalog write.
    library.invalidatePendingScans();
    state = const LocalMusicActionState(busy: true);
    await ref.read(selectedFolderControllerProvider.notifier).clear();
    await library.clearLocalCatalog();
    state = const LocalMusicActionState(
      message: 'Local music forgotten. Your files were not deleted.',
    );
  }

  List<String> _selectedFolders() =>
      ref.read(selectedFolderControllerProvider).valueOrNull ?? <String>[];

  /// Scans [folders] as one library, turns the resulting report into the card's
  /// status line, and hands the report back so a caller can act on the outcome.
  Future<LocalScanReport?> _scan(List<String> folders) async {
    // Use this operation's result, never the last globally recorded report:
    // a superseded scan must not look successful or persist a source switch.
    final report = await ref
        .read(libraryControllerProvider.notifier)
        .scanFoldersWithReport(folders);
    if (report == null) {
      state = const LocalMusicActionState();
      return null;
    }
    final bool isDeviceLibrary = folders.length == 1 &&
        FolderLocation.parse(folders.first).isAndroidMediaStore;
    if (report.hadError) {
      final String message;
      if (isDeviceLibrary) {
        message = report.error == LocalScanError.mediaPermission
            ? 'Could not scan the device music library. Check device music '
                'access in Android settings, or choose a folder instead.'
            : "Couldn't read Android's shared music library. Try again, or "
                'choose a folder instead.';
      } else if (report.rootsScanned > 1) {
        message = "Couldn't read any of your music folders. Check that the "
            'drives are connected, or select them again.';
      } else {
        message = "Couldn't scan that folder. Try selecting it again.";
      }
      state = LocalMusicActionState(message: message, isError: true);
      return report;
    }
    if (report.importedTracks > 0) {
      final String source = isDeviceLibrary
          ? 'this device'
          : report.rootsScanned > 1
              ? '${report.rootsAvailable} '
                  '${report.rootsAvailable == 1 ? 'folder' : 'folders'}'
              : 'this folder';
      final String tracks = '${report.importedTracks} '
          '${report.importedTracks == 1 ? 'track' : 'tracks'}';
      state = LocalMusicActionState(
        message: report.isPartial
            ? 'Added $tracks from $source. '
                '${_unavailableSuffix(report.rootsUnavailable)}'
            : 'Added $tracks from $source.',
        isError: report.isPartial,
      );
      return report;
    }
    final bool isContentUri =
        folders.length == 1 && FolderLocation.parse(folders.first).isContentUri;
    final bool looksBlocked = report.readFailures > 0 ||
        report.isPartial ||
        (isContentUri && report.filesVisited == 0);
    state = LocalMusicActionState(
      message: isDeviceLibrary
          ? 'No music was found in Android MediaStore.'
          : report.isPartial
              ? 'No music found in the folders Linthra could read. '
                  '${_unavailableSuffix(report.rootsUnavailable)}'
              : looksBlocked
                  ? 'No music found. Linthra may not have access to that '
                      'folder — try selecting it again.'
                  : report.rootsScanned > 1
                      ? 'No playable audio found in those folders.'
                      : 'No playable audio found in that folder.',
      isError: looksBlocked,
    );
    return report;
  }

  /// What Retry says when the folder is still away. Worded from the fault, so
  /// "put the drive back" and "fix the permissions" are never swapped, and
  /// never carrying an OS message, only the kind.
  static String _stillUnreachable(LocalRootFault fault) {
    switch (fault) {
      case LocalRootFault.missing:
        return "That folder still isn't there. Reconnect the drive, or select "
            'the folder again if the music moved.';
      case LocalRootFault.permissionDenied:
        return "Linthra still isn't allowed to read that folder. Check its "
            'permissions, or select the folder again.';
      case LocalRootFault.unavailable:
        return 'That storage still is not responding. Reconnect it and try '
            'again.';
      case LocalRootFault.unknown:
        return "Linthra still couldn't read that folder. Try selecting it "
            'again.';
    }
  }

  static String _unavailableSuffix(int unavailable) {
    final String folders = unavailable == 1 ? 'folder' : 'folders';
    return '$unavailable $folders could not be read, so their music was kept '
        'as it was.';
  }
}

final localMusicControllerProvider =
    NotifierProvider<LocalMusicController, LocalMusicActionState>(
  LocalMusicController.new,
);

/// Which of the selected local-music folders Linthra can still reach.
///
/// Keyed by folder, so the Settings list can flag exactly the one whose drive
/// is unplugged instead of declaring the whole library broken. A folder Linthra
/// cannot answer for on this platform, and one nothing has answered for yet,
/// are both left out of the map rather than reported as unreachable.
///
/// Derived, never probed: [localRootAvailabilityProvider] already owns the one
/// probe, the one poll and the one set of rules for "can Linthra read this
/// folder?". Asking storage a second question here is exactly how the card and
/// the library screen would come to disagree about one drive.
final localFolderAccessProvider = Provider<Map<String, bool>>((ref) {
  return ref.watch(localRootAvailabilityProvider).reachability;
});

/// The unreachable folders and what is wrong with each. What the recovery UI
/// renders: one entry per folder that needs the user, each carrying its own fix.
final localRootFaultsProvider = Provider<Map<String, LocalRootFault>>((ref) {
  return ref.watch(localRootAvailabilityProvider).faults;
});

/// Whether any selected folder is currently unreachable — the one-line answer
/// the compact source card needs.
final localFolderAccessLostProvider = Provider<bool>((ref) {
  return ref.watch(localRootAvailabilityProvider).hasUnavailableRoots;
});
