import 'dart:io';
import 'dart:math';

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
  FileSystemOfflineFileStore({
    Future<Directory> Function()? directory,
    Future<RandomAccessFile> Function(File temp)? openDraft,
  })  : _directory = directory ?? _defaultDirectory,
        _openDraft = openDraft ?? _openForWriting;

  final Future<Directory> Function() _directory;

  /// Opens a draft's temp file for writing. Tests hand in their own, to have
  /// the disk fail on cue.
  final Future<RandomAccessFile> Function(File temp) _openDraft;

  static Future<RandomAccessFile> _openForWriting(File temp) =>
      temp.open(mode: FileMode.writeOnly);

  /// Files modified after this may be ones this run is writing, so
  /// [removeAbandoned] never takes them: when this store was created, less a
  /// margin, since file times come from a coarser clock than [DateTime.now]
  /// (and are whole seconds on some filesystems).
  final DateTime _sweepCutoff =
      DateTime.now().subtract(const Duration(seconds: 10));

  /// Whether [removeAbandoned] has run.
  bool _sweptAbandoned = false;

  /// Suffix of a draft's temp file, which publishing renames from. A leftover
  /// (from a crash mid-download) is never referenced by download metadata, so
  /// it is never served, and [removeAbandoned] clears it at the next launch.
  static const String _tempSuffix = '.part';

  static Future<Directory> _defaultDirectory() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'offline_audio'));
  }

  @override
  Future<OfflineFileDraft> createDraft(String trackId) async {
    final Directory dir = await _directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // A name of its own for every draft: a download and a pre-cache of the
    // same track can be fetching at once. Still ends in the temp suffix, so
    // nothing ever mistakes it for a cache file and a leftover is cleared.
    final String serial =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${_draftRandom.nextInt(1 << 30).toRadixString(36)}';
    final File temp = File(
      p.join(dir.path, '${_safeId(trackId)}.$serial$_tempSuffix'),
    );
    final RandomAccessFile file = await _openDraft(temp);
    return _FileDraft(dir.path, trackId, temp, file);
  }

  static final Random _draftRandom = Random();

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

  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) async {
    // Once: the repository asks at its startup load, before it writes
    // anything, and a repository built again later shares this store while
    // the first one may still be writing.
    if (_sweptAbandoned) return;
    _sweptAbandoned = true;
    try {
      final Directory dir = await _directory();
      if (!await dir.exists()) return;
      // Not following links: only this directory's own files are ever taken.
      await for (final FileSystemEntity entity
          in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final String name = p.basename(entity.path);
        if (!name.endsWith(_tempSuffix) &&
            (temporaryOnly || referenced.contains(name))) {
          continue;
        }
        try {
          if (!(await entity.lastModified()).isBefore(_sweepCutoff)) continue;
          await entity.delete();
        } on FileSystemException {
          // Gone already, or not ours to remove: leave it.
        }
      }
    } on Object {
      // Best-effort: the cache works the same with the leftovers in place.
    }
  }

  /// Builds a safe cache file name from the non-secret [trackId] (never a
  /// token): keeps only filename-safe characters, so an odd id can't smuggle
  /// path separators or escape the offline directory.
  static String _fileNameFor(String trackId, String? extension) {
    final String ext = (extension != null && extension.isNotEmpty)
        ? '.${extension.replaceAll(RegExp('[^A-Za-z0-9]'), '')}'
        : '';
    return '${_safeId(trackId)}$ext';
  }

  static String _safeId(String trackId) =>
      trackId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
}

/// A draft on disk: a temp file in the offline directory, written as the
/// download arrives and renamed into place when it is published.
class _FileDraft implements OfflineFileDraft {
  _FileDraft(this._directory, this._trackId, this._temp, this._file);

  final String _directory;
  final String _trackId;
  final File _temp;
  RandomAccessFile? _file;
  int _length = 0;

  /// Published or discarded: either way the temp file is no longer this
  /// draft's to write or delete.
  bool _settled = false;

  @override
  int get length => _length;

  @override
  Future<void> add(List<int> chunk) async {
    final RandomAccessFile? file = _file;
    if (_settled || file == null) {
      throw StateError('This cache file is no longer being written.');
    }
    await file.writeFrom(chunk);
    _length += chunk.length;
  }

  @override
  Future<String> publish({String? extension}) async {
    if (_settled) {
      throw StateError('This cache file is no longer being written.');
    }
    try {
      final RandomAccessFile? file = _file;
      if (file != null) {
        await file.flush();
        await file.close();
        // Only once closed: a flush or close that fails leaves it to
        // [discard] to close, rather than open until the process ends.
        _file = null;
      }
      // Validate before publishing anything: an empty download (an
      // interrupted or truncated fetch can end with zero bytes) is never a
      // valid cache file, and would masquerade as one, since the playback
      // locator only checks that a file exists.
      if (_length == 0) {
        throw const FileSystemException('Refusing to cache an empty download.');
      }
      // Confirm the temp holds every byte before publishing it, so a short
      // write (the disk filled up, say) is caught here rather than renamed
      // into the cache to fail later.
      final int written = await _temp.length();
      if (written != _length) {
        throw FileSystemException(
          'Cached file is incomplete ($written/$_length bytes).',
          _temp.path,
        );
      }
      // Atomic publish: a rename within one directory is atomic on the POSIX
      // filesystems Linthra targets, so the playback locator only ever sees
      // the fully written file or no file, even if the process is killed
      // here. The metadata that marks the track cached is written by the
      // repository only after this returns, so a crash between the rename and
      // that write leaves a file no record names, which the next launch
      // clears.
      final String fileName =
          FileSystemOfflineFileStore._fileNameFor(_trackId, extension);
      await _temp.rename(p.join(_directory, fileName));
      _settled = true;
      return fileName;
    } on Object {
      await discard();
      rethrow;
    }
  }

  @override
  Future<void> discard() async {
    if (_settled) return;
    _settled = true;
    final RandomAccessFile? file = _file;
    _file = null;
    try {
      await file?.close();
    } on Object {
      // Closing only matters so the delete below can go through.
    }
    try {
      if (await _temp.exists()) await _temp.delete();
    } on FileSystemException {
      // Left for the next launch's sweep of temp files.
    }
  }
}
