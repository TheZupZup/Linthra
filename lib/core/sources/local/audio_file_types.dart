import 'package:path/path.dart' as p;

/// The audio file extensions Linthra's local scanner recognizes.
///
/// This is the Dart catalog's source of truth. Android's SAF scanner mirrors
/// these values for its filename fallback because Kotlin cannot import a Dart
/// constant; `audio_format_parity_test.dart` compares the two definitions so
/// future additions cannot silently drift across the platform boundary.
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

  /// Whether [path] is a CUE sidecar that can change how neighboring audio
  /// files are represented in the local library.
  static bool isCueSheet(String path) =>
      p.extension(path).toLowerCase() == '.cue';

  /// Whether [mimeType] denotes audio content (an `audio/*` type), regardless of
  /// the file name. Lets the scanner keep a file the platform recognized by
  /// content type even when its display name lacks a known extension. Matching
  /// is case-insensitive; null/blank is not audio.
  static bool isAudioMimeType(String? mimeType) {
    if (mimeType == null) {
      return false;
    }
    return mimeType.trim().toLowerCase().startsWith('audio/');
  }

  /// Whether a discovered document should be treated as audio: either its [name]
  /// carries a recognized extension or its [mimeType] is `audio/*`.
  ///
  /// This keeps the supported-types decision in one place while accepting both
  /// signals a content provider can offer, so neither an unknown MIME with a
  /// valid extension nor a valid audio MIME with an odd extension is dropped.
  static bool isSupportedDocument(String name, String? mimeType) =>
      isSupported(name) || isAudioMimeType(mimeType);
}
