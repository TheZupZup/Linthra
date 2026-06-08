/// The category of a [SubsonicException].
///
/// Lets the UI react to the *kind* of failure (re-prompt for credentials on
/// [unauthorized], suggest checking the address on
/// [notReachable]/[notSubsonic]) without fragile matching on message text.
enum SubsonicErrorKind {
  /// The address the user typed isn't a usable http(s) URL.
  invalidUrl,

  /// The server couldn't be reached at all (DNS, connection refused, or
  /// timeout). Often a wrong address or an offline tunnel.
  notReachable,

  /// The platform blocked an insecure cleartext `http://` request (Android
  /// blocks cleartext by default on modern targets). Distinct from
  /// [notReachable] so the user is told to use `https://` rather than to
  /// "check the address".
  cleartextBlocked,

  /// The TLS handshake failed — typically a self-signed or otherwise untrusted
  /// certificate. Distinct from [notReachable] so the user knows the server was
  /// found but its certificate couldn't be verified.
  insecureConnection,

  /// The server answered but rejected the credentials (Subsonic error 40/41/44,
  /// or HTTP 401/403).
  unauthorized,

  /// Something answered, but it isn't a Subsonic-compatible server (non-Subsonic
  /// body, missing fields, or a reverse-proxy/Cloudflare error page).
  notSubsonic,

  /// The server reported a server-side error (HTTP 5xx, or a generic Subsonic
  /// error code).
  serverError,

  /// The requested item isn't available (a Subsonic "not found" error, code 70).
  streamUnavailable,

  /// The server answered with something Linthra can't classify or use.
  unsupportedResponse,

  /// Any other unexpected failure.
  unexpected,
}

/// The single typed error the Subsonic layer throws.
///
/// Mirrors [JellyfinException]: callers get a friendly, user-facing [message]
/// plus a [kind] to branch on, instead of a raw HTTP/socket failure or a
/// Subsonic error code.
///
/// Security invariant: a message must NEVER contain the password, the salt, or
/// the token. Do not add the request URL (which carries `t=`/`s=`) or any auth
/// query parameter to a message — the factories below intentionally carry only
/// a safe, generic explanation.
class SubsonicException implements Exception {
  const SubsonicException(
    this.message, {
    this.kind = SubsonicErrorKind.unexpected,
    this.statusCode,
  });

  /// The typed address-format failure. The caller supplies a specific reason
  /// since only it knows what was wrong with the input.
  const SubsonicException.invalidUrl(this.message)
      : kind = SubsonicErrorKind.invalidUrl,
        statusCode = null;

  factory SubsonicException.notReachable() => const SubsonicException(
        "Couldn't reach the server. Check the address and that you're online. "
        'If your server is behind a reverse proxy or Cloudflare, make sure it '
        'is running.',
        kind: SubsonicErrorKind.notReachable,
      );

  factory SubsonicException.cleartextBlocked() => const SubsonicException(
        'The insecure http:// connection to your server was blocked. Use an '
        'https:// address, or allow cleartext (http) access for a server on '
        'your local network.',
        kind: SubsonicErrorKind.cleartextBlocked,
      );

  factory SubsonicException.insecureConnection() => const SubsonicException(
        "Couldn't verify your server's security certificate. If it uses a "
        'self-signed certificate, put it behind a reverse proxy with a trusted '
        'certificate, or use http:// on a trusted local network.',
        kind: SubsonicErrorKind.insecureConnection,
      );

  factory SubsonicException.unauthorized() => const SubsonicException(
        'Your username or password was not accepted by the server.',
        kind: SubsonicErrorKind.unauthorized,
      );

  factory SubsonicException.notSubsonic() => const SubsonicException(
        "That address responded, but it doesn't look like a Subsonic-compatible "
        'server (such as Navidrome). Double-check the URL — point it at the '
        'server root, not a sub-page.',
        kind: SubsonicErrorKind.notSubsonic,
      );

  factory SubsonicException.serverError([int? statusCode]) => SubsonicException(
        'Your music server reported an error'
        '${statusCode != null ? ' (HTTP $statusCode)' : ''}. '
        'Try again in a moment.',
        kind: SubsonicErrorKind.serverError,
        statusCode: statusCode,
      );

  factory SubsonicException.streamUnavailable() => const SubsonicException(
        "This track isn't available from your server right now. "
        'It may have been moved or removed.',
        kind: SubsonicErrorKind.streamUnavailable,
      );

  factory SubsonicException.unsupportedResponse([int? statusCode]) =>
      SubsonicException(
        'Your music server returned a response Linthra could not use'
        '${statusCode != null ? ' (HTTP $statusCode)' : ''}. '
        'It may be running an unsupported version.',
        kind: SubsonicErrorKind.unsupportedResponse,
        statusCode: statusCode,
      );

  /// A user-facing explanation safe to show in the UI.
  final String message;

  /// What broadly went wrong, for the UI to branch on.
  final SubsonicErrorKind kind;

  /// The HTTP status code, when the failure came from a transport response.
  final int? statusCode;

  @override
  String toString() => message;
}
