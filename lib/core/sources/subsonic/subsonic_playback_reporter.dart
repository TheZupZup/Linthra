import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../models/subsonic_session.dart';
import '../../models/track.dart';
import '../../services/server_playback_reporter.dart';
import 'subsonic_client.dart';
import 'subsonic_exception.dart';
import 'subsonic_track_mapper.dart';

/// Reports playback of `subsonic:<id>` tracks back to the server through the
/// Subsonic `scrobble` endpoint — the one playback-reporting concept the
/// Subsonic API has — so Navidrome (and any Subsonic-compatible server) shows
/// Linthra under "now playing" and counts completed plays.
///
/// The lifecycle is mapped onto what the protocol can express:
///  - **start / resume** → `scrobble(submission=false)`: registers the song as
///    now playing (resume re-announces, so the entry stays fresh after a long
///    pause). There is no pause or stop wire concept, so paused/stopped state
///    is never sent — entries age out on the server.
///  - **progress / pause** → no request; only the position is remembered, so a
///    later settle can judge how much actually played.
///  - **stop / track change** → `scrobble(submission=true)` when the play
///    *counts*: at least half the track, or at least [submissionFloor] of it,
///    was played — the classic scrobbling rule, applied client-side because
///    the server records whatever a client submits. A skipped-early track
///    submits nothing.
///
/// Every Subsonic-specific reporting detail lives here: the lifecycle →
/// scrobble mapping, the played-enough rule, and the id extraction from the
/// opaque track uri. The playback layer only ever sees the provider-neutral
/// [ServerPlaybackReporter].
///
/// The session and client are read through getters at event time — exactly
/// like `SubsonicPlayableUriResolver` reads its source — so signing in/out is
/// always picked up live without rebuilding anything. With no session every
/// event is a silent no-op.
///
/// Best-effort by contract: every failure (typed or not — including a server
/// without scrobble support, which answers with an error envelope) is
/// swallowed, so reporting can never disturb playback — at most it leaves a
/// debug breadcrumb carrying only the error *kind* (an enum name). Credential
/// safety follows the established Subsonic rules: the salt+token are woven
/// into the request URL inside the client, on demand, and never reach this
/// class, a log, or an error; nothing here is persisted.
class SubsonicPlaybackReporter implements ServerPlaybackReporter {
  SubsonicPlaybackReporter({
    required SubsonicSession? Function() session,
    required SubsonicClient Function() client,
  })  : _session = session,
        _client = client;

  /// Supplies the live signed-in session, or `null` when not connected.
  final SubsonicSession? Function() _session;

  /// Supplies the live client.
  final SubsonicClient Function() _client;

  /// A play always counts once this much of it ran, even when that is less
  /// than half (the long-track half of the half-or-four-minutes rule).
  static const Duration submissionFloor = Duration(minutes: 4);

  /// The track currently announced as now playing, with the last position and
  /// duration observed for it — what a settle (stop or track change) judges
  /// the play by. One play submits at most once: settling clears it.
  String? _nowPlayingUri;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;

  @override
  bool handles(Track track) =>
      track.uri.startsWith(SubsonicTrackMapper.uriScheme);

  @override
  Future<void> onPlaybackStarted(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    final String songId = _songId(track);
    if (songId.isEmpty) return;
    _remember(track, position, duration);
    await _scrobble(songId, submission: false);
  }

  @override
  Future<void> onPlaybackProgress(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    // No progress concept on the wire; just keep the settle judgement honest.
    if (_songId(track).isEmpty) return;
    _remember(track, position, duration);
  }

  @override
  Future<void> onPlaybackPaused(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    // No pause concept on the wire either.
    if (_songId(track).isEmpty) return;
    _remember(track, position, duration);
  }

  @override
  Future<void> onPlaybackResumed(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    final String songId = _songId(track);
    if (songId.isEmpty) return;
    _remember(track, position, duration);
    // Re-announce so the server's now-playing entry is fresh after a pause.
    await _scrobble(songId, submission: false);
  }

  @override
  Future<void> onPlaybackStopped(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _settle(track, position, duration);

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {
    // Only the outgoing track is this reporter's business here: its play must
    // be settled whatever comes next (another Subsonic track, another
    // provider's, or nothing). The incoming track announces itself via
    // onPlaybackStarted once it actually plays. This event carries no
    // position, so the settle uses the last one observed.
    if (previousTrack == null || !handles(previousTrack)) return;
    if (previousTrack.uri != _nowPlayingUri) return;
    await _settle(previousTrack, _lastPosition, _lastDuration);
  }

  /// Closes the play of [track]: submits a scrobble when enough of it ran to
  /// count, nothing otherwise, and forgets the play either way so it can never
  /// submit twice (a stop followed by the queue moving on settles once).
  Future<void> _settle(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    final String songId = _songId(track);
    if (songId.isEmpty) return;
    if (track.uri != _nowPlayingUri) return;
    _nowPlayingUri = null;
    if (!playedEnoughToSubmit(position, duration)) return;
    await _scrobble(songId, submission: true);
  }

  /// Whether a play that ended at [position] counts as a completed play:
  /// at least half of a known [duration], or at least [submissionFloor]
  /// regardless. A play whose position was never observed counts nothing.
  @visibleForTesting
  static bool playedEnoughToSubmit(Duration position, Duration duration) {
    if (position <= Duration.zero) return false;
    if (position >= submissionFloor) return true;
    return duration > Duration.zero && position * 2 >= duration;
  }

  /// The song id from the opaque `subsonic:<id>` uri, or `''` when the track
  /// isn't this provider's (or the uri is corrupt) — the caller's cue to
  /// silently do nothing.
  String _songId(Track track) {
    if (!handles(track)) return '';
    return track.uri.substring(SubsonicTrackMapper.uriScheme.length).trim();
  }

  void _remember(Track track, Duration position, Duration duration) {
    if (track.uri != _nowPlayingUri) {
      // A fresh play: drop the previous play's leftovers so they can never
      // bleed into this track's settle judgement.
      _nowPlayingUri = track.uri;
      _lastPosition = Duration.zero;
      _lastDuration = Duration.zero;
    }
    if (position > Duration.zero) _lastPosition = position;
    if (duration > Duration.zero) _lastDuration = duration;
  }

  /// Sends one scrobble call, best-effort. Signed out is a silent no-op; a
  /// failed request is swallowed (with a kind-only debug breadcrumb) —
  /// playback never notices.
  Future<void> _scrobble(String songId, {required bool submission}) async {
    final SubsonicSession? session = _session();
    if (session == null) return;
    final String what = submission ? 'scrobble' : 'now-playing';
    try {
      await _client().scrobble(session, songId, submission: submission);
    } on SubsonicException catch (error) {
      // Best-effort by contract. The breadcrumb carries only the error kind —
      // never the message, a URL, or the credential.
      _log('$what failed: ${error.kind.name}');
    } catch (_) {
      _log('$what failed: unexpected');
    }
  }

  static void _log(String message) {
    if (!kDebugMode) return;
    developer.log(message, name: 'linthra.subsonic');
  }
}
