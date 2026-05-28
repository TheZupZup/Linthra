import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/jellyfin_session.dart';

/// An opaque, non-secret fingerprint identifying a Jellyfin **server + account**.
///
/// Used by the auto-sync gate to answer one question: "have we already run the
/// first sync for *this* server/user?" so a fresh connection to a new server or
/// account syncs once, while reconnecting an already-synced account doesn't
/// re-pull the whole library on its own.
///
/// Security: the inputs are the (non-secret) base URL and user id — never the
/// access token — and they are SHA-256 hashed, so the stored value is a
/// one-way fingerprint that reveals neither the server address nor the user id.
/// It is safe to persist in plaintext `shared_preferences` and to surface in
/// diagnostics. The token is never part of the material.
String jellyfinAccountFingerprint(JellyfinSession session) {
  // A NUL separator keeps e.g. ("ab","c") distinct from ("a","bc").
  final String material = '${session.baseUrl}\u0000${session.userId}';
  return sha256.convert(utf8.encode(material)).toString();
}
