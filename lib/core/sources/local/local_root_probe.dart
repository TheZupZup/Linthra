import 'android_media_library.dart';
import 'directory_readability.dart';
import 'folder_location.dart';
import 'saf_permission_probe.dart';

/// Answers one question about one configured local root: can Linthra reach it
/// right now?
///
/// The seam through which availability tracking touches storage, in the same
/// shape as [AudioFileScanner] and [DirectoryWatchFactory], so the state
/// machine above it can be tested without a disk, a drive to unplug, or a
/// device.
///
/// It asks about **the configured path and nothing else**. There is deliberately
/// no "find where this drive went" step: a removable disk that comes back at a
/// different mount point is a different path, Linthra has no way to prove it is
/// the same hardware, and silently adopting it would point a library at
/// somebody else's files. An unavailable root stays unavailable until the path
/// the user configured answers again, or until they choose a new one.
abstract interface class LocalRootProbe {
  /// Whether [root] is reachable right now, or `null` when this platform cannot
  /// answer for that kind of selection.
  ///
  /// `null` is never a guess and never a failure: the caller leaves such a root
  /// untracked rather than calling a folder it cannot see "gone".
  ///
  /// Must not throw. A probe that cannot complete answers `null`.
  Future<bool?> isAvailable(String root);
}

/// The production [LocalRootProbe]: routes each kind of selection to the seam
/// that can already speak for it.
///
///  * a **filesystem path** (desktop, the removable-drive case) is listed
///    through [DirectoryReadability], which answers false for a path that is
///    missing *and* for one that exists but cannot be read, both of which mean
///    "not usable right now";
///  * an **Android SAF tree** is answered by whether its persisted read grant is
///    still held;
///  * **Android's device-wide library** is answered by its permission state.
///
/// Nothing here knows about mount points, automounters, `/run/media`, `/media`,
/// or any desktop environment's conventions. A removable drive is simply a path
/// that is sometimes there, which is the only property Linthra needs and the
/// only one that holds on every distribution.
class PlatformLocalRootProbe implements LocalRootProbe {
  const PlatformLocalRootProbe({
    required DirectoryReadability readability,
    required SafPermissionProbe safPermissions,
    required AndroidMediaLibrary mediaLibrary,
    required bool probesFilesystemPaths,
  })  : _readability = readability,
        _safPermissions = safPermissions,
        _mediaLibrary = mediaLibrary,
        _probesFilesystemPaths = probesFilesystemPaths;

  final DirectoryReadability _readability;
  final SafPermissionProbe _safPermissions;
  final AndroidMediaLibrary _mediaLibrary;

  /// Whether a filesystem path is a question this host can answer. False on
  /// Android, where a raw path left over from an old selection cannot be read
  /// under scoped storage anyway, so probing it would report a loss that means
  /// nothing.
  final bool _probesFilesystemPaths;

  @override
  Future<bool?> isAvailable(String root) async {
    if (root.trim().isEmpty) return null;
    final FolderLocation location = FolderLocation.parse(root);
    try {
      if (location.isAndroidMediaStore) {
        final AndroidMusicPermissionStatus status =
            await _mediaLibrary.permissionStatus();
        return status == AndroidMusicPermissionStatus.allowed;
      }
      if (location.isContentUri) {
        // Null off Android, where a grant Linthra cannot see must not be called
        // lost.
        return await _safPermissions.hasPersistedPermission(root);
      }
      if (!_probesFilesystemPaths) return null;
      return await _readability.canList(root);
    } catch (_) {
      // A probe that faulted learned nothing. Reporting "unavailable" here would
      // turn a platform-channel hiccup into a library that looks disconnected.
      return null;
    }
  }
}
