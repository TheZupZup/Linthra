/// An authenticated Subsonic/Navidrome session: everything needed to make
/// further authorized requests, kept in one immutable value so it can be
/// persisted as a unit and passed to the source.
///
/// Security — the token+salt model: Subsonic's modern auth sends, on every
/// request, `u=<user>&t=<token>&s=<salt>` where `token = md5(password + salt)`.
/// Linthra computes a single random [salt] and its [token] once at sign-in and
/// stores **only those**; the user's password is used to derive the token and
/// is then discarded, never persisted. That mirrors how [JellyfinSession]
/// stores a derived access token rather than the password. The (salt, token)
/// pair is a credential — it is persisted only through the `SubsonicSessionStore`
/// (the production binding is encrypted on-device) and must never be logged or
/// shown. [toString] redacts both so an accidental interpolation can't leak it.
///
/// Supports both modern token-based auth (salt + token) and legacy plaintext
/// password auth (for Nextcloud Music via `isLegacy` and `password`).
class SubsonicSession {
  const SubsonicSession({
    required this.baseUrl,
    required this.username,
    this.salt,
    this.token,
    this.password,
    this.isLegacy = false,
    this.serverType,
    this.serverVersion,
    this.apiVersion,
  });

  /// Clean base URL of the server (no trailing slash), e.g.
  /// `https://music.example.com`. The `/rest/*.view` API paths append to this.
  final String baseUrl;

  /// The authenticated user's name. Sent on every request as `u=`.
  final String username;

  /// The per-session random salt sent as `s=` (null in legacy mode). Not a secret on its own, but is
  /// half of the credential, so it is treated as sensitive and redacted in
  /// [toString].
  final String? salt;

  /// `md5(password + salt)`, sent as `t=` (null in legacy mode). Never log this.
  final String? token;

  /// The raw password sent as `p=` in legacy mode. Never log this.
  final String? password;

  /// Flag indicating whether this session uses legacy plaintext authentication.
  final bool isLegacy;

  /// The server product, when reported (OpenSubsonic `type`, e.g. `navidrome`).
  /// Display/diagnostics only.
  final String? serverType;

  /// The server's own version (OpenSubsonic `serverVersion`), when reported.
  /// Display/diagnostics only.
  final String? serverVersion;

  /// The Subsonic API version the server reported (`version`), when known.
  /// Display/diagnostics only.
  final String? apiVersion;

  SubsonicSession copyWith({
    String? baseUrl,
    String? username,
    String? salt,
    String? token,
    String? password,
    bool? isLegacy,
    String? serverType,
    String? serverVersion,
    String? apiVersion,
  }) {
    return SubsonicSession(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      salt: salt ?? this.salt,
      token: token ?? this.token,
      password: password ?? this.password,
      isLegacy: isLegacy ?? this.isLegacy,
      serverType: serverType ?? this.serverType,
      serverVersion: serverVersion ?? this.serverVersion,
      apiVersion: apiVersion ?? this.apiVersion,
    );
  }

  /// Serializes for the encrypted secure store. Credentials (tokens or legacy password)
  /// are included safely since the store is encrypted on-device.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'username': username,
        if (salt != null) 'salt': salt,
        if (token != null) 'token': token,
        if (password != null) 'password': password,
        'isLegacy': isLegacy,
        if (serverType != null) 'serverType': serverType,
        if (serverVersion != null) 'serverVersion': serverVersion,
        if (apiVersion != null) 'apiVersion': apiVersion,
      };

  /// Rebuilds a session from [toJson] output, or returns `null` if any required
  /// field is missing/blank. Branches validation based on [isLegacy].
  static SubsonicSession? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = json['baseUrl'] as String?;
    final String? username = json['username'] as String?;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    if (username == null || username.isEmpty) return null;

    final bool isLegacy = json['isLegacy'] as bool? ?? false;

    if (isLegacy) {
      final String? password = json['password'] as String?;
      if (password == null || password.isEmpty) return null;
      return SubsonicSession(
        baseUrl: baseUrl,
        username: username,
        password: password,
        isLegacy: true,
        serverType: json['serverType'] as String?,
        serverVersion: json['serverVersion'] as String?,
        apiVersion: json['apiVersion'] as String?,
      );
    } else {
      final String? salt = json['salt'] as String?;
      final String? token = json['token'] as String?;
      if (salt == null || salt.isEmpty) return null;
      if (token == null || token.isEmpty) return null;
      return SubsonicSession(
        baseUrl: baseUrl,
        username: username,
        salt: salt,
        token: token,
        isLegacy: false,
        serverType: json['serverType'] as String?,
        serverVersion: json['serverVersion'] as String?,
        apiVersion: json['apiVersion'] as String?,
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubsonicSession &&
          other.baseUrl == baseUrl &&
          other.username == username &&
          other.salt == salt &&
          other.token == token &&
          other.password == password &&
          other.isLegacy == isLegacy &&
          other.serverType == serverType &&
          other.serverVersion == serverVersion &&
          other.apiVersion == apiVersion);

  @override
  int get hashCode => Object.hash(
        baseUrl,
        username,
        salt,
        token,
        password,
        isLegacy,
        serverType,
        serverVersion,
        apiVersion,
      );

  /// Redacts sensitive credentials (salt, token, password) so the session can
  /// be safely interpolated into logs or error messages.
  @override
  String toString() => 'SubsonicSession(baseUrl: $baseUrl, '
      'username: $username, isLegacy: $isLegacy, serverType: $serverType, '
      'serverVersion: $serverVersion, apiVersion: $apiVersion, '
      'salt: <redacted>, token: <redacted>, password: <redacted>)';
}
