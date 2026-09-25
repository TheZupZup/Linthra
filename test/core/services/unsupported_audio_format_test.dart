import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/stability_diagnostics.dart';
import 'package:linthra/core/services/stream_interruption.dart';

import '../../features/library/fake_music_library_repository.dart';

/// #674: an Android device with no decoder for a track's audio (FLAC on an API
/// 24–26 device without a platform FLAC decoder, once the bundled fallback is
/// also missing) must end in an unsupported-format error, never in the
/// "PLAYING, timer advancing, no sound, Last error: none" state.
///
/// The engine here stands in for Linthra's patched just_audio, which raises
/// Media3's ERROR_CODE_DECODING_FORMAT_UNSUPPORTED (4005) with the sample MIME
/// type when a source has audio no renderer can decode.

const String _plexStreamUrl =
    'https://plex.example:32400/library/parts/1/file.flac?X-Plex-Token=SECRET';

PlayerException _noDecoder([String mimeType = 'audio/flac']) => PlayerException(
      unsupportedAudioFormatErrorCode,
      'Unsupported audio format: no decoder on this device for $mimeType',
      <String, dynamic>{'index': 0, 'mimeType': mimeType},
    );

/// An engine that fails to open the URLs in [undecodable] the way the patched
/// just_audio does, opens everything else, and records transport calls. Its
/// event stream can inject a mid-playback engine error.
class _Engine extends Fake implements AudioPlayer {
  _Engine({this.undecodable = const <String, String>{}});

  /// URL -> sample MIME type the engine cannot decode.
  final Map<String, String> undecodable;
  final List<String> opened = <String>[];
  int playCalls = 0;

  final StreamController<PlayerState> states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> events =
      StreamController<PlaybackEvent>.broadcast();

  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    opened.add(url);
    final String? mimeType = undecodable[url];
    if (mimeType != null) throw _noDecoder(mimeType);
    return const Duration(minutes: 4);
  }

  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {
    await states.close();
    await events.close();
  }
}

class _Resolver implements PlayableUriResolver {
  _Resolver(this.byUri);

  /// Track uri -> what it resolves to; a missing entry is "offline".
  final Map<String, ResolvedPlayable> byUri;
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    final ResolvedPlayable? resolved = byUri[track.uri];
    if (resolved == null) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    return resolved;
  }
}

