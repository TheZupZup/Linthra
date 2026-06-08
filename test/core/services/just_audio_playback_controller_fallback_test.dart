import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/playback_source_label.dart';

/// A fake engine that records what it was asked to open and can be told to fail
/// opening specific URLs (a "couldn't start playback" failure), without touching
/// any platform channel. Only the members the controller uses are overridden.
class _FakePlayer extends Fake implements AudioPlayer {
  _FakePlayer({this.failUrls = const <String>{}});

  /// Resolved URLs whose [setUrl] should throw, simulating an engine that can
  /// resolve a stream but fail to open it.
  final Set<String> failUrls;
  final List<String> setUrlCalls = <String>[];

  @override
  Stream<PlayerState> get playerStateStream =>
      const Stream<PlayerState>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      const Stream<PlaybackEvent>.empty();

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    setUrlCalls.add(url);
    if (failUrls.contains(url)) throw Exception('engine could not open source');
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

/// A fake resolver driven by the track's opaque uri: a uri in [resolveFailures]
/// throws (server down / session expired); one in [resolved] returns its mapped
/// [ResolvedPlayable]; anything else throws a generic, safe failure.
class _FakeResolver implements PlayableUriResolver {
  _FakeResolver({
    this.resolved = const <String, ResolvedPlayable>{},
    this.resolveFailures = const <String>{},
  });

  final Map<String, ResolvedPlayable> resolved;
  final Set<String> resolveFailures;
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    if (resolveFailures.contains(track.uri)) {
      throw const PlaybackResolutionException(
        'That source needs attention.',
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    final ResolvedPlayable? r = resolved[track.uri];
    if (r == null) {
      throw const PlaybackResolutionException(
        "Couldn't reach this source.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    return r;
  }
}

Track _track(String id, String uri) => Track(
      id: id,
      title: 'Hello',
      uri: uri,
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

ResolvedPlayable _stream(String url) =>
    ResolvedPlayable(Uri.parse(url), PlaybackSource.streamingDirect);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A song available on both providers. Which one is the displayed/primary copy
  // depends on the default source; the candidate list is ordered to match.
  final Track jelly = _track('j', 'jellyfin:j');
  final Track sub = _track('s', 'subsonic:s');

  JustAudioPlaybackController build({
    required _FakePlayer player,
    required _FakeResolver resolver,
    required Map<String, List<Track>> candidates,
  }) {
    final controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: MapPlaybackCandidateSource(() => candidates),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('runtime source fallback', () {
    test('default Jellyfin fails to resolve → plays Navidrome, shows Navidrome',
        () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolveFailures: <String>{'jellyfin:j'},
        resolved: <String, ResolvedPlayable>{
          'subsonic:s': _stream('https://sub/stream/s'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        // Jellyfin is the default, so it leads the candidate order.
        candidates: <String, List<Track>>{
          'j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);

      final PlaybackState s = controller.state;
      expect(s.currentTrack?.uri, 'subsonic:s');
      expect(s.source, PlaybackSource.streamingDirect);
      // The indicator reflects the copy that actually started.
      expect(
        PlaybackSourceLabel.of(trackUri: s.currentTrack?.uri, source: s.source),
        'Navidrome',
      );
      // Each candidate tried at most once, in order.
      expect(resolver.calls, <String>['jellyfin:j', 'subsonic:s']);
    });

    test('default Navidrome fails → plays Jellyfin, shows Jellyfin', () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolveFailures: <String>{'subsonic:s'},
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        // Navidrome is the default, so the displayed copy is the Subsonic one.
        candidates: <String, List<Track>>{
          's': <Track>[sub, jelly],
        },
      );

      await controller.playTracks(<Track>[sub]);

      final PlaybackState s = controller.state;
      expect(s.currentTrack?.uri, 'jellyfin:j');
      expect(s.source, PlaybackSource.streamingDirect);
      expect(
        PlaybackSourceLabel.of(trackUri: s.currentTrack?.uri, source: s.source),
        'Jellyfin',
      );
      expect(resolver.calls, <String>['subsonic:s', 'jellyfin:j']);
    });

    test('a preferred copy that resolves but won\'t start falls back',
        () async {
      // Jellyfin resolves fine, but the engine can't open its stream URL — a
      // "start playback" failure, which must also trigger fallback.
      final player = _FakePlayer(failUrls: <String>{'https://jelly/stream/j'});
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
          'subsonic:s': _stream('https://sub/stream/s'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);

      expect(controller.state.currentTrack?.uri, 'subsonic:s');
      expect(controller.state.source, PlaybackSource.streamingDirect);
      // It really tried to open Jellyfin first, then Navidrome.
      expect(player.setUrlCalls,
          <String>['https://jelly/stream/j', 'https://sub/stream/s']);
    });

    test('the preferred copy succeeding never attempts a fallback', () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j': _stream('https://jelly/stream/j'),
          'subsonic:s': _stream('https://sub/stream/s'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);

      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
      // The secondary copy was never resolved or opened.
      expect(resolver.calls, <String>['jellyfin:j']);
      expect(player.setUrlCalls, <String>['https://jelly/stream/j']);
    });

    test('a cached preferred copy wins first (cache behaviour preserved)',
        () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          // The offline-first resolver reports a cache hit for the preferred
          // copy; fallback must not override that.
          'jellyfin:j': ResolvedPlayable(
            Uri.file('/cache/j.mp3'),
            PlaybackSource.offlineCache,
          ),
          'subsonic:s': _stream('https://sub/stream/s'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);

      expect(controller.state.currentTrack?.uri, 'jellyfin:j');
      expect(controller.state.source, PlaybackSource.offlineCache);
      expect(resolver.calls, <String>['jellyfin:j']);
    });

    test('all candidates failing shows one clear, safe error', () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolveFailures: <String>{'jellyfin:j', 'subsonic:s'},
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly]);

      final PlaybackState s = controller.state;
      expect(s.status, PlaybackStatus.error);
      expect(s.errorMessage,
          "Couldn't play this track from any available source.");
      // No URLs/credentials in the surfaced message.
      expect(s.errorMessage, isNot(contains('http')));
      // Each candidate was tried exactly once — no looping.
      expect(resolver.calls, <String>['jellyfin:j', 'subsonic:s']);
    });
  });

