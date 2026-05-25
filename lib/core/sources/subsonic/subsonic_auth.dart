import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The salt + token pair that authenticates a Subsonic request, derived once
/// from the password and then carried instead of it.
///
/// Subsonic's modern auth (API 1.13.0+) sends `t=<token>&s=<salt>` where
/// `token = md5(password + salt)`, so the plaintext password never travels and
/// never needs to be stored. Linthra computes one pair at sign-in and keeps
/// only it — see [SubsonicSession].
class SubsonicCredentials {
  const SubsonicCredentials({required this.salt, required this.token});

  /// The random salt, sent as the `s=` query parameter.
  final String salt;

  /// `md5(password + salt)`, the secret sent as the `t=` query parameter. Never
  /// log this.
  final String token;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubsonicCredentials &&
          other.salt == salt &&
          other.token == token);

  @override
  int get hashCode => Object.hash(salt, token);

  /// Redacts the token (and salt) so a credential can't leak through a log.
  @override
  String toString() =>
      'SubsonicCredentials(salt: <redacted>, token: <redacted>)';
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

  static String _randomSalt() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
