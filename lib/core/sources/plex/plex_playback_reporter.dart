import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../models/plex_session.dart';
import '../../models/track.dart';
import '../../services/server_playback_reporter.dart';
import 'plex_api.dart';
import 'plex_client.dart';
import 'plex_exception.dart';
import 'plex_track_mapper.dart';

/// Reports playback of `plex:<ratingKey>` tracks back to the Plex Media
/// Server's `/:/timeline` endpoint, so Linthra shows up as an active player in
/// the server's Now Playing dashboard — playing, paused, progressing, and
/// cleared again when playback stops or moves on.
///
/// Every Plex-specific reporting detail lives here: the lifecycle → timeline
/// `state` mapping, the `ratingKey` extraction from the opaque track uri, and
/// the millisecond units PMS expects. The playback layer only ever sees the
/// provider-neutral [ServerPlaybackReporter].
///
/// The session and client are read through getters at event time — exactly
/// like `PlexPlayableUriResolver` reads its source — so signing in/out (and
/// the client identity persisted at sign-in, which is what PMS keys the
/// player session on) is always the live one without rebuilding anything.
/// With no session every event is a silent no-op.
///
/// Best-effort by contract: every failure (typed or not) is swallowed, so a
/// down server or rejected token can never disturb playback — at most it
/// leaves a debug breadcrumb carrying only the error *kind* (an enum name).
/// Token safety follows the established Plex rules: the token is handed to
/// the [PlexClient] (which sends it as a header) and never reaches a URL this
/// class sees, a log, or an error; nothing here is persisted.
class PlexPlaybackReporter implements ServerPlaybackReporter {
  PlexPlaybackReporter({
    required PlexSession? Function() session,
    required PlexClient Function() client,
  })  : _session = session,
        _client = client;

  /// Supplies the live signed-in session, or `null` when not connected.
  final PlexSession? Function() _session;

  /// Supplies the live client (whose identity headers name this install).
  final PlexClient Function() _client;

  /// The last position/duration actually reported for the current track, so
  /// [onTrackChanged] can close the outgoing track's session at an honest
  /// position (that event carries no position of its own).
  String? _lastReportedUri;
  Duration _lastReportedPosition = Duration.zero;
  Duration? _lastReportedDuration;

  @override
  bool handles(Track track) => track.uri.startsWith(PlexTrackMapper.uriScheme);

  @override
  Future<void> onPlaybackStarted(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, PlexTimelineState.playing, position, duration);

  @override
  Future<void> onPlaybackProgress(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, PlexTimelineState.playing, position, duration);

  @override
  Future<void> onPlaybackPaused(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, PlexTimelineState.paused, position, duration);

  @override
  Future<void> onPlaybackResumed(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, PlexTimelineState.playing, position, duration);

  @override
  Future<void> onPlaybackStopped(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, PlexTimelineState.stopped, position, duration);

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {
    // Only the outgoing track is this reporter's business here: a Plex track
    // that stops playing must release its Now Playing session whatever plays
    // next (another Plex track, another provider's, or nothing). The incoming
    // track announces itself via onPlaybackStarted once it actually plays.
    if (previousTrack == null || !handles(previousTrack)) return;
    final bool remembered = previousTrack.uri == _lastReportedUri;
    await _report(
      previousTrack,
      PlexTimelineState.stopped,
      remembered ? _lastReportedPosition : Duration.zero,
      remembered ? (_lastReportedDuration ?? Duration.zero) : Duration.zero,
    );
  }

  /// Sends one timeline report, best-effort. A non-Plex track, a missing
  /// session, or a blank ratingKey is a silent no-op; a failed request is
  /// swallowed (with a kind-only debug breadcrumb) — playback never notices.
  Future<void> _report(
    Track track,
    PlexTimelineState state,
    Duration position,
    Duration duration,
  ) async {
    if (!handles(track)) return;
    final PlexSession? session = _session();
    if (session == null) return;
    final String ratingKey =
        track.uri.substring(PlexTrackMapper.uriScheme.length).trim();
    if (ratingKey.isEmpty) return;

    if (state == PlexTimelineState.stopped) {
      if (track.uri == _lastReportedUri) _lastReportedUri = null;
    } else {
      _lastReportedUri = track.uri;
      _lastReportedPosition = position;
      _lastReportedDuration = duration > Duration.zero ? duration : null;
    }

    try {
      await _client().reportTimeline(
        baseUrl: session.baseUrl,
        token: session.token,
        ratingKey: ratingKey,
        state: state,
        time: position,
        duration: duration > Duration.zero ? duration : null,
      );
    } on PlexException catch (error) {
      // Best-effort by contract. The breadcrumb carries only the error kind
      // and the reported state — never the message, a URL, or the token.
      _log('timeline ${state.value} failed: ${error.kind.name}');
    } catch (_) {
      _log('timeline ${state.value} failed: unexpected');
    }
  }

  static void _log(String message) {
    if (!kDebugMode) return;
    developer.log(message, name: 'linthra.plex');
  }
}
