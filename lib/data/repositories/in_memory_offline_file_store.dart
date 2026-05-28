import 'dart:async';

import '../../core/repositories/offline_file_store.dart';

/// A non-persistent [OfflineFileStore] for development and tests.
///
/// Holds bytes in memory keyed by a track-id-derived file name and hands out a
/// synthetic absolute path, so the offline-cache flow can be exercised without a
/// real filesystem or `path_provider`. The running app overrides this with
/// [FileSystemOfflineFileStore]; no bytes ever hit disk here.
class InMemoryOfflineFileStore implements OfflineFileStore {
  InMemoryOfflineFileStore({String baseDirectory = '/offline_audio'})
      : _baseDirectory = baseDirectory;

  final String _baseDirectory;
  final Map<String, List<int>> _files = <String, List<int>>{};
  final Map<String, List<int>> _temps = <String, List<int>>{};
  int _tempCounter = 0;

  /// The bytes stored under [fileName], for test assertions; `null` if absent.
  List<int>? bytesFor(String fileName) => _files[fileName];

  /// The staged bytes for [temp], for cleanup assertions; `null` if absent.
  List<int>? tempBytesFor(OfflineTempFile temp) => _temps[temp.id];

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
    return commitTemp(trackId, temp, extension: extension);
  }

  @override
  Future<OfflineTempFile> writeTemp(
    String trackId,
    Stream<List<int>> chunks, {
    String? extension,
    int? totalBytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    final String safeId = _safeId(trackId);
    final String tempId = '.$safeId-${_tempCounter++}.tmp';
    final List<int> bytes = <int>[];
    int received = 0;
    onProgress?.call(received, totalBytes);
    await for (final List<int> chunk in chunks) {
      bytes.addAll(chunk);
      received += chunk.length;
      onProgress?.call(received, totalBytes);
    }
    _temps[tempId] = List<int>.unmodifiable(bytes);
    return OfflineTempFile(id: tempId, sizeBytes: received);
  }

  @override
  Future<String> commitTemp(
    String trackId,
    OfflineTempFile temp, {
    String? extension,
  }) async {
    final List<int>? bytes = _temps.remove(temp.id);
    if (bytes == null) {
      throw StateError('Temp cache file is missing.');
    }
    final String fileName = _fileNameFor(trackId, extension);
    _files[fileName] = bytes;
    return fileName;
  }

  @override
  Future<void> deleteTemp(OfflineTempFile temp) async {
    _temps.remove(temp.id);
  }

  @override
  Future<String?> pathFor(String fileName) async =>
      _files.containsKey(fileName) ? '$_baseDirectory/$fileName' : null;

  @override
  Future<int?> sizeFor(String fileName) async => _files[fileName]?.length;

  @override
  Future<void> delete(String fileName) async {
    _files.remove(fileName);
  }

  static String _safeId(String trackId) =>
      trackId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

  static String _fileNameFor(String trackId, String? extension) {
    final String ext = (extension != null && extension.isNotEmpty)
        ? '.${extension.replaceAll(RegExp('[^A-Za-z0-9]'), '')}'
        : '';
    return '${_safeId(trackId)}$ext';
  }
}
