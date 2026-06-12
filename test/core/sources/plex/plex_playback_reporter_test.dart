import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_playback_reporter.dart';

import 'fake_plex_client.dart';

const String _token = 'super-secret-plex-token';

const PlexSession _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'machine-1',
);

Track _plexTrack(String ratingKey) => Track(
      id: 'plex-$ratingKey',
      title: 'Song $ratingKey',
      uri: 'plex:$ratingKey',
      duration: const Duration(minutes: 3),
    );

const Track _jellyfinTrack =
    Track(id: 'jf-1', title: 'Elsewhere', uri: 'jellyfin:item-1');

const Duration _position = Duration(seconds: 42);
const Duration _duration = Duration(minutes: 3);

void main() {
  group('PlexPlaybackReporter', () {
    late FakePlexClient client;
    PlexSession? session = _session;

    setUp(() {
      client = FakePlexClient();
      session = _session;
    });

    PlexPlaybackReporter build() => PlexPlaybackReporter(
          session: () => session,
          client: () => client,
        );

    test('handles only plex: tracks', () {
      final reporter = build();
      expect(reporter.handles(_plexTrack('42')), isTrue);
      expect(reporter.handles(_jellyfinTrack), isFalse);
    });

    test('started reports a playing timeline with the ratingKey', () async {
      await build().onPlaybackStarted(_plexTrack('4242'), _position, _duration);

      expect(client.timelineReports, hasLength(1));
      final report = client.timelineReports.single;
      expect(report.ratingKey, '4242');
      expect(report.state, PlexTimelineState.playing);
      expect(report.time, _position);
      expect(report.duration, _duration);
      expect(client.lastBaseUrl, _session.baseUrl);
      expect(client.lastToken, _token);
    });

    test('progress and resume report playing; pause paused; stop stopped',
        () async {
      final reporter = build();
      final Track track = _plexTrack('7');

      await reporter.onPlaybackProgress(track, _position, _duration);
      await reporter.onPlaybackPaused(track, _position, _duration);
      await reporter.onPlaybackResumed(track, _position, _duration);
      await reporter.onPlaybackStopped(track, _position, _duration);

      expect(
        client.timelineReports.map((r) => r.state),
        <PlexTimelineState>[
          PlexTimelineState.playing,
          PlexTimelineState.paused,
          PlexTimelineState.playing,
          PlexTimelineState.stopped,
        ],
      );
    });

    test('an unknown duration is omitted, never reported as zero', () async {
      await build()
          .onPlaybackStarted(_plexTrack('9'), _position, Duration.zero);

      expect(client.timelineReports.single.duration, isNull);
    });

    test('a track change closes the outgoing Plex track at its last position',
        () async {
      final reporter = build();
      final Track previous = _plexTrack('1');

      await reporter.onPlaybackStarted(previous, Duration.zero, _duration);
      await reporter.onPlaybackProgress(
          previous, const Duration(seconds: 65), _duration);
      await reporter.onTrackChanged(previous, _plexTrack('2'));

      final report = client.timelineReports.last;
      expect(report.ratingKey, '1');
      expect(report.state, PlexTimelineState.stopped);
      expect(report.time, const Duration(seconds: 65));
      expect(report.duration, _duration);
    });

    test('a track change with no remembered position stops at zero', () async {
      await build().onTrackChanged(_plexTrack('1'), null);

      final report = client.timelineReports.single;
      expect(report.state, PlexTimelineState.stopped);
      expect(report.time, Duration.zero);
      expect(report.duration, isNull);
    });

    test('a track change from a non-Plex track reports nothing', () async {
      final reporter = build();

      await reporter.onTrackChanged(_jellyfinTrack, _plexTrack('2'));
      await reporter.onTrackChanged(null, _plexTrack('2'));

      expect(client.timelineReports, isEmpty);
    });

    group('never reports for what it cannot own', () {
      test('a non-Plex track is a silent no-op on every event', () async {
        final reporter = build();

        await reporter.onPlaybackStarted(_jellyfinTrack, _position, _duration);
        await reporter.onPlaybackProgress(_jellyfinTrack, _position, _duration);
        await reporter.onPlaybackPaused(_jellyfinTrack, _position, _duration);
        await reporter.onPlaybackResumed(_jellyfinTrack, _position, _duration);
        await reporter.onPlaybackStopped(_jellyfinTrack, _position, _duration);

        expect(client.timelineReports, isEmpty);
      });

      test('a plex: uri with a blank ratingKey is a silent no-op', () async {
        const Track corrupt = Track(id: 'x', title: 'x', uri: 'plex: ');

        await build().onPlaybackStarted(corrupt, _position, _duration);

        expect(client.timelineReports, isEmpty);
      });

      test('signed out (no session) is a silent no-op', () async {
        session = null;

        await build().onPlaybackStarted(_plexTrack('1'), _position, _duration);

        expect(client.timelineReports, isEmpty);
      });
    });

    test(
        'reads the live session at event time (sign-out mid-play stops '
        'reporting; reconnect picks the new server up)', () async {
      final reporter = build();
      final Track track = _plexTrack('1');

      await reporter.onPlaybackStarted(track, _position, _duration);
      session = null;
      await reporter.onPlaybackProgress(track, _position, _duration);
      session = _session.copyWith(baseUrl: 'https://other.example.com:32400');
      await reporter.onPlaybackPaused(track, _position, _duration);

      expect(client.timelineReports, hasLength(2));
      expect(client.lastBaseUrl, 'https://other.example.com:32400');
    });

    group('reporting is best-effort and never throws', () {
      test('a typed Plex failure is swallowed', () async {
        client.timelineError = PlexException.notReachable();

        await expectLater(
          build().onPlaybackStarted(_plexTrack('1'), _position, _duration),
          completes,
        );
        // The attempt was made; the failure stayed inside the reporter.
        expect(client.timelineReports, hasLength(1));
      });

      test('every lifecycle event swallows a failing server', () async {
        client.timelineError = PlexException.unauthorized();
        final reporter = build();
        final Track track = _plexTrack('1');

        await expectLater(
            reporter.onPlaybackStarted(track, _position, _duration), completes);
        await expectLater(
            reporter.onPlaybackProgress(track, _position, _duration),
            completes);
        await expectLater(
            reporter.onPlaybackPaused(track, _position, _duration), completes);
        await expectLater(
            reporter.onPlaybackResumed(track, _position, _duration), completes);
        await expectLater(
            reporter.onPlaybackStopped(track, _position, _duration), completes);
        await expectLater(reporter.onTrackChanged(track, null), completes);
      });

      test('an untyped failure is swallowed too', () async {
        client.timelineUnexpectedError = StateError('boom $_token');

        await expectLater(
          build().onPlaybackStarted(_plexTrack('1'), _position, _duration),
          completes,
        );
      });
    });

    test(
        'token safety: the token goes only to the client seam, and no '
        'failure path can surface it', () async {
      // Force every failure kind through the reporter with the real token in
      // play; nothing may escape (the reporter never throws), so there is no
      // error object, message, or return value a token could ride out on.
      for (final PlexException error in <PlexException>[
        PlexException.unauthorized(),
        PlexException.notReachable(),
        PlexException.serverError(500),
        PlexException.notFound(),
      ]) {
        client = FakePlexClient()..timelineError = error;
        Object? escaped;
        try {
          await build()
              .onPlaybackStarted(_plexTrack('1'), _position, _duration);
        } catch (e) {
          escaped = e;
        }
        expect(escaped, isNull,
            reason: 'reporting must never throw (${error.kind})');
        // The token was used solely as the client-call credential.
        expect(client.lastToken, _token);
      }
    });

    test(
        'reported values stay credential-free (ratingKey is not a URL or '
        'token)', () async {
      await build().onPlaybackStarted(_plexTrack('4242'), _position, _duration);

      final report = client.timelineReports.single;
      expect(report.ratingKey, isNot(contains(_token)));
      expect(report.ratingKey, isNot(contains('http')));
    });
  });
}