Track _track(String id, String uri) => Track(
      id: id,
      title: 'Track $id',
      uri: uri,
      artistName: 'Artist',
      albumName: 'Album',
      duration: const Duration(minutes: 4),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  JustAudioPlaybackController build(
    _Engine engine,
    _Resolver resolver, {
    _Resolver? streamingFallback,
  }) {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: engine,
      resolver: resolver,
      streamingFallbackResolver: streamingFallback,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  void expectUnsupportedError(PlaybackState state) {
    expect(state.status, PlaybackStatus.error);
    expect(state.failure?.kind, PlaybackFailureKind.unplayableMedia);
    expect(
      state.errorMessage,
      "This track's format isn't supported on this device.",
    );
  }

  setUp(() => StabilityDiagnostics.lastInterruptionKind = null);

  group('a track no decoder on this device can play', () {
    test('Plex FLAC stream fails as unsupported, never plays', () async {
      final _Engine engine =
          _Engine(undecodable: <String, String>{_plexStreamUrl: 'audio/flac'});
      final JustAudioPlaybackController controller = build(
        engine,
        _Resolver(<String, ResolvedPlayable>{
          'plex:1': ResolvedPlayable(
            Uri.parse(_plexStreamUrl),
            PlaybackSource.streamingDirect,
          ),
        }),
      );

      await controller.playTracks(<Track>[_track('1', 'plex:1')]);

      expectUnsupportedError(controller.state);
      expect(engine.playCalls, 0, reason: 'nothing to play, so never started');
      expect(
        StabilityDiagnostics.lastInterruptionKind,
        'unsupported-format:audio/flac',
      );
      // The tokenized URL never reaches the error or the breadcrumb.
      expect(controller.state.errorMessage, isNot(contains('SECRET')));
      expect(StabilityDiagnostics.lastInterruptionKind,
          isNot(contains('Plex-Token')));
    });

    test('local FLAC file fails as unsupported', () async {
      final Uri file = Uri.file('/music/Album/01.flac');
      final _Engine engine =
          _Engine(undecodable: <String, String>{file.toString(): 'audio/flac'});
      final JustAudioPlaybackController controller = build(
        engine,
        _Resolver(<String, ResolvedPlayable>{
          file.toString(): ResolvedPlayable(file, PlaybackSource.localFile),
        }),
      );

      await controller.playTracks(<Track>[_track('l', file.toString())]);

      expectUnsupportedError(controller.state);
      expect(engine.playCalls, 0);
    });

    test('offline cached FLAC fails as unsupported without a server', () async {
      final Uri cached = Uri.file('/cache/remote/plex_1.flac');
      final _Engine engine = _Engine(
        undecodable: <String, String>{cached.toString(): 'audio/flac'},
      );
      // The streaming fallback cannot reach the server (offline).
      final _Resolver offlineStream = _Resolver(<String, ResolvedPlayable>{});
      final JustAudioPlaybackController controller = build(
        engine,
        _Resolver(<String, ResolvedPlayable>{
          'plex:1': ResolvedPlayable(cached, PlaybackSource.offlineCache),
        }),
        streamingFallback: offlineStream,
      );

      await controller.playTracks(<Track>[_track('1', 'plex:1')]);

      expectUnsupportedError(controller.state);
      expect(engine.opened, <String>[cached.toString()]);
      expect(engine.playCalls, 0);
    });

    test('Jellyfin and Subsonic streams take the same path', () async {
      for (final String uri in <String>['jellyfin:9', 'subsonic:9']) {
        final String url = 'https://server.example/stream/$uri?api_key=KEY';
        final _Engine engine =
            _Engine(undecodable: <String, String>{url: 'audio/flac'});
        final JustAudioPlaybackController controller = build(
          engine,
          _Resolver(<String, ResolvedPlayable>{
            uri: ResolvedPlayable(
              Uri.parse(url),
              PlaybackSource.streamingDirect,
            ),
          }),
        );

        await controller.playTracks(<Track>[_track('9', uri)]);

        expectUnsupportedError(controller.state);
        expect(controller.state.errorMessage, isNot(contains('KEY')));
      }
    });

    test('an MP3 on the same engine still loads and starts', () async {
      const String mp3 = 'https://server.example/stream/a.mp3';
      final _Engine engine = _Engine(
        // Only FLAC is undecodable on this simulated device.
        undecodable: <String, String>{_plexStreamUrl: 'audio/flac'},
      );
      final JustAudioPlaybackController controller = build(
        engine,
        _Resolver(<String, ResolvedPlayable>{
          'jellyfin:mp3': ResolvedPlayable(
            Uri.parse(mp3),
            PlaybackSource.streamingDirect,
          ),
        }),
      );

      await controller.playTracks(<Track>[_track('m', 'jellyfin:mp3')]);
      controller.handleEngineState(
        PlayerState(true, ProcessingState.ready),
      );

      expect(engine.playCalls, 1);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.failure, isNull);
    });

    test('an unsupported error mid-playback is not retried as a network drop',
        () async {
      const String url = 'https://server.example/stream/x.flac';
      final _Engine engine = _Engine();
      final _Resolver resolver = _Resolver(<String, ResolvedPlayable>{
        'jellyfin:x':
            ResolvedPlayable(Uri.parse(url), PlaybackSource.streamingDirect),
      });
      final JustAudioPlaybackController controller = build(engine, resolver);

      await controller.playTracks(<Track>[_track('x', 'jellyfin:x')]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.playing);

      engine.events.addError(_noDecoder());
      await pumpEventQueue();

      expectUnsupportedError(controller.state);
      // One resolve for the start; a network-style retry would add another.
      expect(resolver.calls, <String>['jellyfin:x']);
    });
  });

  group('media session', () {
    test('reports an error, not PLAYING, for undecodable audio', () async {
      final _Engine engine =
          _Engine(undecodable: <String, String>{_plexStreamUrl: 'audio/flac'});
      final JustAudioPlaybackController controller = build(
        engine,
        _Resolver(<String, ResolvedPlayable>{
          'plex:1': ResolvedPlayable(
            Uri.parse(_plexStreamUrl),
            PlaybackSource.streamingDirect,
          ),
        }),
      );
      final LinthraAudioHandler handler = LinthraAudioHandler(
        controller,
        MediaBrowserTree(FakeMusicLibraryRepository(tracks: const <Track>[])),
      );
      addTearDown(handler.dispose);

      await controller.playTracks(<Track>[_track('1', 'plex:1')]);
      await pumpEventQueue();

      final audio.PlaybackState session = handler.playbackState.value;
      expect(session.playing, isFalse);
      expect(session.processingState, audio.AudioProcessingState.error);
    });
  });

  group('classifyEngineError', () {
    test('code 4005 is unsupported format, whatever the message says', () {
      // Words and digits that would otherwise route elsewhere.
      for (final String message in <String>[
        'no decoder (HTTP 403 earlier)',
        'connection reset while probing',
        '',
      ]) {
        final StreamInterruption result = classifyEngineError(
          PlayerException(unsupportedAudioFormatErrorCode, message),
        );
        expect(result.kind, StreamInterruptionKind.formatUnsupported);
        expect(result.retryable, isFalse);
      }
    });

    test('other engine codes keep their existing classification', () {
      expect(
        classifyEngineError(PlayerException(0, 'Source error: timeout')).kind,
        StreamInterruptionKind.networkDropped,
      );
    });
  });

  group('loadFailureBreadcrumb', () {
    const PlaybackResolutionException unsupported = PlaybackResolutionException(
      "This track's format isn't supported on this device.",
      kind: PlaybackResolutionErrorKind.mediaUnsupported,
    );

    test('names the MIME type for undecodable audio', () {
      expect(
        JustAudioPlaybackController.loadFailureBreadcrumb(
          _noDecoder('audio/flac'),
          unsupported,
        ),
        'unsupported-format:audio/flac',
      );
    });

    test('never lets anything but a MIME type into the report', () {
      for (final String hostile in <String>[
        'audio/flac?X-Plex-Token=SECRET',
        'https://host/path',
        '/storage/emulated/0/Music/a.flac',
        'audio/flac\nLast error: none',
        '',
      ]) {
        expect(
          JustAudioPlaybackController.loadFailureBreadcrumb(
            _noDecoder(hostile),
            unsupported,
          ),
          'unsupported-format',
          reason: hostile,
        );
      }
    });

    test('an ordinary load failure stays "load"', () {
      expect(
        JustAudioPlaybackController.loadFailureBreadcrumb(
          Exception('could not open'),
          const PlaybackResolutionException(
            "Couldn't stream this track.",
            kind: PlaybackResolutionErrorKind.streamUnavailable,
          ),
        ),
        'load',
      );
    });
  });
}
