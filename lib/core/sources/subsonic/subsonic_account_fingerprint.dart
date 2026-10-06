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

/// An opaque, non-secret fingerprint of the Subsonic/Navidrome **server**
/// [session] is signed in to, whoever is signed in.
///
/// A song id is the server's, the same for every account on it, so this is
/// what an offline copy of a song belongs to (see `OfflineCopyOrigins`). The
/// base URL is all Linthra knows of a server, hashed like
/// [subsonicAccountFingerprint], so it reveals no address.
///
/// Navidrome is the exception: it derives a song's id from its file's path,
/// so the id names the same file at any address the server is reached
/// through. Every Navidrome is [navidromeServerFingerprint], and its copies
/// follow the listener from the LAN address to the reverse proxy and back.
String subsonicServerFingerprint(SubsonicSession session) => session.isNavidrome
    ? navidromeServerFingerprint
    : sha256.convert(utf8.encode(session.baseUrl)).toString();

/// The [subsonicServerFingerprint] of every Navidrome server.
const String navidromeServerFingerprint = 'navidrome';
