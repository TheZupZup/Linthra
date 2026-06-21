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

ResolvedPlayable _cache(String path) =>
    ResolvedPlayable(Uri.file(path), PlaybackSource.offlineCache);

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
    _FakeResolver? streamResolver,
  }) {
    final controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: MapPlaybackCandidateSource(() => candidates),
      // Null by default, so every existing test keeps the original behavior; the
      // offline-cache fallback group passes a real one.
      streamingFallbackResolver: streamResolver,
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
          'jellyfin:j': <Track>[jelly, sub],
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
          'subsonic:s': <Track>[sub, jelly],
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
          'jellyfin:j': <Track>[jelly, sub],
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
          'jellyfin:j': <Track>[jelly, sub],
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
          'jellyfin:j': <Track>[jelly, sub],
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
          'jellyfin:j': <Track>[jelly, sub],
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

  group('offline-cache load failure falls back to streaming', () {
    // A Plex track with a cached copy and no sibling copy on another provider —
    // its own only candidate, so cross-provider fallback can't save it.
    final Track plex = _track('p', 'plex:101');

    test('a single-source cached copy that won\'t open streams the same track',
        () async {
      // The primary resolver reports a cache hit (a file://), but the engine
      // can't open that file — corrupt, or reclaimed after the existence check.
      final player = _FakePlayer(failUrls: <String>{'file:///cache/p.flac'});
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _cache('/cache/p.flac'),
        },
      );
      // The streaming fallback resolves the *same* track to its live stream.
      final streamResolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _stream('https://plex/stream/101'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        streamResolver: streamResolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[plex]);

      final PlaybackState s = controller.state;
      expect(s.currentTrack?.uri, 'plex:101');
      expect(s.source, PlaybackSource.streamingDirect);
      expect(s.status, isNot(PlaybackStatus.error));
      // It really tried the cache file first, then the stream — each once.
      expect(player.setUrlCalls,
          <String>['file:///cache/p.flac', 'https://plex/stream/101']);
    });

    test('a cached copy that won\'t open and a dead stream errors, no loop',
        () async {
      final player = _FakePlayer(failUrls: <String>{
        'file:///cache/p.flac',
        'https://plex/stream/101',
      });
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _cache('/cache/p.flac'),
        },
      );
      final streamResolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _stream('https://plex/stream/101'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        streamResolver: streamResolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[plex]);

      expect(controller.state.status, PlaybackStatus.error);
      // Cache, then stream — each tried exactly once.
      expect(player.setUrlCalls,
          <String>['file:///cache/p.flac', 'https://plex/stream/101']);
    });

    test('a cache hit that opens never consults the streaming fallback',
        () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _cache('/cache/p.flac'),
        },
      );
      final streamResolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _stream('https://plex/stream/101'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        streamResolver: streamResolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[plex]);

      expect(controller.state.source, PlaybackSource.offlineCache);
      // The healthy cache copy played; the stream was never resolved or opened.
      expect(streamResolver.calls, isEmpty);
      expect(player.setUrlCalls, <String>['file:///cache/p.flac']);
    });

    test('without a streaming fallback, a failed cache load behaves as before',
        () async {
      // The additive guarantee: with no fallback resolver wired (the default and
      // in tests), a single-source cache failure still surfaces an error exactly
      // as it did before — so nothing regresses.
      final player = _FakePlayer(failUrls: <String>{'file:///cache/p.flac'});
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'plex:101': _cache('/cache/p.flac'),
        },
      );
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: const <String, List<Track>>{},
      );

      await controller.playTracks(<Track>[plex]);

      expect(controller.state.status, PlaybackStatus.error);
      expect(player.setUrlCalls, <String>['file:///cache/p.flac']);
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
          'jellyfin:j': <Track>[jelly, sub],
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

  // Regression: when the user changes the default source mid-queue, the candidate
  // source recomputes under the controller (it reads it lazily). End-of-track
  // continuation must pick up the new order for the *next* queued copy — and must
  // never get stuck on stale source state. The map is keyed by every copy's uri,
  // so a queued Jellyfin copy still resolves to its candidates after the switch.
  group('end-of-track continuation after a source change', () {
    final Track j1 = _track('j1', 'jellyfin:j1');
    final Track s1 = _track('s1', 'subsonic:s1');
    final Track j2 = _track('j2', 'jellyfin:j2');
    final Track s2 = _track('s2', 'subsonic:s2');

    // The live candidate map, keyed by every copy's uri (what
    // playbackCandidatesProvider produces). Mutated in place to model a switch.
    Map<String, List<Track>> jellyfinFirst() => <String, List<Track>>{
          'jellyfin:j1': <Track>[j1, s1],
          'subsonic:s1': <Track>[j1, s1],
          'jellyfin:j2': <Track>[j2, s2],
          'subsonic:s2': <Track>[j2, s2],
        };
    Map<String, List<Track>> subsonicFirst() => <String, List<Track>>{
          'jellyfin:j1': <Track>[s1, j1],
          'subsonic:s1': <Track>[s1, j1],
          'jellyfin:j2': <Track>[s2, j2],
          'subsonic:s2': <Track>[s2, j2],
        };

    void completeCurrent(JustAudioPlaybackController controller) {
      // Mirrors just_audio reporting the track reached its natural end.
      controller
          .handleEngineState(PlayerState(false, ProcessingState.completed));
    }

    test('the next queued copy uses the newly chosen source', () async {
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j1': _stream('https://jelly/stream/j1'),
          'jellyfin:j2': _stream('https://jelly/stream/j2'),
          'subsonic:s1': _stream('https://sub/stream/s1'),
          'subsonic:s2': _stream('https://sub/stream/s2'),
        },
      );
      final Map<String, List<Track>> candidates = jellyfinFirst();
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: candidates,
      );

      // Plays the queue under the default (Automatic) order: Jellyfin first.
      await controller.playTracks(<Track>[j1, j2]);
      expect(controller.state.currentTrack?.uri, 'jellyfin:j1');

      // The user switches the default source to Navidrome/Subsonic. The live
      // candidate map recomputes in place under the session-pinned controller.
      candidates
        ..clear()
        ..addAll(subsonicFirst());

      // The first track finishes and the queue advances.
      completeCurrent(controller);
      await Future<void>.delayed(Duration.zero);

      // Continuation used the newly chosen source for the next track.
      expect(controller.state.currentTrack?.uri, 'subsonic:s2');
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('continuation still falls back when the new source fails', () async {
      // After the switch Subsonic leads, but the Subsonic copy of song 2 is
      // unreachable — continuation must fall back to Jellyfin rather than stall.
      final player = _FakePlayer();
      final resolver = _FakeResolver(
        resolveFailures: <String>{'subsonic:s2'},
        resolved: <String, ResolvedPlayable>{
          'jellyfin:j1': _stream('https://jelly/stream/j1'),
          'jellyfin:j2': _stream('https://jelly/stream/j2'),
          'subsonic:s1': _stream('https://sub/stream/s1'),
        },
      );
      final Map<String, List<Track>> candidates = jellyfinFirst();
      final controller = build(
        player: player,
        resolver: resolver,
        candidates: candidates,
      );

      await controller.playTracks(<Track>[j1, j2]);
      candidates
        ..clear()
        ..addAll(subsonicFirst());

      completeCurrent(controller);
      await Future<void>.delayed(Duration.zero);

      // It tried Subsonic first, then fell back to Jellyfin — playback continues.
      expect(controller.state.currentTrack?.uri, 'jellyfin:j2');
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });
  });
}
