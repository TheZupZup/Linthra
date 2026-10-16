import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../models/subsonic_session.dart';

/// What authenticates a Subsonic request: by default the salt + token pair
/// derived once from the password and then carried instead of it.
///
/// Subsonic's modern auth (API 1.13.0+) sends `t=<token>&s=<salt>` where
/// `token = md5(password + salt)`, so the plaintext password never travels and
/// never needs to be stored. Linthra computes one pair at sign-in and keeps
/// only it — see [SubsonicSession].
///
/// Some servers refuse tokens: Nextcloud Music does, and so does a Subsonic
/// account whose password lives in LDAP (both answer error 41). For those the
/// user can opt into [SubsonicCredentials.password], which carries the
/// password itself. `SubsonicEndpoints` sends it only to an https server.
class SubsonicCredentials {
  const SubsonicCredentials({
    required String this.salt,
    required String this.token,
  }) : password = null;

  /// The opt-in legacy credential: the password, sent as `p=` on every
  /// request. See [SubsonicAuth.encodePassword].
  const SubsonicCredentials.password(String this.password)
      : salt = null,
        token = null;

  /// The credential [session] signs its requests with.
  factory SubsonicCredentials.of(SubsonicSession session) {
    final String? password = session.password;
    if (password != null) return SubsonicCredentials.password(password);
    return SubsonicCredentials(salt: session.salt!, token: session.token!);
  }

  /// The random salt, sent as the `s=` query parameter. Null for a password
  /// credential.
  final String? salt;

  /// `md5(password + salt)`, the secret sent as the `t=` query parameter. Never
  /// log this. Null for a password credential.
  final String? token;

  /// The password itself, for a server that refuses tokens. Never log this.
  /// Null for the default salt + token credential.
  final String? password;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubsonicCredentials &&
          other.salt == salt &&
          other.token == token &&
          other.password == password);

  @override
  int get hashCode => Object.hash(salt, token, password);

  /// Redacts the token (and salt), or the password, so a credential can't
  /// leak through a log.
  @override
  String toString() => password != null
      ? 'SubsonicCredentials(password: <redacted>)'
      : 'SubsonicCredentials(salt: <redacted>, token: <redacted>)';
}

/// Derives Subsonic [SubsonicCredentials] from a password, the one place the
/// token+salt scheme is implemented.
///
/// Pure and side-effect-free (apart from generating a random salt), so it is
/// trivially unit-testable: a fixed [saltGenerator] yields a deterministic
/// token whose value can be asserted against a known `md5(password + salt)`.
/// The password is used only to compute the token here and is never held,
/// copied, or logged.
abstract final class SubsonicAuth {
  /// Computes the (salt, token) pair for [password]. A fresh secure-random salt
  /// is generated unless [saltGenerator] is supplied (tests inject a fixed one).
  static SubsonicCredentials credentials(
    String password, {
    String Function()? saltGenerator,
  }) {
    final String salt = (saltGenerator ?? _randomSalt)();
    return SubsonicCredentials(salt: salt, token: tokenFor(password, salt));
  }

  /// `md5(password + salt)` as a lowercase hex string — exactly what a Subsonic
  /// server recomputes from its stored password to verify a request.
  static String tokenFor(String password, String salt) {
    return md5.convert(utf8.encode('$password$salt')).toString();
  }

  /// [password] as the `p=` value: `enc:` and its UTF-8 bytes in hex, the
  /// form every server that takes `p=` understands.
  ///
  /// The hex is an encoding, not encryption. It keeps the password unreadable
  /// at a glance and out of the query escaping that servers and proxies
  /// disagree on (`+`, `%`, non-ASCII), nothing more: anyone holding the URL
  /// holds the password.
  static String encodePassword(String password) {
    final String hex = utf8
        .encode(password)
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'enc:$hex';
  }

  static String _randomSalt() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
