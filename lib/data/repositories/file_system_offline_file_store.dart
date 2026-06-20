import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/repositories/offline_file_store.dart';

/// The app's [OfflineFileStore]: keeps downloaded audio in an app-private
/// directory under the application *support* location (not the OS cache, which
/// can be reclaimed at any time), so explicit user downloads survive restarts
/// until the user removes them.
///
/// The base directory is injected so tests can point it at a temp folder; the
/// app uses `path_provider`'s application-support directory by default.
///
/// Security: the cache file name is built only from the *non-secret* track id —
/// sanitized to filename-safe characters so an odd id can't escape the offline
/// directory — never from a token or an authenticated URL.
class FileSystemOfflineFileStore implements OfflineFileStore {
  FileSystemOfflineFileStore({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  /// Suffix for the in-progress temp file an atomic [write] renames from. A
  /// leftover (from a crash mid-write) is never referenced by download metadata,
  /// so it is harmless, and the next same-name download overwrites it.
  static const String _tempSuffix = '.part';

  static Future<Directory> _defaultDirectory() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'offline_audio'));
  }

  @override
  Future<String> write(
    String trackId,
    List<int> bytes, {
    String? extension,
  }) async {
    // Validate before writing anything: an empty download (an interrupted or
    // truncated fetch can hand back zero bytes) is never a valid cache file —
    // and would masquerade as one, since the playback locator only checks that
    // a file *exists*. Refusing it here surfaces as a failed write the caller
    // streams past, rather than a 0-byte file that fails at play time.
    if (bytes.isEmpty) {
      throw const FileSystemException('Refusing to cache an empty download.');
    }
    final Directory dir = await _directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String fileName = _fileNameFor(trackId, extension);
    final File target = File(p.join(dir.path, fileName));

    // Atomic publish: write to a temporary sibling, validate it, then rename it
    // into place. A rename within one directory is atomic on the POSIX
    // filesystems Linthra targets, so the playback locator only ever sees the
    // fully-written file or no file — never a half-written one, even if the
    // process is killed mid-write. The metadata that marks the track cached is
    // written by the repository only *after* this returns, so a crash between
    // the rename and that write just leaves an unreferenced file the next
    // download (same name) overwrites — it is never mistaken for cached.
    final File temp = File('${target.path}$_tempSuffix');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      // Confirm the temp holds every byte before publishing it, so a short
      // write (e.g. the disk filled mid-write) is caught and discarded here
      // rather than renamed into the cache to fail later.
      final int written = await temp.length();
      if (written != bytes.length) {
        throw FileSystemException(
          'Cached file is incomplete ($written/${bytes.length} bytes).',
          target.path,
        );
      }
      await temp.rename(target.path);
    } on Object {
      // Never leave a partial temp behind on any failure (validation or I/O).
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
    return fileName;
  }

  @override
  Future<String?> pathFor(String fileName) async {
    final Directory dir = await _directory();
    final File file = File(p.join(dir.path, fileName));
    return await file.exists() ? file.path : null;
  }

  @override
  Future<int?> sizeFor(String fileName) async {
    final Directory dir = await _directory();
    final File file = File(p.join(dir.path, fileName));
    return await file.exists() ? await file.length() : null;
  }

  @override
  Future<void> delete(String fileName) async {
    final Directory dir = await _directory();
    final File file = File(p.join(dir.path, fileName));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Builds a safe cache file name from the non-secret [trackId] (never a
  /// token): keeps only filename-safe characters, so an odd id can't smuggle
  /// path separators or escape the offline directory.
  static String _fileNameFor(String trackId, String? extension) {
    final String safeId = trackId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
    final String ext = (extension != null && extension.isNotEmpty)
        ? '.${extension.replaceAll(RegExp('[^A-Za-z0-9]'), '')}'
        : '';
    return '$safeId$ext';
  }
}
