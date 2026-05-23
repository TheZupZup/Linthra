import 'package:path/path.dart' as p;

/// The audio file extensions Linthra's local scanner recognizes.
///
/// Kept small and centralized on purpose: supporting a new container format
/// later is a one-line change here that the rest of the scanner picks up for
/// free.
abstract final class AudioFileTypes {
  /// Recognized extensions, lower-case and *without* the leading dot.
  static const Set<String> supportedExtensions = <String>{
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'opus',
    'wav',
  };

  /// Whether [path] points at a file with a recognized audio extension.
  ///
  /// Matching is case-insensitive and ignores the directory part, so
  /// `/Music/Album/Track.FLAC` is recognized. Files with no extension —
  /// including dotfiles such as `.DS_Store` — are not treated as audio.
  static bool isSupported(String path) {
    final String ext = p.extension(path).toLowerCase();
    if (ext.isEmpty) {
      return false;
    }
    return supportedExtensions.contains(ext.substring(1));
  }
}
