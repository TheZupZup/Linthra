import 'dart:io';

/// Answers one question for the SAF scanner: can this app actually *list* the
/// directory at [path] on this device right now?
///
/// This seam exists because [SafTreeUriResolver] can map an Android SAF tree
/// URI to a filesystem path (e.g. `primary:Music` → `/storage/emulated/0/Music`)
/// that the app is then not allowed to read under Android's scoped storage. A
/// plain `dart:io` walk of such a path simply returns nothing, which looks like
/// an empty library rather than the permission problem it actually is. Probing
/// readability first lets [ContentUriAudioFileScanner] tell those two cases
/// apart and raise a clear [FolderScanException] for the unreadable one.
///
/// Kept behind an interface so the SAF scanner stays unit-testable without a
/// real device: tests inject a fake that reports "readable"/"not readable".
abstract interface class DirectoryReadability {
  /// Whether the directory at [path] exists and can be listed by this app.
  ///
  /// Returns `false` for a missing directory and for one that exists but cannot
  /// be read (the scoped-storage case); an existing but *empty* directory is
  /// reported as readable.
  Future<bool> canList(String path);
}

/// The production [DirectoryReadability], backed by `dart:io`.
class IoDirectoryReadability implements DirectoryReadability {
  const IoDirectoryReadability();

  @override
  Future<bool> canList(String path) async {
    final Directory directory = Directory(path);
    try {
      if (!await directory.exists()) {
        return false;
      }
      // Touch the listing: an existing-but-unreadable directory (the scoped
      // storage case) only fails here, not on exists(). An empty but readable
      // directory completes the loop without yielding and is reported readable.
      await for (final FileSystemEntity _ in directory.list(
        followLinks: false,
      )) {
        break;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
