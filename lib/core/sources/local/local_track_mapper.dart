import 'package:path/path.dart' as p;

import '../../models/track.dart';

/// Builds a [Track] from a local file path.
///
/// This is intentionally the *only* place that turns a file into a [Track], so
/// richer metadata (ID3/Vorbis tags, embedded artwork, real duration) can be
/// added here later without changing the scanner or the source.
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
}
