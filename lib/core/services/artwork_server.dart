import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/plex_session.dart';
import '../models/subsonic_session.dart';
import '../sources/plex/plex_track_mapper.dart';
import '../sources/subsonic/subsonic_artwork.dart';

/// The non-secret identity of the server a cover [reference] resolves against
/// right now, for the artwork caches to keep one server's covers apart from
/// another's (#739).
///
/// A Subsonic or Plex reference (`subsonic-cover:al-12`,
/// `plex-thumb:/library/metadata/101/thumb/…`) names a cover on whichever
/// server is connected, so another server's `al-12` is another cover: it is
/// told apart by a hash of the Subsonic server's address, or by the Plex
/// server's `machineIdentifier`. Null when that provider is signed out and
/// nothing would resolve the reference.
///
/// Anything else (a Jellyfin cover URL, which already names its server) is
/// ''. Never a token, an address in the clear, or a user.
String? artworkServerOf(
  Uri reference, {
  SubsonicSession? subsonic,
  PlexSession? plex,
}) {
  if (reference.isScheme(SubsonicArtwork.referenceScheme)) {
    if (subsonic == null) return null;
    final String address =
        sha256.convert(utf8.encode(subsonic.baseUrl)).toString();
    return 'subsonic:$address';
  }
  if (reference.isScheme(PlexTrackMapper.artworkScheme)) {
    if (plex == null) return null;
    return 'plex:${plex.machineIdentifier}';
  }
  return '';
}
