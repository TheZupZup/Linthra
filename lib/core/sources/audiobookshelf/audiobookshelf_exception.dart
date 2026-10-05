/// The category of an [AudiobookshelfException].
///
/// Lets the UI react to the *kind* of failure (re-prompt for credentials on
/// [unauthorized], suggest checking the address on [notReachable]/
/// [notAudiobookshelf]) without fragile matching on message text.
enum AudiobookshelfErrorKind {
  /// The address the user typed isn't a usable http(s) URL.
  invalidUrl,

  /// The server couldn't be reached at all (DNS, connection refused, TLS
  /// handshake, or timeout). Often a wrong address or an offline tunnel.
  notReachable,

  /// The server answered but rejected the credentials (HTTP 401/403).
  unauthorized,

  /// Something answered, but it isn't an Audiobookshelf server (non-JSON
  /// body, missing fields, or a Cloudflare/reverse-proxy error page).
  notAudiobookshelf,

  /// The Audiobookshelf server reported a server-side error (HTTP 5xx).
  serverError,

  /// Any other unexpected failure.
  unexpected,
}

/// The single typed error the Audiobookshelf layer throws.
///
/// Mirrors how the Jellyfin/Subsonic/Plex layers each surface one typed
/// exception: callers get a friendly, user-facing [message] plus a [kind] to
/// branch on, instead of a raw HTTP/socket failure.
///
/// Security invariant: a message must NEVER contain the password or an
/// access/refresh token. Do not add the request body or the `Authorization`
/// header to any message here — the factories below intentionally carry only
/// a status code and a generic, safe explanation.
class AudiobookshelfException implements Exception {
  const AudiobookshelfException(
    this.message, {
    this.kind = AudiobookshelfErrorKind.unexpected,
    this.statusCode,
  });

  /// The typed address-format failure. The caller supplies a specific reason
  /// (what was wrong with the input) since only it knows the context.
  const AudiobookshelfException.invalidUrl(this.message)
      : kind = AudiobookshelfErrorKind.invalidUrl,
        statusCode = null;

  factory AudiobookshelfException.notReachable() =>
      const AudiobookshelfException(
        "Couldn't reach the server. Check the address and that you're "
        'online.',
        kind: AudiobookshelfErrorKind.notReachable,
      );

  factory AudiobookshelfException.unauthorized() =>
      const AudiobookshelfException(
        'Your username or password was not accepted by the server.',
        kind: AudiobookshelfErrorKind.unauthorized,
        statusCode: 401,
      );

  factory AudiobookshelfException.notAudiobookshelf() =>
      const AudiobookshelfException(
        "That address responded, but it doesn't look like an Audiobookshelf "
        'server. Double-check the URL.',
        kind: AudiobookshelfErrorKind.notAudiobookshelf,
      );

  factory AudiobookshelfException.serverError(int statusCode) =>
      AudiobookshelfException(
        'The Audiobookshelf server reported an error (HTTP $statusCode). '
        'Try again in a moment.',
        kind: AudiobookshelfErrorKind.serverError,
        statusCode: statusCode,
      );

  factory AudiobookshelfException.unsupportedResponse() =>
      const AudiobookshelfException(
        'Your Audiobookshelf server returned a response Linthra could not '
        'use. It may be running an unsupported version.',
        kind: AudiobookshelfErrorKind.unexpected,
      );

  /// A user-facing explanation safe to show in the UI.
  final String message;

  /// What broadly went wrong, for the UI to branch on.
  final AudiobookshelfErrorKind kind;

  /// The HTTP status code, when the failure came from a response.
  final int? statusCode;

  @override
  String toString() => message;
}
