import 'package:flutter/foundation.dart';

import 'android_media_library.dart';
import 'directory_readability.dart';
import 'folder_location.dart';
import 'local_root_fault.dart';
import 'saf_permission_probe.dart';

/// What one probe learned about one configured root.
///
/// Deliberately a value rather than a bool: "it answered" and "it did not, and
/// here is why" are both useful, and the *why* is what lets the UI offer the
/// recovery that actually applies. It carries a fault kind and nothing else
/// (no errno, no message, no path), so a reading can be shown to a user or
/// written to the diagnostics line without anything being stripped out of it
/// first.
@immutable
class LocalRootReading {
  /// The configured root answered: it is there and it can be listed.
  const LocalRootReading.available() : fault = null;

  /// The configured root did not answer, for [fault].
  const LocalRootReading.blocked(LocalRootFault this.fault);

  /// Why the root could not be read, or null when it could.
  final LocalRootFault? fault;

  bool get isAvailable => fault == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalRootReading && other.fault == fault);

  @override
  int get hashCode => fault.hashCode;

  @override
  String toString() =>
      'LocalRootReading(${fault == null ? 'available' : fault!.name})';
}

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
  /// What [root] answers right now, or `null` when this platform cannot answer
  /// for that kind of selection.
  ///
  /// `null` is never a guess and never a failure: the caller leaves such a root
  /// untracked rather than calling a folder it cannot see "gone". It is also
  /// distinct from a [LocalRootFault.unknown] reading, which *is* a failure:
  /// one this platform saw and could not name.
  ///
  /// Must not throw. A probe that cannot complete answers `null`.
  Future<LocalRootReading?> inspect(String root);
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
  Future<LocalRootReading?> inspect(String root) async {
    if (root.trim().isEmpty) return null;
    final FolderLocation location = FolderLocation.parse(root);
    try {
      if (location.isAndroidMediaStore) {
        final AndroidMusicPermissionStatus status =
            await _mediaLibrary.permissionStatus();
        // A build that does not expose the permission at all cannot speak for
        // this selection. The same "leave it untracked" answer a SAF grant
        // gets off Android, rather than reporting a device library as revoked
        // because there is nothing here to revoke it.
        if (status == AndroidMusicPermissionStatus.unavailable) return null;
        // Otherwise the device library is never "missing": it is the platform's
        // own, and the only way it stops answering is the permission being
        // withdrawn.
        return status == AndroidMusicPermissionStatus.allowed
            ? const LocalRootReading.available()
            : const LocalRootReading.blocked(LocalRootFault.permissionDenied);
      }
      if (location.isContentUri) {
        // Null off Android, where a grant Linthra cannot see must not be called
        // lost. A grant that is genuinely gone is a permission problem, not a
        // missing folder: the tree is still wherever it was.
        final bool? granted =
            await _safPermissions.hasPersistedPermission(root);
        if (granted == null) return null;
        return granted
            ? const LocalRootReading.available()
            : const LocalRootReading.blocked(LocalRootFault.permissionDenied);
      }
      if (!_probesFilesystemPaths) return null;
      final LocalRootFault? fault = await _readability.inspect(root);
      return fault == null
          ? const LocalRootReading.available()
          : LocalRootReading.blocked(fault);
    } catch (_) {
      // A probe that faulted learned nothing. Reporting "unavailable" here would
      // turn a platform-channel hiccup into a library that looks disconnected.
      return null;
    }
  }
}
