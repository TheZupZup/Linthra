import 'package:flutter/foundation.dart';

import '../models/track.dart';

/// One playable copy of a song from a single provider — a "source track".
///
/// It pairs the catalog [Track] (which already carries the opaque
/// `jellyfin:` / `subsonic:` / local-path URI, never a credential) with the
/// [sourceId] that owns it, so the unifier and the UI can reason about *where*
/// a copy lives without re-parsing the URI at every call site.
@immutable
class TrackSourceCandidate {
  const TrackSourceCandidate({required this.track, required this.sourceId});

  /// The source-specific catalog track (its own id, URI, and metadata).
  final Track track;

  /// The provider that owns [track] — `local`, `jellyfin`, or `subsonic`.
  final String sourceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackSourceCandidate &&
          other.sourceId == sourceId &&
          other.track == track);

  @override
  int get hashCode => Object.hash(sourceId, track);
}

/// One displayed library item, representing the same song across one or more
/// [TrackSourceCandidate]s.
///
/// The candidates are ordered best-first by source preference, so [primary] is
/// the copy playback should use and the rest are deterministic fallbacks. A
/// logical track with a single candidate is the common case — a track that
/// exists on only one provider — and behaves exactly like that provider's track
/// did before unification.
@immutable
class LogicalTrack {
  /// Wraps the ordered [candidates] of a song. Callers must pass a non-empty,
  /// preference-ordered list — `unifyTracks` and [LogicalTrack.single] are the
  /// only constructors used in practice and both uphold that.
  const LogicalTrack(this.candidates);

  /// A logical track wrapping a single source copy. The everyday case.
  LogicalTrack.single(TrackSourceCandidate candidate)
      : candidates = <TrackSourceCandidate>[candidate];

  /// Source copies of this song, ordered most-preferred first.
  final List<TrackSourceCandidate> candidates;

  /// The preferred copy — what the row displays and what playback resolves to.
  TrackSourceCandidate get primary => candidates.first;

  /// The preferred copy's catalog track (the playable, displayable [Track]).
  Track get primaryTrack => primary.track;

  /// The artwork to show for this row, chosen deterministically: the displayed
  /// (preferred) copy's own cover wins; if it has none, the first fallback
  /// candidate — in the same preference order — that *does* carry artwork is
  /// used. So unifying never blanks a cover the song actually has on another
  /// provider (a common regression when the preferred provider — e.g. Subsonic,
  /// whose mapper stores no `artworkUri` — shadows a Jellyfin copy that has one).
  /// `null` only when no candidate has any artwork at all.
  Uri? get displayArtworkUri {
    for (final TrackSourceCandidate c in candidates) {
      final Uri? art = c.track.artworkUri;
      if (art != null) return art;
    }
    return null;
  }

  /// The [Track] the row should display and enqueue: the preferred copy, but
  /// carrying the best available artwork ([displayArtworkUri]) so a primary that
  /// lacks a cover does not hide one a fallback copy has. Its [Track.id] and
  /// [Track.uri] are the primary's, so playback resolution, the "Playing from …"
  /// source indicator, and removal are all unchanged — only the cover is filled.
  Track get displayTrack {
    final Uri? art = displayArtworkUri;
    if (art == primaryTrack.artworkUri) return primaryTrack;
    return primaryTrack.copyWith(artworkUri: art);
  }

  /// A stable id for the logical row: the preferred copy's track id. Stable for
  /// a given catalog + preference, which is all the UI (keys, selection) needs.
  String get id => primaryTrack.id;

  /// Every source id this song can be played from, in preference order.
  List<String> get sourceIds =>
      <String>[for (final TrackSourceCandidate c in candidates) c.sourceId];

  /// Every source copy's track id. Removing a logical track from the library
  /// forgets *all* of these, so a hidden duplicate can't resurrect the row.
  List<String> get allTrackIds =>
      <String>[for (final TrackSourceCandidate c in candidates) c.track.id];

  /// Whether this song is available from more than one provider.
  bool get hasMultipleSources => candidates.length > 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LogicalTrack && listEquals(other.candidates, candidates));

  @override
  int get hashCode => Object.hashAll(candidates);
}
