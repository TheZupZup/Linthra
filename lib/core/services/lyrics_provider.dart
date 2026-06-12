import '../models/lyrics.dart';
import '../models/track.dart';

/// One music source's lyrics backend: local sidecar files, a Jellyfin or
/// Subsonic/Navidrome server, later Plex.
///
/// A provider is *identified* by [sourceId] — the same id its `MusicProvider`
/// declares in `MusicProviders` — and the [LyricsResolver] routes each track to
/// the provider(s) registered for the source that owns the track's URI. That
/// keeps routing in one registry-driven place instead of every backend keeping
/// its own list of "schemes that aren't mine" (the drift that quietly sent
/// `plex:` tracks to the local sidecar reader).
///
/// Contract:
///  - "No lyrics" is `null`, never an error — the UI shows its calm empty
///    state.
///  - A *fetch failure* (server offline, expired session) may throw so the UI
///    can tell "couldn't load" apart from "no lyrics"; anything thrown must be
///    safe to surface and log — no token, credential, or authenticated URL in
///    its message (the typed provider exceptions already guarantee this).
///  - Lookups are on-demand and independent of playback: a slow or failing
///    provider can never stall the audio path.
abstract interface class LyricsProvider {
  /// The id of the `MusicProvider` whose tracks this backend serves, e.g.
  /// `'jellyfin'` or `'local'`. The resolver only consults this provider for
  /// tracks owned by that source.
  String get sourceId;

  /// The lyrics for [track], or `null` when this backend has none.
  Future<Lyrics?> lyricsFor(Track track);
}
