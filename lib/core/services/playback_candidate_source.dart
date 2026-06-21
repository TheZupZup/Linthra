import '../models/track.dart';

/// Looks up the ordered source candidates for a track at play time, so the
/// playback controller can fall back to another copy of the *same song* when the
/// preferred one fails to resolve or start.
///
/// A logical (de-duplicated) library row can be backed by the same song on more
/// than one provider (Jellyfin + Navidrome/Subsonic + local). The UI plays the
/// preferred copy, but only passes that single [Track] into playback — the
/// sibling copies are lost at that boundary. This seam re-supplies them, ordered
/// most-preferred first, so a failed preferred copy can deterministically fall
/// back to the next.
///
/// Returning `[track]` (just the track itself) means "no fallback": that is the
/// answer for a single-source song, a non-library track (e.g. a specific playlist
/// entry), or the default implementation — so existing single-source playback
/// behaves exactly as it did before runtime fallback existed.
abstract interface class PlaybackCandidateSource {
  /// The ordered candidates to try for [track], most-preferred first. Never
  /// empty; the first element corresponds to [track] itself.
  List<Track> candidatesFor(Track track);
}

/// The default [PlaybackCandidateSource]: no cross-provider fallback. Every track
/// is its own only candidate, so playback is byte-for-byte what it was before
/// runtime fallback. Used wherever the unified library isn't wired in (and as the
/// safe default the production override replaces).
class NoFallbackCandidateSource implements PlaybackCandidateSource {
  const NoFallbackCandidateSource();

  @override
  List<Track> candidatesFor(Track track) => <Track>[track];
}

/// A [PlaybackCandidateSource] backed by a lazily-read map of *provider-namespaced
/// [Track.uri]* → ordered candidates.
///
/// The map is read through a callback at every [candidatesFor] call, never cached,
/// so the session-pinned playback controller always sees the latest library
/// (after a scan, sync, sign-in, or a change to the default-source setting)
/// without being rebuilt. A track absent from the map — a single-source song, or
/// any track that isn't a unified library row — yields `[track]`, i.e. no
/// fallback. Keyed by uri (not the bare id) so a queued `subsonic:101` can't
/// resolve to a different song's candidates that happen to be `jellyfin:101`.
class MapPlaybackCandidateSource implements PlaybackCandidateSource {
  const MapPlaybackCandidateSource(this._candidatesByUri);

  final Map<String, List<Track>> Function() _candidatesByUri;

  @override
  List<Track> candidatesFor(Track track) {
    final List<Track>? candidates = _candidatesByUri()[track.uri];
    if (candidates == null || candidates.isEmpty) return <Track>[track];
    return candidates;
  }
}
