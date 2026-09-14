import 'dart:io';

import 'local_root_fault.dart';

/// Answers one question for the SAF scanner and for local-root availability:
/// can this app actually *list* the directory at [path] on this device right
/// now, and when it cannot, why not?
///
/// This seam exists because [SafTreeUriResolver] can map an Android SAF tree
/// URI to a filesystem path (e.g. `primary:Music` → `/storage/emulated/0/Music`)
/// that the app is then not allowed to read under Android's scoped storage. A
/// plain `dart:io` walk of such a path simply returns nothing, which looks like
/// an empty library rather than the permission problem it actually is. Probing
/// readability first lets [ContentUriAudioFileScanner] tell those two cases
/// apart and raise a clear [FolderScanException] for the unreadable one.
///
/// The answer is a [LocalRootFault] rather than a bare `false` because "the
/// folder is gone", "you may not read it" and "the drive is not answering" are
/// three different problems with three different fixes, and a user staring at
/// an empty library deserves to be told which one they have. Classification
/// happens here, at the one place that touches [OSError], so nothing downstream
/// carries an errno or a raw message.
///
/// Kept behind an interface so the SAF scanner and the availability probe stay
/// unit-testable without a real device: tests inject a fake that reports
/// readable, or the fault they want to stage.
abstract interface class DirectoryReadability {
  /// Why the directory at [path] cannot be listed by this app right now, or
  /// `null` when it can.
  ///
  /// An existing but *empty* directory is readable and answers `null`. Must not
  /// throw: a probe that cannot classify a failure answers
  /// [LocalRootFault.unknown].
  Future<LocalRootFault?> inspect(String path);
}

/// The plain yes/no every caller that only needs "is it usable?" asks.
///
/// An extension rather than a second interface method, so implementing
/// [DirectoryReadability] stays a one-method job and the two answers can never
/// disagree.
extension DirectoryReadabilityChecks on DirectoryReadability {
  /// Whether the directory at [path] exists and can be listed by this app.
  ///
  /// Returns `false` for a missing directory and for one that exists but cannot
  /// be read (the scoped-storage case); an existing but *empty* directory is
  /// reported as readable.
  Future<bool> canList(String path) async => await inspect(path) == null;
}

/// The production [DirectoryReadability], backed by `dart:io`.
///
/// One syscall's worth of work: open the listing and stop at the first entry.
/// It is deliberately *not* an `exists()` check followed by a listing, because
/// `exists()` answers false for everything it cannot stat, so a missing folder,
/// a share that timed out and a parent directory the user may not search all
/// come back identical. Going straight to the listing keeps the [OSError] that says
/// which one it was.
class IoDirectoryReadability implements DirectoryReadability {
  const IoDirectoryReadability();

  @override
  Future<LocalRootFault?> inspect(String path) async {
    try {
      // Stop at the first entry: this asks whether the directory can be opened
      // and read, not what is in it. An empty but readable directory completes
      // the loop without yielding and is reported readable.
      await for (final FileSystemEntity _ in Directory(path).list(
        followLinks: false,
      )) {
        break;
      }
      return null;
    } on FileSystemException catch (error) {
      return classifyFilesystemFault(error);
    } catch (_) {
      return LocalRootFault.unknown;
    }
  }
}
