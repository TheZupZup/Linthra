import 'dart:typed_data';

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
  Future<OfflineFileDraft> createDraft(String trackId) async =>
      _MemoryDraft(this, trackId);

  String _publish(String trackId, List<int> bytes, String? extension) {
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
  Future<int?> sizeFor(String fileName) async => _files[fileName]?.length;

  @override
  Future<void> delete(String fileName) async {
    _files.remove(fileName);
  }

  /// Every file here was written by this run, so none is ever abandoned.
  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) async {}
}

/// A draft held in memory until it is published into the store's map.
class _MemoryDraft implements OfflineFileDraft {
  _MemoryDraft(this._store, this._trackId);

  final InMemoryOfflineFileStore _store;
  final String _trackId;
  final BytesBuilder _bytes = BytesBuilder();
  bool _settled = false;

  @override
  int get length => _bytes.length;

  @override
  Future<void> add(List<int> chunk) async {
    if (_settled) {
      throw StateError('This cache file is no longer being written.');
    }
    _bytes.add(chunk);
  }

  @override
  Future<String> publish({String? extension}) async {
    if (_settled) {
      throw StateError('This cache file is no longer being written.');
    }
    _settled = true;
    return _store._publish(_trackId, _bytes.takeBytes(), extension);
  }

  @override
  Future<void> discard() async {
    _settled = true;
    _bytes.clear();
  }
}
