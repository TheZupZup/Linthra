import 'dart:math';

import '../../models/jellyfin_session.dart';
import 'jellyfin_api.dart';
import 'jellyfin_client.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_server_url.dart';

/// Turns a raw address + credentials into a usable [JellyfinSession].
///
/// This is the "authentication" concern, kept separate from settings storage
/// (the `JellyfinSessionStore`) and from library fetching (the
/// `JellyfinMusicSource`): it validates the URL, mints a stable device id, and
/// asks the [JellyfinClient] to authenticate. It does not persist anything —
/// the controller decides whether/where to store the session — so this stays a
/// pure coordinator that's trivial to test with a fake client.
///
/// The password is passed straight through to the one auth call and is never
/// held, copied into the session, or logged.
class JellyfinAuthenticator {
  JellyfinAuthenticator(
    this._client, {
    String Function()? deviceIdGenerator,
  }) : _deviceIdGenerator = deviceIdGenerator ?? _randomDeviceId;

  final JellyfinClient _client;

  /// Injectable so tests can assert a fixed device id; production uses a secure
  /// random one per sign-in.
  final String Function() _deviceIdGenerator;

  /// Validates [rawUrl] and confirms it points at a Jellyfin server, returning
  /// its public info. Throws [JellyfinException] on a bad URL or unreachable /
  /// non-Jellyfin server.
  Future<JellyfinServerInfo> testConnection(String rawUrl) async {
    final String baseUrl = JellyfinServerUrl.normalize(rawUrl);
    return _client.fetchServerInfo(baseUrl);
  }

  /// Signs in and returns a session. [serverName], when known from a prior
  /// [testConnection], is carried into the session for display only.
  ///
  /// Throws [JellyfinException] for a bad URL, missing username, or rejected
  /// credentials.
  Future<JellyfinSession> signIn({
    required String rawUrl,
    required String username,
    required String password,
    String? serverName,
  }) async {
    final String baseUrl = JellyfinServerUrl.normalize(rawUrl);
    final String trimmedUsername = username.trim();
    if (trimmedUsername.isEmpty) {
      throw const JellyfinException(
        'Enter your Jellyfin username.',
        kind: JellyfinErrorKind.unauthorized,
      );
    }

    final String deviceId = _deviceIdGenerator();
    final JellyfinAuthResult result = await _client.authenticateByName(
      baseUrl: baseUrl,
      username: trimmedUsername,
      password: password,
      deviceId: deviceId,
    );

    return JellyfinSession(
      baseUrl: baseUrl,
      userId: result.userId,
      accessToken: result.accessToken,
      deviceId: deviceId,
      userName: result.userName ?? trimmedUsername,
      serverId: result.serverId,
      serverName: serverName,
    );
  }

  static String _randomDeviceId() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
