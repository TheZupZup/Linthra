import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'local_lyrics_reader.dart';

/// A [LocalLyricsReader] that finds a sidecar lyrics file *on the filesystem*,
/// next to a local track addressed by a file path or `file://` URI — the
/// desktop/Linux counterpart to the Android SAF reader.
///
/// Given a track at `…/Album/Song.mp3` and extension `lrc`, it reads
/// `…/Album/Song.lrc` (same folder, same base name). A `content://` URI (an
/// Android SAF document, which has no filesystem path) is not its job, so it
/// returns `null` and the SAF reader handles those.
///
/// Best-effort and total: a missing file, a permission error, or invalid bytes
/// all resolve to `null`, so a sidecar that can't be read is simply "no lyrics"
/// — never a thrown error. Text is decoded as UTF-8 with malformed bytes
/// allowed, so one stray byte can't lose an otherwise-readable file.
class IoLocalLyricsReader implements LocalLyricsReader {
  const IoLocalLyricsReader();

  @override
  Future<String?> readSidecar(String trackUri, String extension) async {
    final String? path = _filesystemPath(trackUri);
    if (path == null) return null;
    final String sidecar = p.join(
      p.dirname(path),
      '${p.basenameWithoutExtension(path)}.$extension',
    );
    try {
      final File file = File(sidecar);
      if (!await file.exists()) return null;
      return await file.readAsString(
        encoding: const Utf8Codec(allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  /// The filesystem path for [trackUri], or `null` when it isn't a local file
  /// location (a `content://` SAF document, or a remote scheme this reader can't
  /// open). A bare path and a `file://` URI both resolve to a path.
  static String? _filesystemPath(String trackUri) {
    final Uri? uri = Uri.tryParse(trackUri);
    if (uri == null || uri.scheme.isEmpty) return trackUri;
    if (uri.scheme.toLowerCase() == 'file') return uri.toFilePath();
    return null;
  }
}
