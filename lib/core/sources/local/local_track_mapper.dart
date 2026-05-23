import 'package:path/path.dart' as p;

import '../../models/track.dart';
import 'saf_document_lister.dart';

/// Builds a [Track] from an on-device source — a local file path or an Android
/// SAF document.
///
/// This is intentionally the *only* place that turns an on-device item into a
/// [Track], so richer metadata (ID3/Vorbis tags, embedded artwork, real
/// duration) can be added here later without changing the scanner or source.
abstract final class LocalTrackMapper {
  /// Maps [path] to a [Track] using only what the path itself reveals.
  ///
  /// The title is the file name without its extension. Artist, album and
  /// duration are left unset until tag parsing lands. The path doubles as both
  /// the stable [Track.id] and the [Track.uri].
  static Track fromPath(String path) {
    return Track(
      id: path,
      title: p.basenameWithoutExtension(path),
      uri: path,
    );
  }

  /// Maps a SAF [document] to a [Track]. The `content://` URI is both the
  /// stable id and the playable uri; the title is the display name without its
  /// extension (the URI alone has no reliable name to show).
  static Track fromSafDocument(SafAudioDocument document) {
    return Track(
      id: document.uri,
      title: p.basenameWithoutExtension(document.name),
      uri: document.uri,
    );
  }
}
