import '../models/lyrics.dart';
import '../models/track.dart';

/// Fetches a track's lyrics, hiding the source from the UI.
///
/// This is the seam the player watches; it never knows *where* lines come
/// from. The shipped implementation is a [LyricsResolver]: it routes each
/// track, by the source that owns its URI, to the [LyricsProvider]s registered
/// for that source (Jellyfin, Subsonic/Navidrome, the local sidecar reader, a
/// placeholder for Plex) — so a new provider slots in behind this same seam
/// without the player changing.
abstract interface class LyricsService {
  /// The lyrics for [track], or `null` when none are available — "no lyrics"
  /// is a calm state, never an error. May throw a typed provider exception
  /// (e.g. [JellyfinException]) for a *fetch failure* (offline, expired
  /// session) so the UI can tell "couldn't load" apart from "no lyrics";
  /// anything thrown carries a user-safe message free of tokens, credentials,
  /// and authenticated URLs.
  Future<Lyrics?> lyricsFor(Track track);
}
