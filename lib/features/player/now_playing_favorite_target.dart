import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_candidate_source.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/plex/plex_track_mapper.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';

/// Resolves the provider-specific track that a Now Playing heart tap should
/// toggle.
///
/// The Now Playing widget can be handed a logical/display track from the unified
/// library, while playback may have resolved a sibling provider copy (for
/// example a `subsonic:` candidate after Jellyfin failed, or because Navidrome is
/// the preferred source). Favorites are provider-specific writes, so the heart
/// must target the copy that is actually playing when that can be determined.
/// If no better provider copy is available, this deliberately falls back to the
/// displayed track so local-only and single-source playback keep their existing
/// behavior.
Track resolveNowPlayingFavoriteTarget({
  required Track displayTrack,
  required PlaybackState playbackState,
  required PlaybackCandidateSource candidateSource,
}) {
  final Track? playingTrack = playbackState.currentTrack;
  final String targetScheme = _schemeOf(playingTrack?.uri ?? displayTrack.uri);
  if (targetScheme.isEmpty) return displayTrack;

  final List<Track> candidates = _dedupe(<Track>[
    displayTrack,
    if (playingTrack != null) playingTrack,
    ...candidateSource.candidatesFor(displayTrack),
    if (playingTrack != null) ...candidateSource.candidatesFor(playingTrack),
  ]);

  if (playingTrack != null && _schemeOf(playingTrack.uri) == targetScheme) {
    final Track exact = candidates.firstWhere(
      (candidate) => candidate.uri == playingTrack.uri,
      orElse: () => playingTrack,
    );
    return exact;
  }

  for (final Track candidate in candidates) {
    if (_schemeOf(candidate.uri) == targetScheme) return candidate;
  }
  return displayTrack;
}

List<Track> _dedupe(List<Track> tracks) {
  final Set<String> seen = <String>{};
  return <Track>[
    for (final Track track in tracks)
      if (seen.add(track.uri)) track,
  ];
}

String _schemeOf(String uri) {
  if (uri.startsWith(JellyfinTrackMapper.uriScheme)) {
    return JellyfinTrackMapper.uriScheme;
  }
  if (uri.startsWith(SubsonicTrackMapper.uriScheme)) {
    return SubsonicTrackMapper.uriScheme;
  }
  if (uri.startsWith(PlexTrackMapper.uriScheme)) {
    return PlexTrackMapper.uriScheme;
  }
  return '';
}
