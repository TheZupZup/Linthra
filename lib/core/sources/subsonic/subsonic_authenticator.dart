import '../../models/subsonic_session.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';
import 'subsonic_client.dart';
import 'subsonic_exception.dart';
import 'subsonic_server_url.dart';

/// Turns a raw address + credentials into a usable [SubsonicSession].
///
/// The "authentication" concern, kept separate from settings storage (the
/// `SubsonicSessionStore`) and from library fetching (the
/// `SubsonicMusicSource`): it validates the URL, derives the salt+token from
/// the password, and asks the [SubsonicClient] to ping. It does not persist
/// anything — the controller decides whether/where to store the session — so
/// this stays a pure coordinator that's trivial to test with a fake client.
///
/// By default the password is used only to compute the token (via
/// [SubsonicAuth]) and is never held, copied into the session, or logged. The
/// session carries only the derived (salt, token).
///
/// `useLegacy` is the opt-in for a server that refuses tokens (Nextcloud
/// Music): the session then carries the password itself, and only for an
/// https address. Anything else is refused before a request is made.
class SubsonicAuthenticator {
  SubsonicAuthenticator(
    this._client, {
    String Function()? saltGenerator,
  }) : _saltGenerator = saltGenerator;

  final SubsonicClient _client;

  /// Injectable so tests can assert a deterministic token; production uses a
  /// fresh secure-random salt per sign-in (the [SubsonicAuth] default).
  final String Function()? _saltGenerator;

  /// Validates [rawUrl] + credentials and confirms they reach a Subsonic server
  /// that accepts them, returning its info. Throws [SubsonicException] on a bad
  /// URL, unreachable/non-Subsonic server, or rejected credentials.
  ///
  /// Unlike Jellyfin's anonymous server-info probe, Subsonic's `ping` requires
  /// credentials, so a successful test also confirms sign-in will work.
  Future<SubsonicServerInfo> testConnection({
    required String rawUrl,
    required String username,
    required String password,
    bool useLegacy = false,
  }) async {
    final String baseUrl = SubsonicServerUrl.normalize(rawUrl);
    final String trimmedUsername = _requireUsername(username);
    _requirePassword(password);
    final SubsonicCredentials credentials =
        _credentials(baseUrl, password, useLegacy: useLegacy);
    return _client.ping(
      baseUrl,
      username: trimmedUsername,
      credentials: credentials,
    );
  }

  /// Signs in and returns a session that stores only the derived (salt, token),
  /// or with [useLegacy] the password, for an https server only.
  ///
  /// Throws [SubsonicException] for a bad URL, missing credentials, rejected
  /// credentials, or legacy sign-in on an address that isn't https.
  Future<SubsonicSession> signIn({
    required String rawUrl,
    required String username,
    required String password,
    bool useLegacy = false,
  }) async {
    final String baseUrl = SubsonicServerUrl.normalize(rawUrl);
    final String trimmedUsername = _requireUsername(username);
    _requirePassword(password);
    final SubsonicCredentials credentials =
        _credentials(baseUrl, password, useLegacy: useLegacy);

    final SubsonicServerInfo info = await _client.ping(
      baseUrl,
      username: trimmedUsername,
      credentials: credentials,
    );

    return SubsonicSession(
      baseUrl: baseUrl,
      username: trimmedUsername,
      salt: credentials.salt,
      token: credentials.token,
      password: useLegacy ? password : null,
      isLegacy: useLegacy,
      serverType: info.type,
      serverVersion: info.serverVersion,
      apiVersion: info.apiVersion,
    );
  }

  /// The salt + token for [password], or with [useLegacy] the password itself,
  /// which only an https [baseUrl] may receive.
  SubsonicCredentials _credentials(
    String baseUrl,
    String password, {
    required bool useLegacy,
  }) {
    if (!useLegacy) {
      return SubsonicAuth.credentials(password, saltGenerator: _saltGenerator);
    }
    if (!Uri.parse(baseUrl).isScheme('https')) {
      throw SubsonicException.legacyNeedsHttps();
    }
    return SubsonicCredentials.legacy(password);
  }

  String _requireUsername(String username) {
    final String trimmed = username.trim();
    if (trimmed.isEmpty) {
      throw const SubsonicException(
        'Enter your username.',
        kind: SubsonicErrorKind.unauthorized,
      );
    }
    return trimmed;
  }

  void _requirePassword(String password) {
    if (password.isEmpty) {
      throw const SubsonicException(
        'Enter your password.',
        kind: SubsonicErrorKind.unauthorized,
      );
    }
  }
}
