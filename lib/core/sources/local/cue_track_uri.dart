/// The stable catalog identity and backing file path of a track from a CUE
/// sheet. The suffix keeps multiple tracks backed by one audio file distinct
/// without making the path itself unplayable.
abstract final class CueTrackUri {
  static const String _marker = '#linthra-cue=';

  static String forTrack({
    required String audioPath,
    required String cuePath,
    required int trackNumber,
  }) =>
      '$audioPath$_marker${Uri.encodeComponent(cuePath)}:$trackNumber';

  static bool isCueTrack(String uri) => _parts(uri) != null;

  static String audioPath(String uri) {
    final int marker = uri.lastIndexOf(_marker);
    if (marker < 0 || _parts(uri) == null) return uri;
    return uri.substring(0, marker);
  }

  static ({String cuePath, int trackNumber})? _parts(String uri) {
    final int marker = uri.lastIndexOf(_marker);
    if (marker < 0) return null;
    final String suffix = uri.substring(marker + _marker.length);
    final int separator = suffix.lastIndexOf(':');
    if (separator <= 0) return null;
    final int? trackNumber = int.tryParse(suffix.substring(separator + 1));
    if (trackNumber == null || trackNumber <= 0) return null;
    try {
      return (
        cuePath: Uri.decodeComponent(suffix.substring(0, separator)),
        trackNumber: trackNumber,
      );
    } on FormatException {
      return null;
    }
  }
}
