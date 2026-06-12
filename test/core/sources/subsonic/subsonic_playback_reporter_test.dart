import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_playback_reporter.dart';

import 'fake_subsonic_client.dart';

const String _token = 'super-secret-subsonic-token';

const SubsonicSession _session = SubsonicSession(
  baseUrl: 'https://navidrome.example.com',
  username: 'alice',
  salt: 'salty',
  token: _token,
);

Track _subsonicTrack(String id,
        {Duration duration = const Duration(minutes: 3)}) =>
    Track(
      id: 'sub-$id',
      title: 'Song $id',
      uri: 'subsonic:$id',
      duration: duration,
    );

const Track _plexTrack = Track(id: 'plex-1', title: 'Elsewhere', uri: 'plex:1');
const Track _localTrack =
    Track(id: 'local-1', title: 'On disk', uri: 'file:///music/song.flac');

const Duration _duration = Duration(minutes: 3);

/// Past half of [_duration], so a settle at this position submits a play.
const Duration _playedEnough = Duration(minutes: 2);

/// Well short of half of [_duration] (and of the four-minute floor), so a
/// settle at this position submits nothing.
const Duration _playedLittle = Duration(seconds: 20);

void main() {
  group('SubsonicPlaybackReporter', () {
    late FakeSubsonicClient client;
    SubsonicSession? session = _session;

    setUp(() {
      client = FakeSubsonicClient();
      session = _session;
    });

    SubsonicPlaybackReporter build() => SubsonicPlaybackReporter(
          session: () => session,
          client: () => client,
        );

    test('handles only subsonic: tracks', () {
      final reporter = build();
      expect(reporter.handles(_subsonicTrack('42')), isTrue);
      expect(reporter.handles(_plexTrack), isFalse);
      expect(reporter.handles(_localTrack), isFalse);
    });

    test('started announces now playing (submission=false)', () async {
      await build().onPlaybackStarted(
          _subsonicTrack('song-1'), Duration.zero, _duration);

      expect(client.scrobbles, hasLength(1));
      final scrobble = client.scrobbles.single;
      expect(scrobble.songId, 'song-1');
      expect(scrobble.submission, isFalse);
      expect(client.lastScrobbleSession, _session);
    });

    test('progress and pause send nothing (no wire concept for them)',
        () async {
      final reporter = build();
      final Track track = _subsonicTrack('7');

      await reporter.onPlaybackStarted(track, Duration.zero, _duration);
      await reporter.onPlaybackProgress(track, _playedLittle, _duration);
      await reporter.onPlaybackPaused(track, _playedEnough, _duration);

      // Only the start's now-playing went out.
      expect(client.scrobbles, hasLength(1));
      expect(client.scrobbles.single.submission, isFalse);
    });

    test('resume re-announces now playing', () async {
      final reporter = build();
      final Track track = _subsonicTrack('7');

      await reporter.onPlaybackStarted(track, Duration.zero, _duration);
      await reporter.onPlaybackPaused(track, _playedLittle, _duration);
      await reporter.onPlaybackResumed(track, _playedLittle, _duration);

      expect(client.scrobbles, hasLength(2));
      expect(client.scrobbles.every((s) => !s.submission), isTrue);
      expect(client.scrobbles.every((s) => s.songId == '7'), isTrue);
    });

    group('a stop submits the play only when enough of it ran', () {
      test('stopping past half the track submits (submission=true)', () async {
        final reporter = build();
        final Track track = _subsonicTrack('s');

        await reporter.onPlaybackStarted(track, Duration.zero, _duration);
        await reporter.onPlaybackStopped(track, _playedEnough, _duration);

        expect(client.scrobbles, hasLength(2));
        final submission = client.scrobbles.last;
        expect(submission.songId, 's');
        expect(submission.submission, isTrue);
      });

      test('stopping early submits nothing (a skip is not a play)', () async {
        final reporter = build();
        final Track track = _subsonicTrack('s');

        await reporter.onPlaybackStarted(track, Duration.zero, _duration);
        await reporter.onPlaybackStopped(track, _playedLittle, _duration);

        expect(client.scrobbles, hasLength(1));
        expect(client.scrobbles.single.submission, isFalse);
      });

      test('four minutes of a long track submit even when short of half',
          () async {
        const Duration long = Duration(minutes: 10);
        final reporter = build();
        final Track track = _subsonicTrack('long', duration: long);

        await reporter.onPlaybackStarted(track, Duration.zero, long);
        await reporter.onPlaybackStopped(
            track, const Duration(minutes: 4), long);

        expect(client.scrobbles.last.submission, isTrue);
      });

      test('an unknown duration submits only past the four-minute floor',
          () async {
        final reporter = build();
        final Track track = _subsonicTrack('nodur', duration: Duration.zero);

        await reporter.onPlaybackStarted(track, Duration.zero, Duration.zero);
        await reporter.onPlaybackStopped(
            track, const Duration(minutes: 3), Duration.zero);

        expect(client.scrobbles, hasLength(1),
            reason: 'three minutes of an unknown-length track is not a play');

        await reporter.onPlaybackStarted(track, Duration.zero, Duration.zero);
        await reporter.onPlaybackStopped(
            track, const Duration(minutes: 4), Duration.zero);

        expect(client.scrobbles.last.submission, isTrue);
      });
    });

    test('a track change settles the outgoing track at its last position',
        () async {
      final reporter = build();
      final Track previous = _subsonicTrack('1');

      await reporter.onPlaybackStarted(previous, Duration.zero, _duration);
      await reporter.onPlaybackProgress(previous, _playedEnough, _duration);
      await reporter.onTrackChanged(previous, _subsonicTrack('2'));

      final submission = client.scrobbles.last;
      expect(submission.songId, '1');
      expect(submission.submission, isTrue);
    });

    test('a track change after an early skip submits nothing', () async {
      final reporter = build();
      final Track previous = _subsonicTrack('1');

      await reporter.onPlaybackStarted(previous, Duration.zero, _duration);
      await reporter.onPlaybackProgress(previous, _playedLittle, _duration);
      await reporter.onTrackChanged(previous, _subsonicTrack('2'));

      expect(client.scrobbles, hasLength(1));
      expect(client.scrobbles.single.submission, isFalse);
    });

    test('a stop followed by the queue moving on settles once, not twice',
        () async {
      final reporter = build();
      final Track track = _subsonicTrack('1');

      await reporter.onPlaybackStarted(track, Duration.zero, _duration);
      await reporter.onPlaybackStopped(track, _playedEnough, _duration);
      await reporter.onTrackChanged(track, _subsonicTrack('2'));

      expect(
        client.scrobbles.where((s) => s.submission),
        hasLength(1),
        reason: 'one play must submit at most one scrobble',
      );
    });

    test('replaying the same track submits again (each play counts)', () async {
      final reporter = build();
      final Track track = _subsonicTrack('loop');

      await reporter.onPlaybackStarted(track, Duration.zero, _duration);
      await reporter.onPlaybackStopped(track, _duration, _duration);
      await reporter.onPlaybackStarted(track, Duration.zero, _duration);
      await reporter.onPlaybackStopped(track, _duration, _duration);

      expect(client.scrobbles.where((s) => s.submission), hasLength(2));
    });

    test(
        'a fresh play never inherits the previous track\'s position '
        '(early skip after a long play stays unsubmitted)', () async {
      final reporter = build();
      final Track first = _subsonicTrack('1');
      final Track second = _subsonicTrack('2');

      await reporter.onPlaybackStarted(first, Duration.zero, _duration);
      await reporter.onPlaybackProgress(first, _playedEnough, _duration);
      await reporter.onTrackChanged(first, second);
      await reporter.onPlaybackStarted(second, Duration.zero, _duration);
      await reporter.onTrackChanged(second, null);

      // First track: now-playing + submission. Second: now-playing only —
      // its play never moved past zero, whatever the first track did.
      expect(
        client.scrobbles.map((s) => '${s.songId}:${s.submission}'),
        <String>['1:false', '1:true', '2:false'],
      );
    });

    test('a track change from another provider reports nothing', () async {
      final reporter = build();

      await reporter.onTrackChanged(_plexTrack, _subsonicTrack('2'));
      await reporter.onTrackChanged(null, _subsonicTrack('2'));
      await reporter.onTrackChanged(_localTrack, null);

      expect(client.scrobbles, isEmpty);
    });

    group('never reports for what it cannot own', () {
      test('a non-Subsonic track is a silent no-op on every event', () async {
        final reporter = build();

        for (final Track track in <Track>[_plexTrack, _localTrack]) {
          await reporter.onPlaybackStarted(track, Duration.zero, _duration);
          await reporter.onPlaybackProgress(track, _playedEnough, _duration);
          await reporter.onPlaybackPaused(track, _playedEnough, _duration);
          await reporter.onPlaybackResumed(track, _playedEnough, _duration);
          await reporter.onPlaybackStopped(track, _duration, _duration);
        }

        expect(client.scrobbles, isEmpty);
      });

      test('a subsonic: uri with a blank id is a silent no-op', () async {
        const Track corrupt = Track(id: 'x', title: 'x', uri: 'subsonic: ');

        await build().onPlaybackStarted(corrupt, Duration.zero, _duration);

        expect(client.scrobbles, isEmpty);
      });

      test('signed out (no session) is a silent no-op', () async {
        session = null;

        await build()
            .onPlaybackStarted(_subsonicTrack('1'), Duration.zero, _duration);

        expect(client.scrobbles, isEmpty);
      });
    });

    test(
        'reads the live session at event time (sign-out mid-play stops '
        'reporting; reconnect picks the new server up)', () async {
      final reporter = build();
      final Track track = _subsonicTrack('1');

      await reporter.onPlaybackStarted(track, Duration.zero, _duration);
      session = null;
      await reporter.onPlaybackResumed(track, _playedLittle, _duration);
      session = _session.copyWith(baseUrl: 'https://other.example.com');
      await reporter.onPlaybackResumed(track, _playedLittle, _duration);

      expect(client.scrobbles, hasLength(2));
      expect(client.lastScrobbleSession?.baseUrl, 'https://other.example.com');
    });

    group('reporting is best-effort and never throws', () {
      test('a typed Subsonic failure is swallowed', () async {
        client.scrobbleError = SubsonicException.notReachable();

        await expectLater(
          build()
              .onPlaybackStarted(_subsonicTrack('1'), Duration.zero, _duration),
          completes,
        );
        // The attempt was made; the failure stayed inside the reporter.
        expect(client.scrobbles, hasLength(1));
      });

      test('a server without scrobble support is swallowed on every event',
          () async {
        // A server that doesn't implement scrobble answers with a Subsonic
        // error envelope, which the client maps to a typed exception.
        client.scrobbleError = SubsonicException.unsupportedResponse();
        final reporter = build();
        final Track track = _subsonicTrack('1');

        await expectLater(
            reporter.onPlaybackStarted(track, Duration.zero, _duration),
            completes);
        await expectLater(
            reporter.onPlaybackResumed(track, _playedEnough, _duration),
            completes);
        await expectLater(
            reporter.onPlaybackStopped(track, _duration, _duration), completes);
        await expectLater(reporter.onTrackChanged(track, null), completes);
      });

      test('an untyped failure is swallowed too', () async {
        client.scrobbleUnexpectedError = StateError('boom $_token');

        await expectLater(
          build()
              .onPlaybackStarted(_subsonicTrack('1'), Duration.zero, _duration),
          completes,
        );
      });
    });

    test(
        'credential safety: the credential goes only to the client seam, and '
        'no failure path can surface it', () async {
      // Force every failure kind through the reporter with the real token in
      // play; nothing may escape (the reporter never throws), so there is no
      // error object, message, or return value a credential could ride out on.
      for (final SubsonicException error in <SubsonicException>[
        SubsonicException.unauthorized(),
        SubsonicException.notReachable(),
        SubsonicException.serverError(500),
        SubsonicException.unsupportedResponse(),
      ]) {
        client = FakeSubsonicClient()..scrobbleError = error;
        Object? escaped;
        try {
          await build()
              .onPlaybackStarted(_subsonicTrack('1'), Duration.zero, _duration);
        } catch (e) {
          escaped = e;
        }
        expect(escaped, isNull,
            reason: 'reporting must never throw (${error.kind})');
        // The credential was used solely inside the session handed to the
        // client.
        expect(client.lastScrobbleSession?.token, _token);
      }
    });

    test('scrobbled values stay credential-free (songId is not a URL or token)',
        () async {
      await build().onPlaybackStarted(
          _subsonicTrack('song-9'), Duration.zero, _duration);

      final scrobble = client.scrobbles.single;
      expect(scrobble.songId, isNot(contains(_token)));
      expect(scrobble.songId, isNot(contains('http')));
    });

    group('playedEnoughToSubmit', () {
      const Duration threeMinutes = Duration(minutes: 3);

      test('half the track counts', () {
        expect(
          SubsonicPlaybackReporter.playedEnoughToSubmit(
              const Duration(seconds: 90), threeMinutes),
          isTrue,
        );
      });

      test('just under half does not count', () {
        expect(
          SubsonicPlaybackReporter.playedEnoughToSubmit(
              const Duration(seconds: 89), threeMinutes),
          isFalse,
        );
      });

      test('the four-minute floor counts regardless of duration', () {
        expect(
          SubsonicPlaybackReporter.playedEnoughToSubmit(
              const Duration(minutes: 4), const Duration(minutes: 60)),
          isTrue,
        );
        expect(
          SubsonicPlaybackReporter.playedEnoughToSubmit(
              const Duration(minutes: 4), Duration.zero),
          isTrue,
        );
      });

      test('zero position never counts', () {
        expect(
          SubsonicPlaybackReporter.playedEnoughToSubmit(
              Duration.zero, threeMinutes),
          isFalse,
        );
        expect(
          SubsonicPlaybackReporter.playedEnoughToSubmit(
              Duration.zero, Duration.zero),
          isFalse,
        );
      });
    });
  });
}
