import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/subsonic_session.dart';

/// An opaque, non-secret fingerprint identifying a Subsonic/Navidrome
/// **server + account**.
///
/// Mirrors `jellyfinAccountFingerprint`: it answers "is this the same
/// server/account as before?" without carrying anything sensitive. The inputs
/// are the (non-secret) base URL and username — never the salt or token, which
/// are credentials and rotate per session — and they are SHA-256 hashed, so the
/// value reveals neither the server address nor the username and is safe to put
/// in an in-memory key or surface in diagnostics. A re-login to the same account
/// (a fresh salt/token) keeps the same fingerprint; pointing at a different
/// server, or signing in as a different user, changes it.
String subsonicAccountFingerprint(SubsonicSession session) {
  // A NUL separator (which can appear in neither a URL nor a username) keeps
  // e.g. ("ab","c") distinct from ("a","bc").
  final String separator = String.fromCharCode(0);
  final String material = '${session.baseUrl}$separator${session.username}';
  return sha256.convert(utf8.encode(material)).toString();
}
