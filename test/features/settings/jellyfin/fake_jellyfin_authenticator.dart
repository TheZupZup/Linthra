import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_authenticator.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

/// A [JellyfinAuthenticator] stand-in that returns canned results (or throws)
/// and records its inputs, so the settings controller can be driven without a
/// client or network.
class FakeJellyfinAuthenticator implements JellyfinAuthenticator {
  FakeJellyfinAuthenticator({
    this.serverInfo,
    this.session,
    this.testError,
    this.signInError,
  });

  JellyfinServerInfo? serverInfo;
  JellyfinSession? session;
  JellyfinException? testError;
  JellyfinException? signInError;

  String? lastTestUrl;
  String? lastSignInUrl;
  String? lastUsername;
  String? lastPassword;
  JellyfinServerInfo? lastServerInfo;

  @override
  Future<JellyfinServerInfo> testConnection(String rawUrl) async {
    lastTestUrl = rawUrl;
    final JellyfinException? error = testError;
    if (error != null) {
      throw error;
    }
    return serverInfo ??
        const JellyfinServerInfo(serverName: 'My Server', version: '10.9.0');
  }

  @override
  Future<JellyfinSession> signIn({
    required String rawUrl,
    required String username,
    required String password,
    JellyfinServerInfo? serverInfo,
  }) async {
    lastSignInUrl = rawUrl;
    lastUsername = username;
    lastPassword = password;
    lastServerInfo = serverInfo;
    final JellyfinException? error = signInError;
    if (error != null) {
      throw error;
    }
    return session ??
        JellyfinSession(
          baseUrl: 'https://music.example.com',
          userId: 'user-1',
          accessToken: 'fake-token',
          deviceId: 'device-1',
          userName: username,
          serverName: serverInfo?.serverName,
          serverVersion: serverInfo?.version,
          productName: serverInfo?.productName,
        );
  }
}
