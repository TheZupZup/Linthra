/// Tells a server's error or login page apart from a media file by the
/// response `Content-Type`.
///
/// Shared by the remote downloaders (Jellyfin, Plex, Subsonic). A server can
/// refuse a download with a 2xx and a document in place of the file: Subsonic's
/// `download.view` answers HTTP 200 with a `subsonic-response` error in JSON or
/// XML, and a reverse-proxy/SSO login page is a 200 `text/html` for any
/// provider. Cached as the track, that body would be served ahead of the stream
/// and fail every play, so a downloader refuses it on this check.
///
/// Deliberately a deny-list of document types: servers label media
/// inconsistently (`application/octet-stream`, `binary/octet-stream`,
/// `application/ogg`, or no type at all) and the audio engine sniffs the
/// container, so anything that isn't plainly a document is kept. Mirrors the
/// cast relay's check in `LocalCastMediaProxy`.
abstract final class MediaContentType {
  /// Whether [contentType] names a document (any `text/*`, or JSON/XML such as
  /// `application/json`, `application/xhtml+xml`, `application/problem+json`)
  /// rather than media. Parameters and case are ignored; a missing, empty, or
  /// unrecognized type is not a document.
  static bool isDocument(String? contentType) {
    if (contentType == null) return false;
    final String type = contentType.split(';').first.trim().toLowerCase();
    if (type.startsWith('text/')) return true;
    if (!type.startsWith('application/')) return false;
    final String subtype = type.substring('application/'.length);
    return subtype == 'json' ||
        subtype == 'xml' ||
        subtype.endsWith('+json') ||
        subtype.endsWith('+xml');
  }
}
