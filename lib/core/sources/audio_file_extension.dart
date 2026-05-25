/// Maps a response `Content-Type` to a cache-file extension.
///
/// Shared by the remote downloaders (Jellyfin, Subsonic) so the on-disk cache
/// names a downloaded file sensibly. Returns `null` for unknown types; the audio
/// engine sniffs the container regardless, so the extension is only a
/// convenience — never relied on for correctness, and (security) it carries no
/// token, since a content type isn't a credential.
abstract final class AudioFileExtension {
  /// The lowercase extension (without the dot) for [contentType], or `null` when
  /// the type is absent or unrecognized.
  static String? forContentType(String? contentType) {
    if (contentType == null) return null;
    final String type = contentType.split(';').first.trim().toLowerCase();
    switch (type) {
      case 'audio/mpeg':
      case 'audio/mp3':
        return 'mp3';
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
      case 'audio/mp4':
      case 'audio/m4a':
      case 'audio/x-m4a':
        return 'm4a';
      case 'audio/aac':
        return 'aac';
      case 'audio/ogg':
      case 'application/ogg':
        return 'ogg';
      case 'audio/opus':
        return 'opus';
      case 'audio/wav':
      case 'audio/x-wav':
      case 'audio/wave':
        return 'wav';
      default:
        return null;
    }
  }
}
