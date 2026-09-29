import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/plex_session.dart';

/// An opaque fingerprint of the Plex server **and profile** a session acts as.
///
/// Plex Home profiles on one server share its `machineIdentifier`, and the
/// session carries nothing else that tells them apart except the token each
/// profile was issued. So, unlike `jellyfinAccountFingerprint`, the material
/// here includes the token, SHA-256 hashed so the result reveals nothing about
/// it.
///
/// It exists for one in-memory question, "is this still the same server and
/// profile?", asked by smart pre-cache before it keeps bytes it fetched. It is
/// never persisted, logged, or put in diagnostics.
String plexSessionFingerprint(PlexSession session) {
  // A NUL separator keeps e.g. ("ab","c") distinct from ("a","bc").
  final String separator = String.fromCharCode(0);
  final String material =
      '${session.machineIdentifier}$separator${session.token}';
  return sha256.convert(utf8.encode(material)).toString();
}
