import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

/// A configurable [JellyfinClient] that returns canned responses (or throws)
/// and records what it was asked, so the source/authenticator can be tested
/// without a real server or HTTP.
class FakeJellyfinClient implements JellyfinClient {
  FakeJellyfinClient({
    this.serverInfo,
    this.authResult,
    this.itemsByKind = const <JellyfinItemKind, List<JellyfinItemDto>>{},
    this.serverInfoError,
    this.authError,
    this.itemsError,
    this.verifyError,
    this.streamProbe,
    this.probeError,
  });

  JellyfinServerInfo? serverInfo;
  JellyfinAuthResult? authResult;
  Map<JellyfinItemKind, List<JellyfinItemDto>> itemsByKind;
  JellyfinException? serverInfoError;
  JellyfinException? authError;
  JellyfinException? itemsError;
  JellyfinException? verifyError;

  /// Canned result for [probeStream]; defaults to a healthy `audio/mpeg` 200 so
  /// tests that only care about the minted URL don't have to set it.
  JellyfinStreamProbe? streamProbe;

  /// A transport failure for [probeStream] to throw instead of returning.
  JellyfinException? probeError;

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  String? lastPassword;
  String? lastDeviceId;
  final List<JellyfinItemKind> requestedKinds = <JellyfinItemKind>[];
  int verifyCount = 0;

  /// The last URL [probeStream] was asked about, so a test can prove the probe
  /// ran against the minted stream URL.
  Uri? lastProbedUrl;

  @override
  Future<JellyfinServerInfo> fetchServerInfo(String baseUrl) async {
    lastBaseUrl = baseUrl;
    final JellyfinException? error = serverInfoError;
    if (error != null) {
      throw error;
    }
    return serverInfo ??
        const JellyfinServerInfo(serverName: 'Test Server', version: '10.9.0');
  }

  @override
  Future<JellyfinAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    lastBaseUrl = baseUrl;
    lastUsername = username;
    lastPassword = password;
    lastDeviceId = deviceId;
    final JellyfinException? error = authError;
    if (error != null) {
      throw error;
    }
    return authResult ??
        JellyfinAuthResult(
          accessToken: 'fake-token',
          userId: 'user-1',
          userName: username,
          serverId: 'server-1',
        );
  }

  @override
  Future<List<JellyfinItemDto>> fetchItems(
    JellyfinSession session, {
    required JellyfinItemKind kind,
  }) async {
    requestedKinds.add(kind);
    final JellyfinException? error = itemsError;
    if (error != null) {
      throw error;
    }
    return itemsByKind[kind] ?? const <JellyfinItemDto>[];
  }

  @override
  Future<void> verifySession(JellyfinSession session) async {
    verifyCount++;
    final JellyfinException? error = verifyError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<JellyfinStreamProbe> probeStream(Uri url) async {
    lastProbedUrl = url;
    final JellyfinException? error = probeError;
    if (error != null) {
      throw error;
    }
    return streamProbe ??
        const JellyfinStreamProbe(statusCode: 200, contentType: 'audio/mpeg');
  }
}
