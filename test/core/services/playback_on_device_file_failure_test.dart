// An on-device track that the engine cannot read (#689).
//
// On Android an on-device track is a `content://` document: a SAF document
// from a picked folder, or a MediaStore row. The resolver deliberately does not
// probe those (it would cost a platform round trip on every load), so when the
// file has been deleted or moved, sits on an SD card or USB drive that was
// taken out, or its grant was revoked, the first sign of it is ExoPlayer
// failing to open or read it with "Source error". That is the same text a
// dropped stream produces, so read on its own it made a missing file look like
// a network problem: the cloud icon, "Reconnecting…", and a retry aimed at a
// server that was never involved.
//
// What decides it is where the audio comes from, which the player already
// knows: an on-device file that cannot be read is a file problem, whatever the
// engine's words were. Those words are the same for a file that is gone and
// one that is there but damaged or cut short, so they can't say which: a path
// is looked at again when reading it fails, and a document, which can't be,
// is described as a file that couldn't be read. Everything else keeps the
// classification it had.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';
import 'package:linthra/core/services/stream_interruption.dart';

import '../../support/fake_local_file_presence.dart';

/// A document on a removable SD card, from a folder picked through SAF.
const String _sdCardDocument = 'content://com.android.externalstorage.documents'
    '/tree/1234-5678%3AMusic/document/1234-5678%3AMusic%2FAlbum%2F01.flac';

/// A row from the device-wide MediaStore library.
const String _mediaStoreRow = 'content://media/external/audio/media/42';

const String _streamUrl =
    'https://server.example/Audio/7/stream?api_key=SECRET';
const String _cachedCopy = 'file:///cache/remote/jellyfin_8.flac';

/// What the Android engine raises when ExoPlayer cannot open or keep reading a
/// source (`ExoPlaybackException.TYPE_SOURCE`), for a file and a stream alike.
PlayerException _sourceError() =>
    PlayerException(0, 'Source error', <String, dynamic>{'index': 0});

/// What Linthra's patched engine raises for audio no decoder here can play.
PlayerException _noDecoder() => PlayerException(
      unsupportedAudioFormatErrorCode,
      'Unsupported audio format: no decoder on this device for audio/flac',
      <String, dynamic>{'index': 0, 'mimeType': 'audio/flac'},
    );

/// What a libmpv that loads but is not the right one fails with on Linux.
const String _wrongLibmpv =
    "Invalid argument(s): Failed to lookup symbol 'mpv_create': "
    '/opt/broken/libmpv.so.2: undefined symbol: mpv_create';

/// An engine that fails to open the URLs in [openErrors] with the error given
/// there and opens everything else. Its event stream can raise an engine error
/// mid-playback.
class _Engine extends Fake implements AudioPlayer {
  final Map<String, Object> openErrors = <String, Object>{};
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
    final Object? error = openErrors[url];
    if (error != null) throw error;
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

/// Resolves on-device tracks through the real [LocalPlayableUriResolver], a
/// `jellyfin:7` track to a live stream, and a `jellyfin:8` track to its
/// offline copy. Records every resolve, so a test can see a retry.
class _Resolver implements PlayableUriResolver {
  final LocalPlayableUriResolver _local =
      LocalPlayableUriResolver(presence: FakeLocalFilePresence.all());
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    switch (track.uri) {
      case 'jellyfin:7':
        return ResolvedPlayable(
          Uri.parse(_streamUrl),
          PlaybackSource.streamingDirect,
        );
      case 'jellyfin:8':
        return ResolvedPlayable(
          Uri.parse(_cachedCopy),
          PlaybackSource.offlineCache,
        );
    }
    return _local.resolve(track);
  }
}

/// The streaming fallback an offline copy that won't open is re-resolved
/// through.
class _StreamFallback implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse(_streamUrl),
        PlaybackSource.streamingDirect,
      );
}

Track _track(String uri) => Track(
      id: uri,
      uri: uri,
      title: 'Holocene',
      artistName: 'Bon Iver',
      albumName: 'Bon Iver',
      duration: const Duration(minutes: 4),
    );

/// The production recovery bounds with the waits taken out.
const PlaybackRecoveryPolicy _instantRecovery = PlaybackRecoveryPolicy(
  retryDelay: Duration.zero,
  advanceDelay: Duration.zero,
  maxAdvanceDelay: Duration.zero,
);

