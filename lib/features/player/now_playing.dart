import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/now_playing_match.dart';
import '../../core/models/track.dart';

/// How a track row should mark itself relative to the current playback track.
enum NowPlayingRowState {
  /// The row is the current track and playback is actively playing — the
  /// indicator animates.
  playing,

  /// The row is the current track but playback is paused (or otherwise not
  /// actively playing) — the indicator is shown, but static.
  paused,
}

/// A tiny, position-independent snapshot of "what is playing", shared by every
/// track-row surface so the now-playing matching logic lives in exactly one
/// place rather than being re-derived per screen.
///
/// It carries only the current [Track] and whether playback [isPlaying] — never
/// the position — and has value equality, so it (and the rows watching it) only
/// change on a track change or a play/pause flip, not on every position tick.
@immutable
class NowPlaying {
  const NowPlaying({this.currentTrack, this.isPlaying = false});

  /// The current logical playback track, or null when nothing is playing. May be
  /// a fallback source copy of what the user tapped (see [stateForRow]).
  final Track? currentTrack;

  /// Whether playback is actively playing — drives whether the indicator
  /// animates. False while paused, buffering, idle, errored, or stopped.
  final bool isPlaying;

  /// The indicator state for the row showing [row], or null when [row] is not
  /// the current track and so should show nothing. Matching is logical, so a
  /// different provider's copy of the current song still counts as current (see
  /// [isCurrentPlaybackTrack]).
  NowPlayingRowState? stateForRow(Track row) {
    final Track? current = currentTrack;
    if (current == null) return null;
    if (!isCurrentPlaybackTrack(row, current)) return null;
    return isPlaying ? NowPlayingRowState.playing : NowPlayingRowState.paused;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NowPlaying &&
          other.currentTrack == currentTrack &&
          other.isPlaying == isPlaying);

  @override
  int get hashCode => Object.hash(currentTrack, isPlaying);
}

/// What is currently playing, for the now-playing indicator on track rows.
///
/// The default is deliberately inert — nothing playing — and has **no**
/// dependency on the playback engine, so any surface that shows track rows can
/// watch it without pulling in `just_audio`/cast (and tests render rows without a
/// perpetually-animating indicator or a real audio plugin). Production wires it
/// to the live `PlaybackState` via `nowPlayingOverride` in `main.dart`, mirroring
/// `currentlyPlayingTrackProvider`/`currentlyPlayingTrackOverride`.
final nowPlayingProvider = Provider<NowPlaying>((ref) => const NowPlaying());
