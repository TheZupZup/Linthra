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
/// The password is used only to compute the token (via [SubsonicAuth]) and is
/// never held, copied into the session, or logged. The session carries only the
/// derived (salt, token).
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
  }) async {
    final String baseUrl = SubsonicServerUrl.normalize(rawUrl);
    final String trimmedUsername = _requireUsername(username);
    _requirePassword(password);
    final SubsonicCredentials credentials =
        SubsonicAuth.credentials(password, saltGenerator: _saltGenerator);
    return _client.ping(
      baseUrl,
      username: trimmedUsername,
      credentials: credentials,
    );
  }

  /// Signs in and returns a session that stores only the derived (salt, token).
  ///
  /// Throws [SubsonicException] for a bad URL, missing credentials, or rejected
  /// credentials.
  Future<SubsonicSession> signIn({
    required String rawUrl,
    required String username,
    required String password,
  }) async {
    final String baseUrl = SubsonicServerUrl.normalize(rawUrl);
    final String trimmedUsername = _requireUsername(username);
    _requirePassword(password);
    final SubsonicCredentials credentials =
        SubsonicAuth.credentials(password, saltGenerator: _saltGenerator);

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
      serverType: info.type,
      serverVersion: info.serverVersion,
      apiVersion: info.apiVersion,
    );
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
