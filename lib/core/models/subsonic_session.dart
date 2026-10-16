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
/// The exception is opt-in: a server that refuses tokens (Nextcloud Music, an
/// LDAP account) can only be reached with the password itself, sent as `p=` on
/// every request. [SubsonicSession.password] keeps it, in the same encrypted
/// store, and only for an https server: [fromJson] won't restore one for
/// anything else.
class SubsonicSession {
  const SubsonicSession({
    required this.baseUrl,
    required this.username,
    required String this.salt,
    required String this.token,
    this.serverType,
    this.serverVersion,
    this.apiVersion,
  }) : password = null;

  /// A session that signs in with the password itself (legacy password
  /// sign-in), for a server that refuses the token. [baseUrl] must be https.
  const SubsonicSession.password({
    required this.baseUrl,
    required this.username,
    required String this.password,
    this.serverType,
    this.serverVersion,
    this.apiVersion,
  })  : salt = null,
        token = null;

  /// Clean base URL of the server (no trailing slash), e.g.
  /// `https://music.example.com`. The `/rest/*.view` API paths append to this.
  final String baseUrl;

  /// The authenticated user's name. Sent on every request as `u=`.
  final String username;

  /// The per-session random salt sent as `s=`. Not a secret on its own, but is
  /// half of the credential, so it is treated as sensitive and redacted in
  /// [toString]. Null for a [SubsonicSession.password] session.
  final String? salt;

  /// `md5(password + salt)`, sent as `t=`. The secret — never log this. The
  /// password it was derived from is never stored. Null for a
  /// [SubsonicSession.password] session.
  final String? token;

  /// The password, kept only by a [SubsonicSession.password] session. The
  /// secret — never log this.
  final String? password;

  /// The server product, when reported (OpenSubsonic `type`, e.g. `navidrome`).
  /// Display/diagnostics only.
  final String? serverType;

  /// The server's own version (OpenSubsonic `serverVersion`), when reported.
  /// Display/diagnostics only.
  final String? serverVersion;

  /// The Subsonic API version the server reported (`version`), when known.
  /// Display/diagnostics only.
  final String? apiVersion;

  /// Whether this session signs in with the password (legacy password sign-in)
  /// rather than a salt + token.
  bool get usesPassword => password != null;

  /// A copy with the given fields replaced. A password session keeps its
  /// password and has no salt or token to replace.
  SubsonicSession copyWith({
    String? baseUrl,
    String? username,
    String? salt,
    String? token,
    String? serverType,
    String? serverVersion,
    String? apiVersion,
  }) {
    final String? password = this.password;
    if (password != null) {
      assert(salt == null && token == null, 'a password session has no token');
      return SubsonicSession.password(
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        password: password,
        serverType: serverType ?? this.serverType,
        serverVersion: serverVersion ?? this.serverVersion,
        apiVersion: apiVersion ?? this.apiVersion,
      );
    }
    return SubsonicSession(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      salt: salt ?? this.salt!,
      token: token ?? this.token!,
      serverType: serverType ?? this.serverType,
      serverVersion: serverVersion ?? this.serverVersion,
      apiVersion: apiVersion ?? this.apiVersion,
    );
  }

  /// Serializes for the session store. The credential (salt and token, or the
  /// password) is included because the only caller is the (encrypted) store; do
  /// not route this through any plaintext sink.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'username': username,
        if (password != null) ...<String, dynamic>{
          'auth': _passwordAuth,
          'password': password,
        } else ...<String, dynamic>{
          'salt': salt,
          'token': token,
        },
        if (serverType != null) 'serverType': serverType,
        if (serverVersion != null) 'serverVersion': serverVersion,
        if (apiVersion != null) 'apiVersion': apiVersion,
      };

  /// The `auth` value marking a password session. A record without `auth` is a
  /// salt + token one, which is every record written before password sign-in
  /// existed.
  static const String _passwordAuth = 'password';

  /// Rebuilds a session from [toJson] output, or returns `null` if any required
  /// field is missing/blank (e.g. a partially written or corrupted record), so
  /// the app treats it as "not signed in" rather than crashing.
  ///
  /// A password session for anything but an https server reads as `null` too:
  /// sign-in never makes one, and restoring it would send the password in the
  /// clear.
  static SubsonicSession? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = json['baseUrl'] as String?;
    final String? username = json['username'] as String?;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    if (username == null || username.isEmpty) return null;
    final String? serverType = json['serverType'] as String?;
    final String? serverVersion = json['serverVersion'] as String?;
    final String? apiVersion = json['apiVersion'] as String?;

    if (json['auth'] == _passwordAuth) {
      final Object? password = json['password'];
      if (password is! String || password.isEmpty) return null;
      if (!(Uri.tryParse(baseUrl)?.isScheme('https') ?? false)) return null;
      return SubsonicSession.password(
        baseUrl: baseUrl,
        username: username,
        password: password,
        serverType: serverType,
        serverVersion: serverVersion,
        apiVersion: apiVersion,
      );
    }

    final String? salt = json['salt'] as String?;
    final String? token = json['token'] as String?;
    if (salt == null || salt.isEmpty) return null;
    if (token == null || token.isEmpty) return null;
    return SubsonicSession(
      baseUrl: baseUrl,
      username: username,
      salt: salt,
      token: token,
      serverType: serverType,
      serverVersion: serverVersion,
      apiVersion: apiVersion,
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
          other.password == password &&
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
        serverType,
        serverVersion,
        apiVersion,
      );

  /// Redacts the credential (salt + token, or the password) so the session can
  /// be safely interpolated into logs or error messages without leaking it.
  @override
  String toString() => 'SubsonicSession(baseUrl: $baseUrl, '
      'username: $username, serverType: $serverType, '
      'serverVersion: $serverVersion, apiVersion: $apiVersion, '
      '${usesPassword ? 'password: <redacted>' : 'salt: <redacted>, token: <redacted>'})';
}