  group('single-source playback is unchanged', () {
    test('a local-only track plays from its file with no fallback', () async {
      final Track local = _track('l', '/music/one.mp3');
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          '/music/one.mp3': ResolvedPlayable(
              Uri.file('/music/one.mp3'), PlaybackSource.localFile),
        },
      );
      // No candidate entry for a single-source track.
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[local]);

      expect(controller.state.currentTrack?.uri, '/music/one.mp3');
      expect(controller.state.source, PlaybackSource.localFile);
      expect(resolver.calls, <String>['/music/one.mp3']);
    });

    test('a single-source failure keeps its own specific message', () async {
      final Track local = _track('l', '/music/one.mp3');
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolveFailures: <String>{'/music/one.mp3'},
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[local]);

      expect(controller.state.status, PlaybackStatus.error);
      // Not collapsed to the generic multi-source message.
      expect(controller.state.errorMessage, 'That source needs attention.');
    });
  });

  group('queue reflects the copy that actually started', () {
    test('up-next is preserved and the current entry becomes the fallback',
        () async {
      final Track other = _track('o', 'jellyfin:o');
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolveFailures: <String>{'jellyfin:j'},
        resolved: <String, ResolvedPlayable>{
          'subsonic:s': _stream('https://sub/stream/s'),
          'jellyfin:o': _stream('https://jelly/stream/o'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: <String, List<Track>>{
          'j': <Track>[jelly, sub],
        },
      );

      await controller.playTracks(<Track>[jelly, other]);

      // The current entry is now the Navidrome copy; the rest of the queue is
      // untouched.
      expect(controller.state.currentTrack?.uri, 'subsonic:s');
      expect(controller.state.upNext.map((Track t) => t.uri).toList(),
          <String>['jellyfin:o']);
    });
  });
}
