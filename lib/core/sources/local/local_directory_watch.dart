import 'dart:async';
import 'dart:io';

/// One change the filesystem reported under a watched folder.
///
/// Deliberately thin: the watcher does not care *what* happened, only that
/// something under a music folder did, because the answer either way is the
/// same incremental rescan. Keeping the event this small also means the fake a
/// test drives it with is a two-line class rather than a re-implementation of
/// inotify.
class LocalDirectoryChange {
  const LocalDirectoryChange(this.path);

  /// The path the platform named. Absolute for a real watch; whatever the test
  /// supplied for a synthetic one.
  final String path;

  @override
  String toString() => 'LocalDirectoryChange($path)';
}

/// Opens a recursive watch on one folder.
///
/// The seam through which library watching touches the OS, in the same shape
/// as [AudioFileScanner] and [LocalMetadataReader], so the debounce, failure
/// and disposal rules can all be exercised without a real filesystem or a real
/// inotify budget.
///
/// Implementations either return a stream or throw. Throwing is a normal,
/// expected outcome: the folder may not exist, the platform may not support
/// watching, or the kernel may be out of watch descriptors.
abstract interface class DirectoryWatchFactory {
  /// A stream of changes under [root], recursively.
  ///
  /// Throws when a watch cannot be opened at all. The stream may also emit an
  /// error later, which means the same thing: this folder is no longer being
  /// watched.
  Stream<LocalDirectoryChange> watch(String root);
}

/// The production [DirectoryWatchFactory]: `dart:io`, which on Linux is
/// inotify.
///
/// Recursive because a music library is a tree of artist and album folders and
/// the interesting change is usually several levels down. `dart:io` adds
/// watches for subfolders as it sees them created, so an album copied into a
/// new folder is noticed without re-opening the watch.
class IoDirectoryWatchFactory implements DirectoryWatchFactory {
  const IoDirectoryWatchFactory();

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    if (!FileSystemEntity.isWatchSupported) {
      throw const FileSystemException('filesystem watching is not supported');
    }
    return Directory(root)
        .watch(recursive: true)
        .map((FileSystemEvent event) => LocalDirectoryChange(event.path));
  }
}

/// A [DirectoryWatchFactory] for the platforms where watching a path is not the
/// right question: Android, whose local library is a Storage Access Framework
/// tree or a MediaStore query rather than a directory Linthra may walk.
///
/// It refuses every root, which the watcher treats exactly as it treats a
/// kernel that ran out of watches: nothing is watched, manual refresh is
/// untouched, and the app says so rather than pretending it is live.
class UnsupportedDirectoryWatchFactory implements DirectoryWatchFactory {
  const UnsupportedDirectoryWatchFactory();

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    throw const FileSystemException(
      'filesystem watching is not used on this platform',
    );
  }
}
