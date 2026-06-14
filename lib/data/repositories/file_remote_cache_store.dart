import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/services/remote_cache/remote_cache_record.dart';
import '../../core/services/remote_cache/remote_cache_store.dart';

/// The app's [RemoteCacheStore]: a single JSON **manifest** of credential-free
/// [RemoteCacheRecord]s under an app-private `remote_cache/` directory.
///
/// It sits beside the offline downloads' `offline_audio/` directory but is a
/// distinct, complementary thing: this manifest is the remote playback cache's
/// own durable index (what was prepared, and where its bytes *would* live), not
/// the user's explicit downloads. It lives under the application *support*
/// location (not the OS cache, which can be reclaimed at any time) and is the
/// directory the future on-disk byte cache will write into, keyed by each
/// record's [RemoteCacheRecord.fileSafeName].
///
/// The base directory is injected so tests can point it at a temp folder; the
/// app uses `path_provider`'s application-support directory by default.
///
/// Security: the manifest can only ever contain a record's opaque key and its
/// timestamps (see [RemoteCacheRecord.toJson]) — never a stream URL, an artwork
/// URL, or a token. A malformed or hand-edited manifest degrades to an empty
/// index ([load] never throws), and any line whose key is not a safe
/// credential-free remote id is dropped on the way in by
/// [RemoteCacheRecord.fromJson].
class FileRemoteCacheStore implements RemoteCacheStore {
  FileRemoteCacheStore({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  /// The manifest file name inside the remote-cache directory.
  static const String _manifestName = 'index.json';

  static Future<Directory> _defaultDirectory() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'remote_cache'));
  }

  @override
  Future<List<RemoteCacheRecord>> load() async {
    try {
      final File file = await _manifestFile();
      if (!await file.exists()) return const <RemoteCacheRecord>[];
      return _decode(await file.readAsString());
    } catch (_) {
      // An unreadable manifest degrades to a cold index, never an error.
      return const <RemoteCacheRecord>[];
    }
  }

  @override
  Future<void> save(List<RemoteCacheRecord> records) async {
    final File file = await _manifestFile();
    final Directory dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String raw = jsonEncode(<Map<String, dynamic>>[
      for (final RemoteCacheRecord record in records) record.toJson(),
    ]);
    // Write a sibling temp file then rename it over the manifest: a crash or
    // kill mid-write leaves the previous good manifest intact rather than a
    // truncated one (a torn write would otherwise discard the whole index on the
    // next load). `load` reads only `index.json`, so a stray `.tmp` is ignored.
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(raw, flush: true);
    await tmp.rename(file.path);
  }

  Future<File> _manifestFile() async {
    final Directory dir = await _directory();
    return File(p.join(dir.path, _manifestName));
  }

  /// Decodes a manifest string into records, dropping any corrupt or
  /// non-credential-free entry rather than failing the whole load.
  static List<RemoteCacheRecord> _decode(String raw) {
    if (raw.isEmpty) return const <RemoteCacheRecord>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <RemoteCacheRecord>[];
    }
    if (decoded is! List) return const <RemoteCacheRecord>[];
    final List<RemoteCacheRecord> records = <RemoteCacheRecord>[];
    for (final Object? entry in decoded) {
      if (entry is Map<String, dynamic>) {
        final RemoteCacheRecord? record = RemoteCacheRecord.fromJson(entry);
        if (record != null) records.add(record);
      }
    }
    return records;
  }
}
