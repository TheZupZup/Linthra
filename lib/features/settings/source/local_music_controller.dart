import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/local/android_media_library.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_music_roots.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../library/library_controller.dart';
import '../../library/library_providers.dart';
import '../../library/local_scan_report_provider.dart';
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
    ref.invalidate(localFolderAccessProvider);
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
    ref.invalidate(localFolderAccessProvider);
  }

  Future<void> refreshAndroidPermissionStatus() async {
    ref.invalidate(androidMusicPermissionStatusProvider);
    ref.invalidate(localFolderAccessProvider);
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
/// cannot answer for on this platform is left out of the map rather than
/// reported as unreachable.
final localFolderAccessProvider =
    FutureProvider<Map<String, bool>>((ref) async {
  final List<String> folders =
      ref.watch(selectedFolderControllerProvider).valueOrNull ?? <String>[];
  ref.watch(localScanReportProvider);
  final Map<String, bool> access = <String, bool>{};
  for (final String folder in folders) {
    if (folder.isEmpty) continue;
    final FolderLocation location = FolderLocation.parse(folder);
    if (location.isAndroidMediaStore) {
      final AndroidMusicPermissionStatus status =
          await ref.read(androidMediaLibraryProvider).permissionStatus();
      access[folder] = status == AndroidMusicPermissionStatus.allowed;
      continue;
    }
    if (location.isContentUri) {
      // Null means the probe can't answer here (off Android). Leave the folder
      // out rather than calling a grant Linthra cannot see "lost".
      final bool? granted = await ref
          .read(safPermissionProbeProvider)
          .hasPersistedPermission(folder);
      if (granted != null) access[folder] = granted;
      continue;
    }
    if (!ref.watch(hostPlatformProvider).isDesktop) continue;
    access[folder] = await ref.read(directoryReadabilityProvider).canList(
          folder,
        );
  }
  return access;
});

/// Whether any selected folder is currently unreachable — the one-line answer
/// the compact source card needs.
final localFolderAccessLostProvider = Provider<bool>((ref) {
  final Map<String, bool>? access =
      ref.watch(localFolderAccessProvider).valueOrNull;
  if (access == null) return false;
  return access.values.any((bool reachable) => !reachable);
});
