/// The category of a [JellyfinException].
///
/// Lets the UI react to the *kind* of failure (re-prompt for credentials on
/// [unauthorized], suggest checking the address on [notReachable]/[notJellyfin])
/// without fragile matching on message text.
enum JellyfinErrorKind {
  /// The address the user typed isn't a usable http(s) URL.
  invalidUrl,

  /// The server couldn't be reached at all (DNS, connection refused, TLS
  /// handshake, or timeout). Often a wrong address or an offline tunnel.
  notReachable,

  /// The server answered but rejected the credentials (HTTP 401/403).
  unauthorized,

  /// Something answered, but it isn't a Jellyfin server (non-JSON body, missing
  /// fields, or a Cloudflare/reverse-proxy error page).
  notJellyfin,

  /// The Jellyfin server reported a server-side error (HTTP 5xx).
  serverError,

  /// Any other unexpected failure.
  unexpected,
}

/// The single typed error the Jellyfin layer throws.
///
/// Mirrors how local scanning surfaces one [FolderScanException]: callers get a
/// friendly, user-facing [message] plus a [kind] to branch on, instead of a raw
/// HTTP/socket failure.
///
/// Security invariant: a message must NEVER contain the password or access
/// token. Do not add the request body or the `Authorization` header to any
/// message here — the factories below intentionally carry only a status code
/// and a generic, safe explanation.
class JellyfinException implements Exception {
  const JellyfinException(
    this.message, {
    this.kind = JellyfinErrorKind.unexpected,
    this.statusCode,
  });

  /// The typed address-format failure. The caller supplies a specific reason
  /// (what was wrong with the input) since only it knows the context.
  const JellyfinException.invalidUrl(this.message)
      : kind = JellyfinErrorKind.invalidUrl,
        statusCode = null;

  factory JellyfinException.notReachable() => const JellyfinException(
        "Couldn't reach the server. Check the address and that you're online. "
        'If your server is behind Cloudflare, make sure the tunnel is running.',
        kind: JellyfinErrorKind.notReachable,
      );

  factory JellyfinException.unauthorized() => const JellyfinException(
        'Your username or password was not accepted by the server.',
        kind: JellyfinErrorKind.unauthorized,
        statusCode: 401,
      );

  factory JellyfinException.notJellyfin() => const JellyfinException(
        "That address responded, but it doesn't look like a Jellyfin server. "
        'Double-check the URL — if you use Cloudflare, confirm the domain '
        'points to your Jellyfin instance.',
        kind: JellyfinErrorKind.notJellyfin,
      );

  factory JellyfinException.serverError(int statusCode) => JellyfinException(
        'The Jellyfin server reported an error (HTTP $statusCode). '
        'Try again in a moment.',
        kind: JellyfinErrorKind.serverError,
        statusCode: statusCode,
      );

  factory JellyfinException.unexpected(int statusCode) => JellyfinException(
        'Unexpected response from the server (HTTP $statusCode).',
        kind: JellyfinErrorKind.unexpected,
        statusCode: statusCode,
      );

  /// A user-facing explanation safe to show in the UI.
  final String message;

  /// What broadly went wrong, for the UI to branch on.
  final JellyfinErrorKind kind;

  /// The HTTP status code, when the failure came from a response.
  final int? statusCode;

  @override
  String toString() => message;
}
