import 'dart:async';
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
/// Security: cache and temp file names are built only from the *non-secret*
/// track id plus a local nonce — sanitized to filename-safe characters so an odd
/// id can't escape the offline directory — never from a token or an
/// authenticated URL.
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
    final OfflineTempFile temp = await writeTemp(
      trackId,
      Stream<List<int>>.value(bytes),
      extension: extension,
    );
    try {
      return await commitTemp(trackId, temp, extension: extension);
    } catch (_) {
      await deleteTemp(temp);
      rethrow;
    }
  }

  @override
  Future<OfflineTempFile> writeTemp(
    String trackId,
    Stream<List<int>> chunks, {
    String? extension,
    int? totalBytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    final Directory dir = await _ensureDirectory();
    final String tempName = _tempFileNameFor(trackId);
    final File file = File(p.join(dir.path, tempName));
    final IOSink sink = file.openWrite();
    int received = 0;
    onProgress?.call(received, totalBytes);
    try {
      await for (final List<int> chunk in chunks) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, totalBytes);
      }
      await sink.flush();
      await sink.close();
      return OfflineTempFile(id: file.path, sizeBytes: received);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // Best effort: the original stream/write error is more useful.
      }
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }
  }

  @override
  Future<String> commitTemp(
    String trackId,
    OfflineTempFile temp, {
    String? extension,
  }) async {
    final Directory dir = await _ensureDirectory();
    final File tempFile = File(temp.id);
    if (!await tempFile.exists()) {
      throw StateError('Temp cache file is missing.');
    }
    final String fileName = _fileNameFor(trackId, extension);
    final File finalFile = File(p.join(dir.path, fileName));
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(finalFile.path);
    return fileName;
  }

  @override
  Future<void> deleteTemp(OfflineTempFile temp) async {
    final File file = File(temp.id);
    if (await file.exists()) {
      await file.delete();
    }
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

  Future<Directory> _ensureDirectory() async {
    final Directory dir = await _directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Builds a safe cache file name from the non-secret [trackId] (never a
  /// token): keeps only filename-safe characters, so an odd id can't smuggle
  /// path separators or escape the offline directory.
  static String _fileNameFor(String trackId, String? extension) {
    final String safeId = _safeId(trackId);
    final String ext = (extension != null && extension.isNotEmpty)
        ? '.${extension.replaceAll(RegExp('[^A-Za-z0-9]'), '')}'
        : '';
    return '$safeId$ext';
  }

  static String _tempFileNameFor(String trackId) {
    final String safeId = _safeId(trackId);
    final int nonce = DateTime.now().microsecondsSinceEpoch;
    return '.$safeId-$nonce.tmp';
  }

  static String _safeId(String trackId) =>
      trackId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
}
