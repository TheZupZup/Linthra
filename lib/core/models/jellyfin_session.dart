/// An authenticated Jellyfin session: everything needed to make further
/// authorized requests, kept in one immutable value so it can be persisted as a
/// unit and passed to the source.
///
/// Security: [accessToken] is a secret. It is persisted only through the
/// `JellyfinSessionStore` (the production binding is encrypted on-device) and
/// must never be logged or shown in the UI. [toString] deliberately redacts it
/// so an accidental interpolation can't leak it into logs or error text.
///
/// The user's password is *not* part of a session and is never stored — it is
/// used once to obtain [accessToken] and then discarded.
class JellyfinSession {
  const JellyfinSession({
    required this.baseUrl,
    required this.userId,
    required this.accessToken,
    required this.deviceId,
    this.userName,
    this.serverId,
    this.serverName,
    this.serverVersion,
    this.productName,
  });

  /// Clean base URL of the server (no trailing slash), e.g.
  /// `https://music.example.com`. API paths are appended to this.
  final String baseUrl;

  /// The authenticated user's Jellyfin id.
  final String userId;

  /// Secret bearer token for the `Authorization` header. Never log this.
  final String accessToken;

  /// The id this client identified itself with at sign-in. Reused on every
  /// later request so the server sees one stable device per install.
  final String deviceId;

  /// Display name of the signed-in user, when the server returned one.
  final String? userName;

  /// The server's id, when known. Useful later for distinguishing multiple
  /// servers.
  final String? serverId;

  /// The server's friendly name, when known (from the connection test). Display
  /// only.
  final String? serverName;

  /// The server's reported version (e.g. `10.9.11`), when known. Carried so the
  /// diagnostics report can show it after a restart. Not secret, display only.
  final String? serverVersion;

  /// The server's product name (e.g. `Jellyfin Server`), when reported. Not
  /// secret, display/diagnostics only.
  final String? productName;

  JellyfinSession copyWith({
    String? baseUrl,
    String? userId,
    String? accessToken,
    String? deviceId,
    String? userName,
    String? serverId,
    String? serverName,
    String? serverVersion,
    String? productName,
  }) {
    return JellyfinSession(
      baseUrl: baseUrl ?? this.baseUrl,
      userId: userId ?? this.userId,
      accessToken: accessToken ?? this.accessToken,
      deviceId: deviceId ?? this.deviceId,
      userName: userName ?? this.userName,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      serverVersion: serverVersion ?? this.serverVersion,
      productName: productName ?? this.productName,
    );
  }

  /// Serializes for the session store. The token is included because the only
  /// caller is the (encrypted) store; do not route this through any plaintext
  /// sink.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'userId': userId,
        'accessToken': accessToken,
        'deviceId': deviceId,
        if (userName != null) 'userName': userName,
        if (serverId != null) 'serverId': serverId,
        if (serverName != null) 'serverName': serverName,
        if (serverVersion != null) 'serverVersion': serverVersion,
        if (productName != null) 'productName': productName,
      };

  /// Rebuilds a session from [toJson] output, or returns `null` if any required
  /// field is missing/blank (e.g. a partially written or corrupted record), so
  /// the app treats it as "not signed in" rather than crashing.
  static JellyfinSession? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = json['baseUrl'] as String?;
    final String? userId = json['userId'] as String?;
    final String? accessToken = json['accessToken'] as String?;
    final String? deviceId = json['deviceId'] as String?;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    if (userId == null || userId.isEmpty) return null;
    if (accessToken == null || accessToken.isEmpty) return null;
    if (deviceId == null || deviceId.isEmpty) return null;
    return JellyfinSession(
      baseUrl: baseUrl,
      userId: userId,
      accessToken: accessToken,
      deviceId: deviceId,
      userName: json['userName'] as String?,
      serverId: json['serverId'] as String?,
      serverName: json['serverName'] as String?,
      serverVersion: json['serverVersion'] as String?,
      productName: json['productName'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JellyfinSession &&
          other.baseUrl == baseUrl &&
          other.userId == userId &&
          other.accessToken == accessToken &&
          other.deviceId == deviceId &&
          other.userName == userName &&
          other.serverId == serverId &&
          other.serverName == serverName &&
          other.serverVersion == serverVersion &&
          other.productName == productName);

  @override
  int get hashCode => Object.hash(
        baseUrl,
        userId,
        accessToken,
        deviceId,
        userName,
        serverId,
        serverName,
        serverVersion,
        productName,
      );

  /// Redacts the token so the session can be safely interpolated into logs or
  /// error messages without leaking the secret.
  @override
  String toString() => 'JellyfinSession(baseUrl: $baseUrl, userId: $userId, '
      'userName: $userName, serverId: $serverId, serverName: $serverName, '
      'serverVersion: $serverVersion, productName: $productName, '
      'deviceId: $deviceId, accessToken: <redacted>)';
}
