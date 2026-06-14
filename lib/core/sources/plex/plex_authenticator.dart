import '../../models/plex_session.dart';
import 'plex_api.dart';
import 'plex_client.dart';
import 'plex_exception.dart';
import 'plex_server_url.dart';

/// Turns a manually typed server URL + token into a usable [PlexSession].
///
/// The "authentication" concern for the **manual / advanced** flow, kept
/// separate from session storage (the `PlexSessionStore`) and from library
/// fetching (the `PlexMusicSource`): it normalizes the URL and asks the
/// [PlexClient] to confirm the address is a reachable Plex Media Server that
/// accepts the token, via `GET /identity`. It does not persist anything — the
/// controller decides whether/where to store the session — so this stays a
/// pure coordinator that's trivial to test with a fake client.
///
/// Token safety: the token is only trimmed, handed to the client (which sends it
/// as the `X-Plex-Token` **header** — never a logged URL), and copied into the
/// returned session (whose [PlexSession.toString] redacts it). It is never
/// logged, and the client's [PlexException]s are static and token-free, so a
/// failure on any path can't leak it. The session stores only the token (prefer a
/// server-scoped one) plus the server metadata; it never holds a stream/art URL.
/// See docs/plex.md → Authentication / Token safety rules.
///
/// The primary "Connect with Plex" path is the plex.tv PIN sign-in
/// (`PlexPinAuth`); this manual flow stays as the advanced fallback for users
/// who already have a token (and for dev setups).
class PlexAuthenticator {
  PlexAuthenticator(this._client);

  final PlexClient _client;

  /// Validates [rawUrl] + [token] and confirms they reach a Plex Media Server
  /// that accepts them, returning its identity. Throws [PlexException] on a bad
  /// URL, a missing token, an unreachable/non-Plex server, or a rejected token.
  ///
  /// Backs a future "Test connection" button. Like Subsonic's credentialed ping
  /// (and unlike Jellyfin's anonymous probe), the token is sent on the check, so
  /// a success also confirms sign-in will work.
  Future<PlexServerIdentity> testConnection({
    required String rawUrl,
    required String token,
  }) async {
    final String baseUrl = PlexServerUrl.normalize(rawUrl);
    final String trimmedToken = _requireToken(token);
    return _client.fetchIdentity(baseUrl: baseUrl, token: trimmedToken);
  }

  /// Verifies the server and returns a session that stores **only** the token
  /// (prefer a server-scoped one) plus the server metadata needed to reach it.
  /// The session starts with **no** selected library sections (the library
  /// picker fills [PlexSession.selectedSectionKeys] later) and no server name
  /// (`/identity` doesn't report one).
  ///
  /// Throws [PlexException] for a bad URL, a missing token, an unreachable/
  /// non-Plex server, or a rejected token.
  Future<PlexSession> signIn({
    required String rawUrl,
    required String token,
  }) async {
    final String baseUrl = PlexServerUrl.normalize(rawUrl);
    final String trimmedToken = _requireToken(token);

    final PlexServerIdentity identity =
        await _client.fetchIdentity(baseUrl: baseUrl, token: trimmedToken);

    return PlexSession(
      baseUrl: baseUrl,
      token: trimmedToken,
      machineIdentifier: identity.machineIdentifier,
      serverVersion: identity.version,
    );
  }

  /// Trims a pasted token and rejects an empty one before any network call. A
  /// real `X-Plex-Token` carries no surrounding whitespace, so trimming only
  /// removes copy-paste slips; the value is otherwise untouched.
  String _requireToken(String token) {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const PlexException(
        'Enter your Plex token.',
        kind: PlexErrorKind.unauthorized,
      );
    }
    return trimmed;
  }
}
