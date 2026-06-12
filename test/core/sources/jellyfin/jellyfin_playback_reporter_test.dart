import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playback_reporter.dart';

import 'fake_jellyfin_client.dart';

const String _token = 'super-secret-jellyfin-token';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://jellyfin.example.com',
  userId: 'user-1',
  accessToken: _token,
  deviceId: 'device-1',
);

Track _jellyfinTrack(String itemId) => Track(
      id: 'jf-$itemId',
      title: 'Song $itemId',
      uri: 'jellyfin:$itemId',
      duration: const Duration(minutes: 3),
    );

const Track _plexTrack = Track(id: 'plex-1', title: 'Elsewhere', uri: 'plex:1');
const Track _localTrack =
    Track(id: 'local-1', title: 'On disk', uri: 'file:///music/song.flac');

const Duration _position = Duration(seconds: 42);
const Duration _duration = Duration(minutes: 3);

void main() {
  group('JellyfinPlaybackReporter', () {
    late FakeJellyfinClient client;
    JellyfinSession? session = _session;

    setUp(() {
      client = FakeJellyfinClient();
      session = _session;
    });

    JellyfinPlaybackReporter build() => JellyfinPlaybackReporter(
          session: () => session,
          client: () => client,
        );

    test('handles only jellyfin: tracks', () {
      final reporter = build();
      expect(reporter.handles(_jellyfinTrack('42')), isTrue);
      expect(reporter.handles(_plexTrack), isFalse);
      expect(reporter.handles(_localTrack), isFalse);
    });

    test('started reports a start event with the itemId and position',
        () async {
      await build()
          .onPlaybackStarted(_jellyfinTrack('item-1'), _position, _duration);

      expect(client.playbackReports, hasLength(1));
      final report = client.playbackReports.single;
      expect(report.itemId, 'item-1');
      expect(report.event, JellyfinPlaybackEvent.started);
      expect(report.position, _position);
      expect(client.lastReportSession, _session);
    });

    test('progress, pause, resume, and stop map to their events', () async {
      final reporter = build();
      final Track track = _jellyfinTrack('7');

      await reporter.onPlaybackProgress(track, _position, _duration);
      await reporter.onPlaybackPaused(track, _position, _duration);
      await reporter.onPlaybackResumed(track, _position, _duration);
      await reporter.onPlaybackStopped(track, _position, _duration);

      expect(
        client.playbackReports.map((r) => r.event),
        <JellyfinPlaybackEvent>[
          JellyfinPlaybackEvent.progress,
          JellyfinPlaybackEvent.paused,
          JellyfinPlaybackEvent.resumed,
          JellyfinPlaybackEvent.stopped,
        ],
      );
    });

    test(
        'a track change closes the outgoing Jellyfin track at its last '
        'position', () async {
      final reporter = build();
      final Track previous = _jellyfinTrack('1');

      await reporter.onPlaybackStarted(previous, Duration.zero, _duration);
      await reporter.onPlaybackProgress(
          previous, const Duration(seconds: 65), _duration);
      await reporter.onTrackChanged(previous, _jellyfinTrack('2'));

      final report = client.playbackReports.last;
      expect(report.itemId, '1');
      expect(report.event, JellyfinPlaybackEvent.stopped);
      expect(report.position, const Duration(seconds: 65));
    });

    test('a track change with no remembered position stops at zero', () async {
      await build().onTrackChanged(_jellyfinTrack('1'), null);

      final report = client.playbackReports.single;
      expect(report.event, JellyfinPlaybackEvent.stopped);
      expect(report.position, Duration.zero);
    });

    test('a track change from another provider reports nothing', () async {
      final reporter = build();

      await reporter.onTrackChanged(_plexTrack, _jellyfinTrack('2'));
      await reporter.onTrackChanged(null, _jellyfinTrack('2'));

      expect(client.playbackReports, isEmpty);
    });

    group('never reports for what it cannot own', () {
      test('a non-Jellyfin track is a silent no-op on every event', () async {
        final reporter = build();

        for (final Track track in <Track>[_plexTrack, _localTrack]) {
          await reporter.onPlaybackStarted(track, _position, _duration);
          await reporter.onPlaybackProgress(track, _position, _duration);
          await reporter.onPlaybackPaused(track, _position, _duration);
          await reporter.onPlaybackResumed(track, _position, _duration);
          await reporter.onPlaybackStopped(track, _position, _duration);
        }

        expect(client.playbackReports, isEmpty);
      });

      test('a jellyfin: uri with a blank itemId is a silent no-op', () async {
        const Track corrupt = Track(id: 'x', title: 'x', uri: 'jellyfin: ');

        await build().onPlaybackStarted(corrupt, _position, _duration);

        expect(client.playbackReports, isEmpty);
      });

      test('signed out (no session) is a silent no-op', () async {
        session = null;

        await build()
            .onPlaybackStarted(_jellyfinTrack('1'), _position, _duration);

        expect(client.playbackReports, isEmpty);
      });
    });

    test(
        'reads the live session at event time (sign-out mid-play stops '
        'reporting; reconnect picks the new server up)', () async {
      final reporter = build();
      final Track track = _jellyfinTrack('1');

      await reporter.onPlaybackStarted(track, _position, _duration);
      session = null;
      await reporter.onPlaybackProgress(track, _position, _duration);
      session = _session.copyWith(baseUrl: 'https://other.example.com');
      await reporter.onPlaybackPaused(track, _position, _duration);

      expect(client.playbackReports, hasLength(2));
      expect(client.lastReportSession?.baseUrl, 'https://other.example.com');
    });

    group('reporting is best-effort and never throws', () {
      test('a typed Jellyfin failure is swallowed', () async {
        client.playbackReportError = JellyfinException.notReachable();

        await expectLater(
          build().onPlaybackStarted(_jellyfinTrack('1'), _position, _duration),
          completes,
        );
        // The attempt was made; the failure stayed inside the reporter.
        expect(client.playbackReports, hasLength(1));
      });

      test('every lifecycle event swallows a failing server', () async {
        client.playbackReportError = JellyfinException.unauthorized();
        final reporter = build();
        final Track track = _jellyfinTrack('1');

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
        client.playbackReportUnexpectedError = StateError('boom $_token');

        await expectLater(
          build().onPlaybackStarted(_jellyfinTrack('1'), _position, _duration),
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
      for (final JellyfinException error in <JellyfinException>[
        JellyfinException.unauthorized(),
        JellyfinException.notReachable(),
        JellyfinException.serverError(500),
        JellyfinException.notJellyfin(),
      ]) {
        client = FakeJellyfinClient()..playbackReportError = error;
        Object? escaped;
        try {
          await build()
              .onPlaybackStarted(_jellyfinTrack('1'), _position, _duration);
        } catch (e) {
          escaped = e;
        }
        expect(escaped, isNull,
            reason: 'reporting must never throw (${error.kind})');
        // The token was used solely inside the session handed to the client.
        expect(client.lastReportSession?.accessToken, _token);
      }
    });

    test('reported values stay credential-free (itemId is not a URL or token)',
        () async {
      await build()
          .onPlaybackStarted(_jellyfinTrack('item-9'), _position, _duration);

      final report = client.playbackReports.single;
      expect(report.itemId, isNot(contains(_token)));
      expect(report.itemId, isNot(contains('http')));
    });
  });
}
