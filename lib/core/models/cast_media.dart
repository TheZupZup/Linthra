/// A track resolved into something a cast receiver (e.g. a Chromecast) can
/// fetch and play. The receiver pulls the bytes itself over the network, so
/// [url] must be a reachable `http`/`https` URL — never a `file://` path, which
/// is why on-device files cannot be cast.
///
/// Security: [url] may embed a short-lived access token in its query (a
/// Jellyfin stream URL does). It is resolved on demand at cast time, handed
/// straight to the cast session, and never persisted. [toString] redacts the
/// query and any userinfo so the URL cannot leak into a log or error message —
/// only the host and path survive, mirroring how [JellyfinSession] redacts its
/// token.
class CastMedia {
  const CastMedia({
    required this.url,
    required this.contentType,
    this.title,
    this.artist,
    this.album,
    this.artworkUrl,
  });

  /// The reachable media URL the receiver fetches. May carry an access token in
  /// its query; treat as a secret (see the class doc).
  final Uri url;

  /// The MIME type hint sent to the receiver (e.g. `audio/mpeg`). The receiver
  /// uses it to pick a decoder.
  final String contentType;

  final String? title;
  final String? artist;
  final String? album;

  /// A token-free artwork URL for the receiver to show while playing, or null.
  /// Jellyfin's primary-image URL needs no auth, so it is safe to send as-is.
  final Uri? artworkUrl;

  /// Redacts the secret-bearing [url] down to scheme/host/path so the media can
  /// be safely interpolated into a log or error without leaking the token.
  Uri get _safeUrl => Uri(
      scheme: url.scheme,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: url.path);

  @override
  String toString() =>
      'CastMedia(url: $_safeUrl, contentType: $contentType, title: $title)';
}
