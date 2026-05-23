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
  });

  JellyfinServerInfo? serverInfo;
  JellyfinAuthResult? authResult;
  Map<JellyfinItemKind, List<JellyfinItemDto>> itemsByKind;
  JellyfinException? serverInfoError;
  JellyfinException? authError;
  JellyfinException? itemsError;

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  String? lastPassword;
  String? lastDeviceId;
  final List<JellyfinItemKind> requestedKinds = <JellyfinItemKind>[];

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
}
