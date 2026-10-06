import '../repositories/download_store.dart';

/// Which server each provider whose ids only mean something on one server is
/// connected to right now, so an offline copy only ever plays for the server
/// it came from.
///
/// A Plex ratingKey is a number its server hands out: `plex:101` on another
/// server, or on a reinstalled one, is a different song. Most Subsonic
/// servers number their songs the same way, and Navidrome derives its ids
/// from file paths, which another installation can share for another file.
/// Every stored reference to such a track is that bare id, so without this a
/// song downloaded or pre-cached on one server would stand in for another
/// server's song with the same id: it would read as downloaded and play the
/// wrong audio. Each such copy records the server it came from
/// ([CachedTrack.origin]) and is used only while that server is connected. On
/// another server, and while signed out, it is kept but set aside, so
/// connecting back to its server brings it back.
abstract interface class OfflineCopyOrigins {
  /// Whether offline copies of [scheme] (`plex`, `subsonic`, …) are bound to
  /// the server they came from.
  bool binds(String scheme);

  /// The non-secret identity of the server [scheme]'s provider is connected
  /// to now, or null while it is signed out.
  String? current(String scheme);

  /// Fires whenever [current] may have changed.
  Stream<void> get changes;
}

/// Whether [copy] may stand in for its track right now.
///
/// True for a provider whose ids are the same everywhere, and for a copy
/// saved before its server was recorded (the repository gives it the server
/// connected when it next loads it). A bound copy otherwise has to come from
/// the server connected now, so none of them plays while signed out: no
/// stored reference says which server it means. A [OfflineCopyOrigins] that
/// can't answer counts as signed out.
bool offlineCopyBelongs(CachedTrack copy, OfflineCopyOrigins? origins) {
  final String? scheme = copy.sourceType;
  if (origins == null || scheme == null) return true;
  try {
    if (!origins.binds(scheme)) return true;
    final String? origin = copy.origin;
    return origin == null || origin == origins.current(scheme);
  } catch (_) {
    return copy.origin == null;
  }
}
