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

  /// The bytes stored under [fileName], for test assertions; `null` if absent.
  List<int>? bytesFor(String fileName) => _files[fileName];

  @override
  Future<String> write(
    String trackId,
    List<int> bytes, {
    String? extension,
  }) async {
    final String safeId = trackId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
    final String ext = (extension != null && extension.isNotEmpty)
        ? '.${extension.replaceAll(RegExp('[^A-Za-z0-9]'), '')}'
        : '';
    final String fileName = '$safeId$ext';
    _files[fileName] = List<int>.unmodifiable(bytes);
    return fileName;
  }

  @override
  Future<String?> pathFor(String fileName) async =>
      _files.containsKey(fileName) ? '$_baseDirectory/$fileName' : null;

  @override
  Future<void> delete(String fileName) async {
    _files.remove(fileName);
  }
}
