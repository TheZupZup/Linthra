import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/diagnostics/linux_playback_diagnostics.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_runtime.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// media_kit 1.2.6's own wording when no libmpv answers on Linux.
const String _cannotFindLibmpv =
    'Exception: Cannot find libmpv at the usual places. Depending upon your '
    'distribution, you can install the libmpv package to make shared library '
    'available globally. On Debian or Ubuntu based systems, you can install '
    'it with: apt install libmpv-dev.';

/// What a libmpv that loads but is not the right one fails with, at the first
/// symbol rather than at registration.
const String _wrongLibrary =
    "Invalid argument(s): Failed to lookup symbol 'mpv_create': "
    '/opt/broken/libmpv.so.2: undefined symbol: mpv_create';

class _Engine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> states =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<PlaybackEvent> events =
      StreamController<PlaybackEvent>.broadcast(sync: true);

  final List<String> opened = <String>[];

  /// The error `setUrl` throws instead of opening, or null to open normally.
  Object? openError;

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
    final Object? error = openError;
    if (error != null) throw error;
    return const Duration(minutes: 4);
  }

  @override
  Future<void> play() async => states.add(
        PlayerState(true, ProcessingState.ready),
      );
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}

  Future<void> close() async {
    await states.close();
    await events.close();
  }
}

