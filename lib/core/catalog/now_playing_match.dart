import '../models/track.dart';
import 'track_identity.dart';

/// Whether a displayed track [row] represents the same *logical* song as the
/// current playback track [current] — the decision a track row uses to show the
/// now-playing indicator.
///
/// Two deterministic, deliberately conservative layers:
///
///  * **Exact id.** The everyday case: the row is literally the playing copy
///    (same provider, same track id). This is also the only thing that can match
///    an untagged local file, which carries too little metadata to be matched any
///    other way — so it only ever lights up its own row.
///  * **Cross-provider fallback.** When [row] and [current] come from *different*
///    providers, they count as the same song only when [isLikelySameTrack]
///    confidently agrees. This is the exact predicate the library unifier merges
///    duplicates on, so the indicator stays consistent with how the rest of the
///    app already reasons about "the same song across sources": if the user
///    tapped a Jellyfin row but playback fell back to the Navidrome copy, the
///    Jellyfin row still reads as currently playing.
///
/// Two rows from the *same* provider never match by metadata (only by id),
/// mirroring the unifier's rule that a single provider's own rows are assumed
/// already de-duplicated — so two distinct rows from one source can't both claim
/// to be the playing track.
bool isCurrentPlaybackTrack(Track row, Track current) {
  if (row.id == current.id) return true;
  if (trackSourceId(row) == trackSourceId(current)) return false;
  return isLikelySameTrack(row, current);
}
