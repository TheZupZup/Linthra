import 'dart:async';

import '../repositories/song_origin_legacy_store.dart';
import '../sources/plex/plex_track_mapper.dart';
import '../sources/subsonic/subsonic_track_mapper.dart';

/// Where the songs a stored reference names came from, for the providers
/// whose song ids only mean something on one server (#795).
///
/// A Plex ratingKey and most Subsonic song ids are numbers their server hands
/// out: `subsonic:48211` names one song on server A and another, or none, on
/// server B. A local playlist entry or a play count that keeps only the uri
/// would follow the user to B and stand for B's song 48211. So such a
/// reference records the origin it was made under, and only counts while
/// that origin is signed in again.
///
/// The origin is the identity the saved play queue already uses (#767): the
/// signed-in account for Subsonic, whose library is synced per account, and
/// the server for Plex, whose profiles share their server's ids. Jellyfin item
/// ids are unique across servers, so Jellyfin references record nothing.
abstract interface class SongOrigins {
  /// Whether references to [trackUri] record where they were made.
  bool binds(String trackUri);

  /// The origin [trackUri]'s provider is signed in to now, or null while it
  /// is signed out.
  String? current(String trackUri);

  /// The origin references saved before origins were recorded belong to: the
  /// one signed in when Linthra first started with this rule, or null when
  /// none was (they then match no origin, ever) or that isn't settled yet.
  String? legacy(String trackUri);

  /// Fires whenever [current] or [legacy] may have changed.
  Stream<void> get changes;
}

/// The data-layer default: nothing is bound, so every reference matches. What
/// tests and builds without remote providers get.
class UnboundSongOrigins implements SongOrigins {
  const UnboundSongOrigins();

  @override
  bool binds(String trackUri) => false;

  @override
  String? current(String trackUri) => null;

  @override
  String? legacy(String trackUri) => null;

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

/// The schemes whose references are bound to an origin.
const List<String> boundSongSchemes = <String>[
  SubsonicTrackMapper.uriScheme,
  PlexTrackMapper.uriScheme,
];

/// The bound scheme [trackUri] belongs to, or null.
String? boundSongScheme(String trackUri) {
  for (final String scheme in boundSongSchemes) {
    if (trackUri.startsWith(scheme)) return scheme;
  }
  return null;
}

/// Recorded for a reference made while its provider was signed out: it
/// belongs to no origin, and so never matches one.
const String noSongOrigin = '';

/// Whether a reference to [trackUri] recorded with [origin] (null when it was
/// saved before origins were recorded) names the song the library has under
/// that uri now.
///
/// Never for a reference from another origin, or from no origin at all, and
/// never while its provider is signed out: no stored reference says which
/// server it would mean then.
bool songOriginMatches(SongOrigins origins, String trackUri, String? origin) {
  if (!origins.binds(trackUri)) return true;
  final String? recorded = origin ?? origins.legacy(trackUri);
  if (recorded == null || recorded == noSongOrigin) return false;
  return recorded == origins.current(trackUri);
}

/// What a new reference to [trackUri] records: null when its provider isn't
/// bound, the origin signed in now, or [noSongOrigin] while signed out.
String? songOriginToRecord(SongOrigins origins, String trackUri) {
  if (!origins.binds(trackUri)) return null;
  return origins.current(trackUri) ?? noSongOrigin;
}

/// One key for a play-history entry of [trackUri] made under [origin]: the uri
/// itself when nothing is recorded, otherwise the uri and the origin joined by
/// a NUL, which neither can contain. Two servers' plays of the same id then
/// count apart.
String songHistoryKey(String trackUri, String? origin) =>
    origin == null ? trackUri : '$trackUri\u0000$origin';

/// The uri and origin a [songHistoryKey] was made from.
({String uri, String? origin}) splitSongHistoryKey(String key) {
  final int separator = key.indexOf('\u0000');
  if (separator < 0) return (uri: key, origin: null);
  return (
    uri: key.substring(0, separator),
    origin: key.substring(separator + 1),
  );
}

/// [SongOrigins] read from the signed-in sessions, with the origin of older
/// references settled once, from the sessions restored when this rule first
/// ran (see [settleLegacy]).
class SessionSongOrigins implements SongOrigins {
  SessionSongOrigins({
    required String? Function(String scheme) signedIn,
    required SongOriginLegacyStore legacyStore,
  })  : _signedIn = signedIn,
        _legacyStore = legacyStore;

  /// The origin signed in now for a bound scheme, or null.
  final String? Function(String scheme) _signedIn;
  final SongOriginLegacyStore _legacyStore;

  Map<String, String> _legacy = const <String, String>{};
  Future<void>? _settling;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  bool binds(String trackUri) => boundSongScheme(trackUri) != null;

  @override
  String? current(String trackUri) {
    final String? scheme = boundSongScheme(trackUri);
    return scheme == null ? null : _signedIn(scheme);
  }

  @override
  String? legacy(String trackUri) {
    final String? scheme = boundSongScheme(trackUri);
    return scheme == null ? null : _legacy[scheme];
  }

  @override
  Stream<void> get changes => _changes.stream;

  /// Settles whose the references saved before origins were recorded are:
  /// for each bound scheme not settled yet, the origin signed in now, or
  /// nobody's when it is signed out. Kept from then on.
  ///
  /// Called once at startup, after the saved sign-ins are restored and before
  /// anyone can sign in to something else: an older reference was made under
  /// the account in use until this version, which is the one restored now. A
  /// later sign-in, to another server or the same one, never claims them.
  /// A record that can't be read settles nothing this time; one that can't
  /// be written still holds for this run.
  Future<void> settleLegacy() => _settling ??= _settle();

  Future<void> _settle() async {
    final Map<String, String> settled;
    try {
      settled = await _legacyStore.read();
    } catch (_) {
      return;
    }
    bool decided = false;
    for (final String scheme in boundSongSchemes) {
      if (settled.containsKey(scheme)) continue;
      settled[scheme] = _signedIn(scheme) ?? noSongOrigin;
      decided = true;
    }
    _legacy = settled;
    changed();
    if (!decided) return;
    try {
      await _legacyStore.write(settled);
    } catch (_) {
      // Holds for this run; the next start settles again from what it
      // restores.
    }
  }

  /// Tells listeners the answers may have changed.
  void changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> close() => _changes.close();
}