/// Resolves anything, and counts how often it was asked, so a test can show
/// that an unusable engine is settled *before* the network is touched.
class _Resolver implements PlayableUriResolver {
  int calls = 0;
  PlaybackResolutionException? failWith;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls++;
    final PlaybackResolutionException? failure = failWith;
    if (failure != null) throw failure;
    return ResolvedPlayable(
      Uri.parse('https://music.example/stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

/// A registration that throws while [broken] is set. Clearing it is what "the
/// listener installed the package" looks like from in here.
class _Registration {
  _Registration({required this.error, this.broken = true});

  final Object error;
  bool broken;
  int attempts = 0;

  void call() {
    attempts++;
    if (broken) throw error;
  }
}

Track _track(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

void main() {
  LinuxPlaybackBackendInitializer backendThat(
    _Registration registration, {
    bool bundledRuntime = false,
  }) =>
      LinuxPlaybackBackendInitializer(
        registerBackend: registration.call,
        bundledRuntime: bundledRuntime,
      );

  /// A backend whose registration works first time, for the cases where the
  /// runtime is fine and the failure is the track's.
  LinuxPlaybackBackendInitializer workingBackend() => backendThat(
        _Registration(error: StateError('never thrown'), broken: false),
      );

  ({LinuxPlaybackController controller, _Engine engine, _Resolver resolver})
      build(LinuxPlaybackBackendInitializer backend) {
    final _Engine engine = _Engine();
    final _Resolver resolver = _Resolver();
    final LinuxPlaybackController controller = LinuxPlaybackController(
      player: engine,
      resolver: resolver,
      backend: backend,
    );
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    return (controller: controller, engine: engine, resolver: resolver);
  }

  group('a backend that cannot come up', () {
    test('is not fatal: the controller is built and the app stays up', () {
      final _Registration registration =
          _Registration(error: Exception(_cannotFindLibmpv));

      final controller = build(backendThat(registration)).controller;

      expect(controller.state.status, PlaybackStatus.idle);
      expect(registration.attempts, 1);
    });

    test('reports a Linux runtime problem rather than a track failure',
        () async {
      final parts = build(
        backendThat(_Registration(error: Exception(_cannotFindLibmpv))),
      );

      await parts.controller.playTrack(_track('a'));

      final PlaybackFailure? failure = parts.controller.state.failure;
      expect(parts.controller.state.status, PlaybackStatus.error);
      expect(failure?.kind, PlaybackFailureKind.playbackEngineUnavailable);
      expect(failure?.message, contains('libmpv'));
      expect(failure?.shortLabel, 'Audio engine unavailable');
    });

    test('offers Retry and nothing else', () async {
      final parts = build(
        backendThat(_Registration(error: Exception(_cannotFindLibmpv))),
      );

      // Two tracks queued, so "Skip" would be offered for any other failure.
      await parts.controller.playTracks(<Track>[_track('a'), _track('b')]);

      final PlaybackFailure failure = parts.controller.state.failure!;
      expect(failure.actions, <PlaybackRecoveryAction>[
        PlaybackRecoveryAction.retry,
      ]);
      // Another copy of the song would go through the same dead engine.
      expect(failure.canTryAnotherSource, isFalse);
      expect(failure.canSkip, isFalse);
    });

    test('never reaches the resolver, so no stream is minted for nothing',
        () async {
      final parts = build(
        backendThat(_Registration(error: Exception(_cannotFindLibmpv))),
      );

      await parts.controller.playTrack(_track('a'));

      expect(parts.resolver.calls, 0);
      expect(parts.engine.opened, isEmpty);
    });

    test('says nothing that could be a path, a URL or a raw error', () async {
      final parts = build(
        backendThat(_Registration(error: Exception(_cannotFindLibmpv))),
      );

      await parts.controller.playTrack(_track('a'));

      final String message = parts.controller.state.failure!.message;
      expect(message, isNot(contains('/')));
      expect(message, isNot(contains('://')));
      expect(message.toLowerCase(), isNot(contains('exception')));
      expect(message, isNot(contains('music.example')));
    });

    test('tells a Flatpak listener to reinstall, not to apt install', () async {
      final parts = build(
        backendThat(
          _Registration(error: Exception(_cannotFindLibmpv)),
          bundledRuntime: true,
        ),
      );

      await parts.controller.playTrack(_track('a'));

      final String message = parts.controller.state.failure!.message;
      expect(message, contains('Flathub'));
      expect(message, isNot(contains('apt')));
    });

    test('keeps the loader detail internally, with the paths taken out', () {
      final LinuxPlaybackBackendInitializer backend = backendThat(
        _Registration(
          error: Exception(
            "Failed to load dynamic library '/home/ada/lib/libmpv.so.2': "
            'wrong ELF class: ELFCLASS32',
          ),
        ),
      );
      build(backend);

      final LinuxPlaybackRuntimeFailure failure = backend.failure!;
      expect(failure.problem, LinuxPlaybackRuntimeProblem.libraryIncompatible);
      // The reason is worth keeping; the path it came wrapped in is not.
      expect(failure.diagnostic, contains('wrong ELF class'));
      expect(failure.diagnostic, isNot(contains('/home/ada')));
      // And none of it is what the listener is shown.
      expect(failure.message, isNot(contains('ELF')));
    });
  });

  group('retrying after the environment is fixed', () {
    test('plays, without restarting anything', () async {
      final _Registration registration =
          _Registration(error: Exception(_cannotFindLibmpv));
      final parts = build(backendThat(registration));
      await parts.controller.playTrack(_track('a'));
      expect(parts.controller.state.status, PlaybackStatus.error);

      // The listener installs the package and presses Retry.
      registration.broken = false;
      await parts.controller.retryCurrentTrack();

      expect(parts.controller.state.status, PlaybackStatus.playing);
      expect(parts.controller.state.failure, isNull);
      expect(parts.engine.opened, hasLength(1));
    });

    test('keeps offering Retry past the per-track attempt budget', () async {
      // The budget exists to stop a listener tapping at a source with a fixed
      // answer. A machine being repaired is not that, and after three taps
      // the panel would otherwise have no button left at all.
      final parts = build(
        backendThat(_Registration(error: Exception(_cannotFindLibmpv))),
      );
      await parts.controller.playTrack(_track('a'));

      for (var attempt = 0;
          attempt < JustAudioPlaybackController.maxRecoveryAttemptsPerTrack + 2;
          attempt++) {
        await parts.controller.retryCurrentTrack();
      }

      expect(parts.controller.state.failure?.canRetry, isTrue);
      expect(
        parts.controller.state.failure?.kind,
        PlaybackFailureKind.playbackEngineUnavailable,
      );
    });

    test('re-examines the runtime on every attempt', () {
      final _Registration registration =
          _Registration(error: Exception(_cannotFindLibmpv));
      final LinuxPlaybackBackendInitializer backend = backendThat(registration);

      backend.ensureInitialized();
      backend.ensureInitialized();

      expect(registration.attempts, 2);
      expect(backend.isReady, isFalse);
    });

    test('stops examining it once it works', () {
      final _Registration registration =
          _Registration(error: Exception(_cannotFindLibmpv));
      final LinuxPlaybackBackendInitializer backend = backendThat(registration);

      expect(backend.ensureInitialized(), isNotNull);
      registration.broken = false;
      expect(backend.ensureInitialized(), isNull);
      expect(backend.ensureInitialized(), isNull);

      expect(registration.attempts, 2);
      expect(backend.isReady, isTrue);
      expect(backend.failure, isNull);
    });
  });

  group('a bug is still a bug', () {
    test('an unrecognised registration error is rethrown, not relabelled', () {
      final LinuxPlaybackBackendInitializer backend = backendThat(
        _Registration(error: StateError('the plugin registry is null')),
      );

      expect(backend.ensureInitialized, throwsStateError);
      expect(backend.failure, isNull);
    });

    test('and it reaches the caller rather than becoming "install libmpv"', () {
      expect(
        () => LinuxPlaybackController(
          player: _Engine(),
          resolver: _Resolver(),
          backend: backendThat(
            _Registration(error: ArgumentError('bad registration argument')),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('ordinary failures keep their own classification', () {
    test('a codec the engine cannot decode stays unplayable media', () async {
      final parts = build(workingBackend());
      parts.engine.openError = Exception('unsupported codec in this container');

      await parts.controller.playTrack(_track('a'));

      expect(
        parts.controller.state.failure?.kind,
        PlaybackFailureKind.unplayableMedia,
      );
    });

    test('a server that will not answer stays a temporary source problem',
        () async {
      final parts = build(workingBackend());
      parts.resolver.failWith = const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );

      await parts.controller.playTrack(_track('a'));

      expect(
        parts.controller.state.failure?.kind,
        PlaybackFailureKind.temporarySource,
      );
    });

    test('a provider that rejects the session stays a sign-in problem',
        () async {
      final parts = build(workingBackend());
      parts.resolver.failWith = const PlaybackResolutionException(
        'Your session expired. Sign in again to keep streaming.',
        kind: PlaybackResolutionErrorKind.sessionExpired,
      );

      await parts.controller.playTrack(_track('a'));

      expect(
        parts.controller.state.failure?.kind,
        PlaybackFailureKind.sourceSignInRequired,
      );
    });

    test('an on-device file that moved stays a local-file problem', () async {
      final parts = build(workingBackend());
      parts.resolver.failWith = const PlaybackResolutionException(
        "This track's file isn't there anymore.",
        kind: PlaybackResolutionErrorKind.localFileMissing,
      );

      await parts.controller.playTrack(_track('a'));

      expect(
        parts.controller.state.failure?.kind,
        PlaybackFailureKind.localFileUnavailable,
      );
    });
  });

  group('a runtime that only fails once it is handed a source', () {
    test('reads as an engine problem, not as a track problem', () async {
      // A libmpv that opens but exports none of the symbols this build needs:
      // registration succeeds, the first load does not.
      final parts = build(workingBackend());
      parts.engine.openError = Exception(_wrongLibrary);

      await parts.controller.playTrack(_track('a'));

      expect(
        parts.controller.state.failure?.kind,
        PlaybackFailureKind.playbackEngineUnavailable,
      );
      expect(parts.controller.state.failure?.message, isNot(contains('/opt')));
    });
  });

  group('Android and the shared engine are untouched', () {
    test('the shared controller never produces an engine-unavailable failure',
        () async {
      // The same native-sounding error on the Android path: there is no Linux
      // classifier there, and adding the kind must not have changed how the
      // shared controller reads anything.
      final _Engine engine = _Engine()..openError = Exception(_wrongLibrary);
      final _Resolver resolver = _Resolver();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: engine, resolver: resolver);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });

      await controller.playTrack(_track('a'));

      expect(
        controller.state.failure?.kind,
        isNot(PlaybackFailureKind.playbackEngineUnavailable),
      );
      expect(
        controller.state.failure?.kind,
        PlaybackFailureKind.temporarySource,
      );
      // And it still resolves and tries, because nothing preflights the engine
      // on a platform that ships one.
      expect(resolver.calls, 1);
    });
  });
}
