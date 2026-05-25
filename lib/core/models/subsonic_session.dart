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
class SubsonicSession {
  const SubsonicSession({
    required this.baseUrl,
    required this.username,
    required this.salt,
    required this.token,
    this.serverType,
    this.serverVersion,
    this.apiVersion,
  });

  /// Clean base URL of the server (no trailing slash), e.g.
  /// `https://music.example.com`. The `/rest/*.view` API paths append to this.
  final String baseUrl;

  /// The authenticated user's name. Sent on every request as `u=`.
  final String username;

  /// The per-session random salt sent as `s=`. Not a secret on its own, but is
  /// half of the credential, so it is treated as sensitive and redacted in
  /// [toString].
  final String salt;

  /// `md5(password + salt)`, sent as `t=`. The secret — never log this. The
  /// password it was derived from is never stored.
  final String token;

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
    String? serverType,
    String? serverVersion,
    String? apiVersion,
  }) {
    return SubsonicSession(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      salt: salt ?? this.salt,
      token: token ?? this.token,
      serverType: serverType ?? this.serverType,
      serverVersion: serverVersion ?? this.serverVersion,
      apiVersion: apiVersion ?? this.apiVersion,
    );
  }

  /// Serializes for the session store. The salt and token are included because
  /// the only caller is the (encrypted) store; do not route this through any
  /// plaintext sink.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'username': username,
        'salt': salt,
        'token': token,
        if (serverType != null) 'serverType': serverType,
        if (serverVersion != null) 'serverVersion': serverVersion,
        if (apiVersion != null) 'apiVersion': apiVersion,
      };

  /// Rebuilds a session from [toJson] output, or returns `null` if any required
  /// field is missing/blank (e.g. a partially written or corrupted record), so
  /// the app treats it as "not signed in" rather than crashing.
  static SubsonicSession? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = json['baseUrl'] as String?;
    final String? username = json['username'] as String?;
    final String? salt = json['salt'] as String?;
    final String? token = json['token'] as String?;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    if (username == null || username.isEmpty) return null;
    if (salt == null || salt.isEmpty) return null;
    if (token == null || token.isEmpty) return null;
    return SubsonicSession(
      baseUrl: baseUrl,
      username: username,
      salt: salt,
      token: token,
      serverType: json['serverType'] as String?,
      serverVersion: json['serverVersion'] as String?,
      apiVersion: json['apiVersion'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubsonicSession &&
          other.baseUrl == baseUrl &&
          other.username == username &&
          other.salt == salt &&
          other.token == token &&
          other.serverType == serverType &&
          other.serverVersion == serverVersion &&
          other.apiVersion == apiVersion);

  @override
  int get hashCode => Object.hash(
        baseUrl,
        username,
        salt,
        token,
        serverType,
        serverVersion,
        apiVersion,
      );

  /// Redacts the credential (salt + token) so the session can be safely
  /// interpolated into logs or error messages without leaking the secret.
  @override
  String toString() => 'SubsonicSession(baseUrl: $baseUrl, '
      'username: $username, serverType: $serverType, '
      'serverVersion: $serverVersion, apiVersion: $apiVersion, '
      'salt: <redacted>, token: <redacted>)';
}
