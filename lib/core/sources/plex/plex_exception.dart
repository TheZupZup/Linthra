/// The category of a [PlexException].
///
/// Lets the UI react to the *kind* of failure (re-prompt for the token on
/// [unauthorized], suggest checking the address on [notReachable]/[notPlex])
/// without fragile matching on message text. Mirrors [JellyfinException] /
/// [SubsonicException].
enum PlexErrorKind {
  /// The address the user typed isn't a usable http(s) URL.
  invalidUrl,

  /// The server couldn't be reached at all (DNS, connection refused, TLS
  /// handshake, or timeout). Often a wrong address or an offline tunnel.
  notReachable,

  /// The server answered but rejected the token (HTTP 401/403). A Plex server
  /// returns these when the `X-Plex-Token` is missing, wrong, or not scoped to
  /// the requested library.
  unauthorized,

  /// Something answered, but it isn't a Plex Media Server we can use: a non-JSON
  /// body (Plex defaults to **XML** and only returns JSON for
  /// `Accept: application/json` — an older server or proxy may still send XML or
  /// an HTML error page), or a 2xx JSON body with **no `MediaContainer`**
  /// envelope (so it isn't a recognisable Plex response).
  notPlex,

  /// The Plex server reported a server-side error (HTTP 5xx).
  serverError,

  /// The requested item isn't available (HTTP 404) — e.g. a `ratingKey` that no
  /// longer exists, or a library the token can't reach.
  notFound,

  /// The server answered with a 2xx Plex envelope Linthra can't use — a shape an
  /// older/newer server returned that this version doesn't understand (e.g. a
  /// metadata lookup whose `MediaContainer` carried no item).
  unsupportedResponse,

  /// Any other unexpected failure.
  unexpected,
}

/// The single typed error the Plex layer throws.
///
/// Callers get a friendly, user-facing [message] plus a [kind] to branch on,
/// instead of a raw HTTP/socket failure — exactly like [JellyfinException] and
/// [SubsonicException].
///
/// **Security invariant — the token must NEVER reach a message.** A Plex
/// `X-Plex-Token` rides in an `X-Plex-Token` *header* for API calls and in a
/// *query param* for stream/art URLs, so a single leaked URL or error string
/// would expose the whole token. The factories below intentionally carry only a
/// status code and a generic, safe explanation — never the request URL, a
/// header, or a response body. See docs/plex.md → Token safety rules.
class PlexException implements Exception {
  const PlexException(
    this.message, {
    this.kind = PlexErrorKind.unexpected,
    this.statusCode,
  });

  /// The typed address-format failure. The caller supplies a specific reason
  /// (what was wrong with the input) since only it knows the context.
  const PlexException.invalidUrl(this.message)
      : kind = PlexErrorKind.invalidUrl,
        statusCode = null;

  factory PlexException.notReachable() => const PlexException(
        "Couldn't reach your Plex server. Check the address and that you're "
        'online. If your server is behind a reverse proxy or tunnel, make sure '
        'it is running.',
        kind: PlexErrorKind.notReachable,
      );

  factory PlexException.unauthorized() => const PlexException(
        'Your Plex token was not accepted by the server. Check that the token '
        'is correct and still valid.',
        kind: PlexErrorKind.unauthorized,
        statusCode: 401,
      );

  factory PlexException.notPlex() => const PlexException(
        "That address responded, but it doesn't look like a Plex Media Server. "
        'Double-check the URL — point it at the server root (Plex normally '
        'listens on port 32400).',
        kind: PlexErrorKind.notPlex,
      );

  factory PlexException.serverError(int statusCode) => PlexException(
        'Your Plex server reported an error (HTTP $statusCode). '
        'Try again in a moment.',
        kind: PlexErrorKind.serverError,
        statusCode: statusCode,
      );

  factory PlexException.notFound() => const PlexException(
        "This item isn't available from your Plex server right now. "
        'It may have been moved or removed.',
        kind: PlexErrorKind.notFound,
        statusCode: 404,
      );

  factory PlexException.unsupportedResponse([int? statusCode]) => PlexException(
        'Your Plex server returned a response Linthra could not use'
        '${statusCode != null ? ' (HTTP $statusCode)' : ''}. '
        'It may be running an unsupported version.',
        kind: PlexErrorKind.unsupportedResponse,
        statusCode: statusCode,
      );

  factory PlexException.unexpected(int statusCode) => PlexException(
        'Unexpected response from your Plex server (HTTP $statusCode).',
        kind: PlexErrorKind.unexpected,
        statusCode: statusCode,
      );

  /// A user-facing explanation safe to show in the UI — never carries the token.
  final String message;

  /// What broadly went wrong, for the UI to branch on.
  final PlexErrorKind kind;

  /// The HTTP status code, when the failure came from a response.
  final int? statusCode;

  @override
  String toString() => message;
}
