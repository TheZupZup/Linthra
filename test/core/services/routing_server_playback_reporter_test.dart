import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/routing_server_playback_reporter.dart';
import 'package:linthra/core/services/server_playback_reporter.dart';

/// Records every call routed to it, claiming only tracks whose uri starts
/// with [scheme] — the shape of a real provider reporter (Plex claims `plex:`).
class _SchemeReporter implements ServerPlaybackReporter {
  _SchemeReporter(this.scheme);

  final String scheme;
  final List<String> events = <String>[];

  @override
  bool handles(Track track) => track.uri.startsWith(scheme);

  @override
  Future<void> onPlaybackStarted(
      Track track, Duration position, Duration duration) async {
    events.add('started:${track.id}');
  }

  @override
  Future<void> onPlaybackProgress(
      Track track, Duration position, Duration duration) async {
    events.add('progress:${track.id}');
  }

  @override
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration) async {
    events.add('paused:${track.id}');
  }

  @override
  Future<void> onPlaybackResumed(
      Track track, Duration position, Duration duration) async {
    events.add('resumed:${track.id}');
  }

  @override
  Future<void> onPlaybackStopped(
      Track track, Duration position, Duration duration) async {
    events.add('stopped:${track.id}');
  }

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {
    events.add('changed:${previousTrack?.id}->${nextTrack?.id}');
  }
}

Track _plex(String id) => Track(id: id, title: id, uri: 'plex:$id');
Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _local(String id) =>
    Track(id: id, title: id, uri: 'file:///music/$id.flac');

void main() {
  group('RoutingServerPlaybackReporter', () {
    late _SchemeReporter plex;
    late RoutingServerPlaybackReporter router;

    setUp(() {
      plex = _SchemeReporter('plex:');
      router = RoutingServerPlaybackReporter(<ServerPlaybackReporter>[plex]);
    });

    test('routes every event of a plex: track to the Plex reporter', () async {
      final Track track = _plex('a');
      const Duration p = Duration(seconds: 3);
      const Duration d = Duration(minutes: 3);

      await router.onPlaybackStarted(track, p, d);
      await router.onPlaybackProgress(track, p, d);
      await router.onPlaybackPaused(track, p, d);
      await router.onPlaybackResumed(track, p, d);
      await router.onPlaybackStopped(track, p, d);

      expect(plex.events, <String>[
        'started:a',
        'progress:a',
        'paused:a',
        'resumed:a',
        'stopped:a',
      ]);
    });

    test('non-Plex tracks never reach the Plex reporter', () async {
      for (final Track track in <Track>[_jellyfin('j'), _local('l')]) {
        await router.onPlaybackStarted(track, Duration.zero, Duration.zero);
        await router.onPlaybackProgress(track, Duration.zero, Duration.zero);
        await router.onPlaybackPaused(track, Duration.zero, Duration.zero);
        await router.onPlaybackResumed(track, Duration.zero, Duration.zero);
        await router.onPlaybackStopped(track, Duration.zero, Duration.zero);
        await router.onTrackChanged(track, track);
      }

      expect(plex.events, isEmpty);
    });

    test('an unclaimed track is silently dropped (no reporter, no error)',
        () async {
      await expectLater(
        router.onPlaybackStarted(_local('l'), Duration.zero, Duration.zero),
        completes,
      );
    });

    test('the first reporter claiming a track wins', () async {
      final _SchemeReporter first = _SchemeReporter('plex:');
      final _SchemeReporter second = _SchemeReporter('plex:');
      final RoutingServerPlaybackReporter routed =
          RoutingServerPlaybackReporter(
              <ServerPlaybackReporter>[first, second]);

      await routed.onPlaybackStarted(_plex('a'), Duration.zero, Duration.zero);

      expect(first.events, <String>['started:a']);
      expect(second.events, isEmpty);
    });

    group('onTrackChanged across providers', () {
      late _SchemeReporter jellyfin;
      late RoutingServerPlaybackReporter mixed;

      setUp(() {
        jellyfin = _SchemeReporter('jellyfin:');
        mixed = RoutingServerPlaybackReporter(
            <ServerPlaybackReporter>[plex, jellyfin]);
      });

      test('a plex → local change reaches the Plex reporter (to close it)',
          () async {
        await mixed.onTrackChanged(_plex('a'), _local('l'));

        expect(plex.events, <String>['changed:a->l']);
        expect(jellyfin.events, isEmpty);
      });

      test('a local → plex change reaches the Plex reporter once', () async {
        await mixed.onTrackChanged(_local('l'), _plex('a'));

        expect(plex.events, <String>['changed:l->a']);
      });

      test('a plex → plex change is forwarded once, not twice', () async {
        await mixed.onTrackChanged(_plex('a'), _plex('b'));

        expect(plex.events, <String>['changed:a->b']);
      });

      test('a cross-provider change reaches both owners', () async {
        await mixed.onTrackChanged(_plex('a'), _jellyfin('j'));

        expect(plex.events, <String>['changed:a->j']);
        expect(jellyfin.events, <String>['changed:a->j']);
      });

      test('a change to nothing (queue ended) still reaches the owner',
          () async {
        await mixed.onTrackChanged(_plex('a'), null);

        expect(plex.events, <String>['changed:a->null']);
      });
    });

    test('NoOpServerPlaybackReporter claims everything and does nothing', () {
      const NoOpServerPlaybackReporter noOp = NoOpServerPlaybackReporter();
      expect(noOp.handles(_plex('a')), isTrue);
      expect(noOp.handles(_local('l')), isTrue);
      // The methods complete without effect (nothing observable to assert
      // beyond completion — that is the point).
      expect(
        noOp.onPlaybackStarted(_local('l'), Duration.zero, Duration.zero),
        completes,
      );
    });
  });
}
