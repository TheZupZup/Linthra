import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../models/jellyfin_session.dart';
import '../../models/track.dart';
import '../../services/server_playback_reporter.dart';
import 'jellyfin_api.dart';
import 'jellyfin_client.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_track_mapper.dart';

/// Reports playback of `jellyfin:<itemId>` tracks back to the Jellyfin
/// server's play-session endpoints, so Linthra shows up as an active player on
/// the server's dashboard — playing, paused, progressing, and cleared again
/// when playback stops or moves on — and the item's play state stays in sync.
///
/// Every Jellyfin-specific reporting detail lives here: the lifecycle →
/// [JellyfinPlaybackEvent] mapping and the `itemId` extraction from the opaque
/// track uri. The playback layer only ever sees the provider-neutral
/// [ServerPlaybackReporter]; how Jellyfin spells an event on the wire
/// (endpoints, ticks, `IsPaused`) stays inside the [JellyfinClient].
///
/// The session and client are read through getters at event time — exactly
/// like `JellyfinPlayableUriResolver` reads its source — so signing in/out
/// (and the device identity persisted at sign-in, which is what the server
/// keys the player session on) is always the live one without rebuilding
/// anything. With no session every event is a silent no-op.
///
/// Best-effort by contract: every failure (typed or not) is swallowed, so a
/// down server or rejected token can never disturb playback — at most it
/// leaves a debug breadcrumb carrying only the error *kind* (an enum name).
/// Token safety follows the established Jellyfin rules: the token is handed to
/// the [JellyfinClient] (which sends it in the `Authorization` header) and
/// never reaches a URL this class sees, a log, or an error; nothing here is
/// persisted.
class JellyfinPlaybackReporter implements ServerPlaybackReporter {
  JellyfinPlaybackReporter({
    required JellyfinSession? Function() session,
    required JellyfinClient Function() client,
  })  : _session = session,
        _client = client;

  /// Supplies the live signed-in session, or `null` when not connected.
  final JellyfinSession? Function() _session;

  /// Supplies the live client (whose auth header names this install).
  final JellyfinClient Function() _client;

  /// The last position actually reported for the current track, so
  /// [onTrackChanged] can close the outgoing track's session at an honest
  /// position (that event carries no position of its own).
  String? _lastReportedUri;
  Duration _lastReportedPosition = Duration.zero;

  @override
  bool handles(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme);

  @override
  Future<void> onPlaybackStarted(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, JellyfinPlaybackEvent.started, position);

  @override
  Future<void> onPlaybackProgress(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, JellyfinPlaybackEvent.progress, position);

  @override
  Future<void> onPlaybackPaused(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, JellyfinPlaybackEvent.paused, position);

  @override
  Future<void> onPlaybackResumed(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, JellyfinPlaybackEvent.resumed, position);

  @override
  Future<void> onPlaybackStopped(
    Track track,
    Duration position,
    Duration duration,
  ) =>
      _report(track, JellyfinPlaybackEvent.stopped, position);

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {
    // Only the outgoing track is this reporter's business here: a Jellyfin
    // track that stops playing must release its session whatever plays next
    // (another Jellyfin track, another provider's, or nothing). The incoming
    // track announces itself via onPlaybackStarted once it actually plays.
    if (previousTrack == null || !handles(previousTrack)) return;
    final bool remembered = previousTrack.uri == _lastReportedUri;
    await _report(
      previousTrack,
      JellyfinPlaybackEvent.stopped,
      remembered ? _lastReportedPosition : Duration.zero,
    );
  }

  /// Sends one play-session report, best-effort. A non-Jellyfin track, a
  /// missing session, or a blank itemId is a silent no-op; a failed request is
  /// swallowed (with a kind-only debug breadcrumb) — playback never notices.
  Future<void> _report(
    Track track,
    JellyfinPlaybackEvent event,
    Duration position,
  ) async {
    if (!handles(track)) return;
    final JellyfinSession? session = _session();
    if (session == null) return;
    final String itemId =
        track.uri.substring(JellyfinTrackMapper.uriScheme.length).trim();
    if (itemId.isEmpty) return;

    if (event == JellyfinPlaybackEvent.stopped) {
      if (track.uri == _lastReportedUri) _lastReportedUri = null;
    } else {
      _lastReportedUri = track.uri;
      _lastReportedPosition = position;
    }

    try {
      await _client().reportPlayback(
        session,
        itemId: itemId,
        event: event,
        position: position,
      );
    } on JellyfinException catch (error) {
      // Best-effort by contract. The breadcrumb carries only the error kind
      // and the reported event — never the message, a URL, or the token.
      _log('playback ${event.name} failed: ${error.kind.name}');
    } catch (_) {
      _log('playback ${event.name} failed: unexpected');
    }
  }

  static void _log(String message) {
    if (!kDebugMode) return;
    developer.log(message, name: 'linthra.jellyfin');
  }
}
