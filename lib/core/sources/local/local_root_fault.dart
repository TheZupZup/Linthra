import 'dart:io';

/// Why a configured local music folder cannot be read **right now**.
///
/// Availability already answers "did this path answer?" as a yes/no
/// ([LocalRootAvailability]). This is the follow-up question the user actually
/// needs answered, because the three common ways a folder stops answering have
/// three different fixes:
///
///  * the folder is not there → reconnect the drive, or point Linthra at where
///    the music went;
///  * the folder is there and Linthra is not allowed to read it → fix the
///    permission, or pick the folder again through the chooser so the portal
///    hands over a fresh document;
///  * the storage behind the folder is not answering → wait for the mount, or
///    plug the drive back in.
///
/// Every value here is a *kind*, never a message and never an errno. Raw OS
/// exceptions stay where they are thrown: this is what crosses into the UI, and
/// what the diagnostics line records, so neither can grow a path, a device name
/// or a C library string.
///
/// None of these mean "the folder is gone for good", and nothing keyed on them
/// may delete a track, a folder from the selection, or a file on disk. They
/// describe a recoverable state and the way out of it.
enum LocalRootFault {
  /// The configured path is not there at all: the drive was unmounted, the
  /// folder was moved or deleted, or (in the Flatpak) the portal document that
  /// exposed it was revoked, which removes the path rather than making it
  /// unreadable.
  missing,

  /// The folder is there and this process is not allowed to read it: POSIX
  /// permissions on the directory, a revoked Android grant, a sandbox that no
  /// longer exposes it.
  permissionDenied,

  /// The path resolves but the storage behind it is not answering: a network
  /// share that is down, a stale mount, a device that reports I/O errors. The
  /// most temporary of the three: nothing about the user's setup changed, and
  /// the fix is usually waiting or reconnecting.
  unavailable,

  /// It failed for a reason nothing here can name. Kept distinct from the other
  /// three so an unrecognised failure is never dressed up as a diagnosis the
  /// app cannot actually make.
  unknown;

  /// The stable string this fault travels as on [FolderScanException.code], so
  /// the scanner and the availability probe classify a folder the same way
  /// without one importing the other's error type.
  String get code {
    switch (this) {
      case LocalRootFault.missing:
        return 'folder_missing';
      case LocalRootFault.permissionDenied:
        return 'permission_denied';
      case LocalRootFault.unavailable:
        return 'storage_unavailable';
      case LocalRootFault.unknown:
        return 'folder_unreadable';
    }
  }

  /// The fault [code] names, or null when the code is not one of ours (the
  /// MediaStore wrong-scanner guard, a platform channel's own code).
  static LocalRootFault? fromCode(String? code) {
    if (code == null) return null;
    for (final LocalRootFault fault in LocalRootFault.values) {
      if (fault.code == code) return fault;
    }
    return null;
  }
}

/// `errno` values that mean "you may not read this".
///
/// The same numbers on Linux and on the BSD-derived platforms, so no dialect
/// switch is needed for the case that matters most.
const Set<int> _permissionErrno = <int>{
  1, // EPERM
  13, // EACCES
};

/// `errno` values that mean "this path is not there".
const Set<int> _missingErrno = <int>{
  2, // ENOENT
  20, // ENOTDIR: a path component stopped being a directory
};

/// `errno` values that mean "the storage behind this path is not answering".
///
/// Linux numbering, which is what the Linux desktop build and the Flatpak run
/// on. A value that means something else on another Unix simply falls through
/// to [LocalRootFault.unknown], which is the honest answer rather than a
/// confident wrong one; the two sets above are portable and carry the cases a
/// desktop user actually hits.
const Set<int> _unavailableErrno = <int>{
  5, // EIO
  19, // ENODEV
  100, // ENETDOWN
  101, // ENETUNREACH
  103, // ECONNABORTED
  104, // ECONNRESET
  107, // ENOTCONN
  110, // ETIMEDOUT
  112, // EHOSTDOWN
  113, // EHOSTUNREACH
  116, // ESTALE
};

/// Classifies a `dart:io` failure into the fault the user is shown.
///
/// The whole point of this function is that it is the *only* place an
/// [OSError] is looked at: everything downstream carries a [LocalRootFault],
/// so no errno, no `errno` message and no path can reach a widget through it.
///
/// Anything that is not a [FileSystemException], and any code this does not
/// recognise, is [LocalRootFault.unknown].
LocalRootFault classifyFilesystemFault(Object error) {
  if (error is! FileSystemException) return LocalRootFault.unknown;
  final int? code = error.osError?.errorCode;
  if (code == null) return LocalRootFault.unknown;
  if (_permissionErrno.contains(code)) return LocalRootFault.permissionDenied;
  if (_missingErrno.contains(code)) return LocalRootFault.missing;
  if (_unavailableErrno.contains(code)) return LocalRootFault.unavailable;
  return LocalRootFault.unknown;
}
