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
    final Directory dir = await _directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String fileName = _fileNameFor(trackId, extension);
    final File file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return fileName;
  }

  @override
  Future<String?> pathFor(String fileName) async {
    final Directory dir = await _directory();
    final File file = File(p.join(dir.path, fileName));
    return await file.exists() ? file.path : null;
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