/// Lets every zero-length recovery timer and the awaits behind it run.
Future<void> _settle() async {
  for (int i = 0; i < 100; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track sdCardTrack = _track(_sdCardDocument);
  final Track mediaStoreTrack = _track(_mediaStoreRow);
  final Track streamTrack = _track('jellyfin:7');
  final Track cachedTrack = _track('jellyfin:8');

  // The words a vanished file path already gets from the resolver, so an
  // on-device document that went the same way is described the same way.
  late String missingFileWording;

  late _Engine engine;
  late _Resolver resolver;
  late List<PlaybackStatus> statuses;

  setUpAll(() async {
    try {
      await LocalPlayableUriResolver(
        presence: FakeLocalFilePresence(<String>{}),
      ).resolve(_track('/music/gone.flac'));
      fail('the resolver should refuse a file that is not there');
    } on PlaybackResolutionException catch (error) {
      expect(error.kind, PlaybackResolutionErrorKind.localFileMissing);
      missingFileWording = error.message;
    }
  });

  setUp(() {
    engine = _Engine();
    resolver = _Resolver();
    statuses = <PlaybackStatus>[];
  });

  JustAudioPlaybackController build({
    PlaybackRecoveryPolicy? automaticRecovery,
    PlayableUriResolver? streamingFallback,
    LocalFilePresence? localFilePresence,
  }) {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: engine,
      resolver: resolver,
      streamingFallbackResolver: streamingFallback,
      automaticRecovery: automaticRecovery,
      localFilePresence: localFilePresence ?? FakeLocalFilePresence.all(),
    )..streamRetryBackoff = Duration.zero;
    addTearDown(controller.dispose);
    controller.stateStream
        .listen((PlaybackState state) => statuses.add(state.status));
    return controller;
  }

  /// Plays [track] until the engine reports it playing.
  Future<void> startPlaying(
    JustAudioPlaybackController controller,
    Track track,
  ) async {
    await controller.playTracks(<Track>[track]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    await pumpEventQueue();
    expect(controller.state.status, PlaybackStatus.playing);
  }

  void expectMissingFile(PlaybackState state) {
    expect(state.status, PlaybackStatus.error);
    expect(state.failure?.kind, PlaybackFailureKind.localFileUnavailable);
    expect(state.errorMessage, missingFileWording);
    // The drive may be back in a moment, so Retry stays on offer.
    expect(state.failure?.canRetry, isTrue);
  }

  /// A document that couldn't be read, when nothing says whether it is gone
  /// or damaged: a file problem, worded as both, and never claimed missing.
  void expectUnreadableDocument(PlaybackState state) {
    expect(state.status, PlaybackStatus.error);
    expect(state.failure?.kind, PlaybackFailureKind.localFileUnavailable);
    expect(state.errorMessage, isNot(missingFileWording));
    expect(state.errorMessage, contains("couldn't read this file"));
    expect(state.errorMessage, contains('moved or deleted'));
    expect(state.errorMessage, contains('damaged'));
    expect(state.failure?.canRetry, isTrue);
  }

  group('an on-device document the engine cannot open', () {
    test('is a file that could not be read, not a network problem', () async {
      engine.openErrors[_sdCardDocument] = _sourceError();
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[sdCardTrack]);

      expectUnreadableDocument(controller.state);
      expect(engine.playCalls, 0);
    });

    test('a MediaStore row is reported the same way', () async {
      engine.openErrors[_mediaStoreRow] = _sourceError();
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[mediaStoreTrack]);

      expectUnreadableDocument(controller.state);
    });

    test('says nothing that could be the document or the raw error', () async {
      engine.openErrors[_sdCardDocument] = PlayerException(
        0,
        'Source error: $_sdCardDocument',
      );
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[sdCardTrack]);

      expect(controller.state.errorMessage, isNot(contains('content://')));
      expect(controller.state.errorMessage, isNot(contains('1234-5678')));
      expect(controller.state.errorMessage, isNot(contains('Source error')));
    });

    test('is not retried automatically as though a server blinked', () async {
      engine.openErrors[_sdCardDocument] = _sourceError();
      final JustAudioPlaybackController controller =
          build(automaticRecovery: _instantRecovery);

      await controller.playTracks(<Track>[sdCardTrack]);
      await _settle();

      expectUnreadableDocument(controller.state);
      expect(resolver.calls, <String>[_sdCardDocument]);
      expect(engine.opened, <String>[_sdCardDocument]);
    });
  });

  group('an on-device document that stops being readable mid-playback', () {
    test('ends as a file that could not be read, never "Reconnecting…"',
        () async {
      final JustAudioPlaybackController controller = build();
      await startPlaying(controller, sdCardTrack);
      expect(controller.state.source, PlaybackSource.localFile);
      statuses.clear();

      // The SD card is taken out while the track plays.
      engine.events.addError(_sourceError());
      await pumpEventQueue();

      expect(statuses, isNot(contains(PlaybackStatus.reconnecting)));
      expectUnreadableDocument(controller.state);
      // No reconnect attempt: nothing was re-resolved or re-opened.
      expect(resolver.calls, <String>[_sdCardDocument]);
      expect(engine.opened, <String>[_sdCardDocument]);
    });

    test('is not retried automatically either', () async {
      final JustAudioPlaybackController controller =
          build(automaticRecovery: _instantRecovery);
      await startPlaying(controller, sdCardTrack);
      statuses.clear();

      engine.events.addError(_sourceError());
      await _settle();

      expect(statuses, isNot(contains(PlaybackStatus.reconnecting)));
      expectUnreadableDocument(controller.state);
      expect(resolver.calls, <String>[_sdCardDocument]);
    });

    test('Retry plays it again once the card is back', () async {
      final JustAudioPlaybackController controller = build();
      await startPlaying(controller, sdCardTrack);
      engine.events.addError(_sourceError());
      await pumpEventQueue();
      expectUnreadableDocument(controller.state);

      await controller.retryCurrentTrack();

      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(controller.state.source, PlaybackSource.localFile);
      expect(engine.opened, <String>[_sdCardDocument, _sdCardDocument]);
    });
  });

  group('an on-device path the engine cannot read', () {
    /// A path that is still there but couldn't be read: not called missing,
    /// not called damaged for certain, and Retry kept for a read that clears.
    void expectUnreadablePath(PlaybackState state) {
      expect(state.status, PlaybackStatus.error);
      expect(state.failure?.kind, PlaybackFailureKind.localFileUnavailable);
      expect(state.errorMessage, isNot(missingFileWording));
      expect(state.errorMessage, contains('still there'));
      expect(state.failure?.canRetry, isTrue);
    }

    const String path = '/music/Album/01.flac';
    final String fileUri = Uri.file(path).toString();
    final Track pathTrack = _track(path);

    test('gone by the time it fails: a missing file', () async {
      engine.openErrors[fileUri] = _sourceError();
      final FakeLocalFilePresence presence = FakeLocalFilePresence(<String>{});
      final JustAudioPlaybackController controller =
          build(localFilePresence: presence);

      await controller.playTracks(<Track>[pathTrack]);

      expectMissingFile(controller.state);
      expect(presence.probed, <String>[path]);
    });

    test('still there: a file that could not be read, with Retry kept',
        () async {
      // A damaged file, a read the permissions refuse, or a mounted drive
      // throwing I/O errors all fail with the same "Source error", and only
      // the first is for good.
      engine.openErrors[fileUri] = _sourceError();
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[pathTrack]);

      expectUnreadablePath(controller.state);
      expect(controller.state.errorMessage, isNot(contains(path)));
    });

    test('gone mid-playback: a missing file, never "Reconnecting…"', () async {
      final FakeLocalFilePresence presence = FakeLocalFilePresence(null);
      final JustAudioPlaybackController controller =
          build(localFilePresence: presence);
      await startPlaying(controller, pathTrack);
      statuses.clear();

      // The USB drive is pulled while the track plays.
      presence.present = <String>{};
      engine.events.addError(_sourceError());
      await pumpEventQueue();

      expect(statuses, isNot(contains(PlaybackStatus.reconnecting)));
      expectMissingFile(controller.state);
      expect(engine.opened, <String>[fileUri]);
    });

    test('unreadable mid-playback while still there: Retry kept, not missing',
        () async {
      final JustAudioPlaybackController controller = build();
      await startPlaying(controller, pathTrack);
      statuses.clear();

      // The file is cut short partway through.
      engine.events.addError(_sourceError());
      await pumpEventQueue();

      expect(statuses, isNot(contains(PlaybackStatus.reconnecting)));
      expectUnreadablePath(controller.state);
    });
  });

  group('what keeps its classification', () {
    test('undecodable audio in an on-device document is unplayable media',
        () async {
      engine.openErrors[_sdCardDocument] = _noDecoder();
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[sdCardTrack]);

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.unplayableMedia,
      );
      expect(
        controller.state.errorMessage,
        "This track's format isn't supported on this device.",
      );
    });

    test('a decode failure mid-playback on an on-device document too',
        () async {
      final JustAudioPlaybackController controller = build();
      await startPlaying(controller, sdCardTrack);

      engine.events.addError(_noDecoder());
      await pumpEventQueue();

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.unplayableMedia,
      );
      expect(resolver.calls, <String>[_sdCardDocument]);
    });

    test('"Source error" on a stream is still a stream failure', () async {
      engine.openErrors[_streamUrl] = _sourceError();
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[streamTrack]);

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.temporarySource,
      );
      expect(controller.state.errorMessage, "Couldn't stream this track.");
    });

    test('"Source error" mid-stream still reconnects to the server', () async {
      final JustAudioPlaybackController controller = build();
      await startPlaying(controller, streamTrack);
      expect(controller.state.source, PlaybackSource.streamingDirect);
      statuses.clear();

      engine.events.addError(_sourceError());
      await pumpEventQueue();

      expect(statuses, contains(PlaybackStatus.reconnecting));
      expect(resolver.calls, <String>['jellyfin:7', 'jellyfin:7']);
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('an offline copy that will not open still falls back to the stream',
        () async {
      engine.openErrors[_cachedCopy] = _sourceError();
      final JustAudioPlaybackController controller =
          build(streamingFallback: _StreamFallback());

      await controller.playTracks(<Track>[cachedTrack]);

      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(controller.state.source, PlaybackSource.streamingDirect);
      expect(engine.opened, <String>[_cachedCopy, _streamUrl]);
    });

    test('an offline copy with no stream to fall back to fails as before',
        () async {
      engine.openErrors[_cachedCopy] = _sourceError();
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[cachedTrack]);

      expect(controller.state.status, PlaybackStatus.error);
      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.temporarySource,
      );
      expect(controller.state.errorMessage, "Couldn't play this track.");
    });

    test('an error that is not a source error is not called a missing file',
        () async {
      // ExoPlayer's "unexpected" errors say nothing about whether the file is
      // there, so the failure keeps its generic wording instead of a guess.
      engine.openErrors[_sdCardDocument] =
          PlayerException(2, 'Unexpected runtime error');
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[sdCardTrack]);

      expect(controller.state.errorMessage, "Couldn't play this track.");
      expect(
        controller.state.failure?.kind,
        isNot(PlaybackFailureKind.localFileUnavailable),
      );
    });

    test('an interrupted load is not a verdict on the file', () async {
      engine.openErrors[_sdCardDocument] =
          PlayerInterruptedException('Loading interrupted');
      final JustAudioPlaybackController controller = build();

      await controller.playTracks(<Track>[sdCardTrack]);

      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.temporarySource,
      );
      expect(controller.state.errorMessage, "Couldn't play this track.");
    });
  });

  group('on Linux, an engine that cannot run still comes first', () {
    LinuxPlaybackController buildLinux() {
      final LinuxPlaybackController controller = LinuxPlaybackController(
        player: engine,
        resolver: resolver,
        backend: LinuxPlaybackBackendInitializer(
          registerBackend: () {},
          bundledRuntime: false,
        ),
      )..streamRetryBackoff = Duration.zero;
      addTearDown(controller.dispose);
      return controller;
    }

    test('when an on-device file is loaded', () async {
      final Uri file = Uri.file('/music/Album/01.flac');
      engine.openErrors[file.toString()] = Exception(_wrongLibmpv);
      final LinuxPlaybackController controller = buildLinux();

      await controller.playTracks(<Track>[_track('/music/Album/01.flac')]);

      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.playbackEngineUnavailable,
      );
    });

    test('when it fails while an on-device file plays', () async {
      final LinuxPlaybackController controller = buildLinux();
      await startPlaying(controller, _track('/music/Album/01.flac'));
      expect(controller.state.source, PlaybackSource.localFile);

      engine.events.addError(Exception(_wrongLibmpv));
      await pumpEventQueue();

      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.playbackEngineUnavailable,
      );
    });
  });
}
