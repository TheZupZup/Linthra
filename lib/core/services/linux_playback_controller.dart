import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../diagnostics/linux_playback_diagnostics.dart';
import '../models/playback_source.dart';
import 'just_audio_playback_controller.dart';
import 'linux_playback_runtime.dart';
import 'local_playable_uri_resolver.dart';
import 'playable_uri_resolver.dart';
import 'playback_candidate_source.dart';

typedef LinuxPlaybackBackendRegistration = void Function();

/// The libmpv properties Linthra always applies on Linux.
///
/// media_kit turns mpv's on-disk demuxer cache on for every player it creates
/// (`'cache-on-disk': 'yes'` in media_kit 1.2.6,
/// `lib/src/player/native/player/real.dart`). That is a reasonable default for
/// a video player buffering gigabytes to disk, and the wrong one here: Linthra
/// streams audio, and it manages its own offline downloads separately. When mpv
/// cannot create the temporary file it wants, libmpv logs
/// `[lavf] Failed to create cache temporary file.` followed by
/// `[lavf] Failed to create file cache.` on every stream (#405).
///
/// `cache-on-disk=no` turns off exactly that temporary on-disk packet file.
/// media_kit's `cache=yes` is deliberately left alone, so normal memory and
/// network buffering are unchanged, as is Linthra's own download/offline cache.
///
/// Ordering is what makes this work: media_kit applies its own defaults while
/// the player initializes, and just_audio_media_kit applies this map afterwards
/// through `NativePlayer.setProperty`, which awaits that initialization. The
/// override therefore lands last.
const Map<String, String> linuxMpvProperties = <String, String>{
  'cache-on-disk': 'no',
};

/// [linuxMpvProperties] with anything a caller already configured layered on
/// top.
///
/// Two callers configure something. The headless audio smoke sets its own `ao`
/// before it builds a controller (`tool/linux_audio_backend_smoke.dart`), and
/// `LinuxAudioOutputDeviceService` sets `audio-device` when the listener picks
/// an output. Merging rather than assigning keeps both working whichever order
/// they land in — and keeps the smoke honest: it exercises the same cache
/// configuration production uses, with only the output device swapped.
Map<String, String> resolveLinuxMpvProperties(Map<String, String> configured) =>
    <String, String>{...linuxMpvProperties, ...configured};

/// Whether this process is a Flatpak, where libmpv is bundled in the image.
///
/// Read once from the environment the sandbox always sets
/// (`docs/flatpak-development.md`). It changes only what a runtime failure
/// *advises*: a distribution build plays through the machine's libmpv, so the
/// fix is the machine's package manager, while a Flatpak never loads the
/// host's libmpv at all and telling its user to `apt install` something would
/// send them to fix a library the app does not use.
bool runsInFlatpak() =>
    (Platform.environment['FLATPAK_ID'] ?? '').trim().isNotEmpty;

/// Registers just_audio's Linux implementation once for this process, and says
/// what stopped it when it cannot.
///
/// Registration is synchronous, so the success flag cannot race another call
/// in the same isolate. It is deliberately set only after registration returns,
/// which is what makes the whole retry story work: the runtime is re-examined
/// on every attempt until one succeeds, so a listener who installs the missing
/// package and presses Retry gets audio without restarting Linthra, let alone
/// the machine.
///
/// Two kinds of failure leave here by two different doors, and keeping them
/// apart is the point of this class:
///
///  * An environment problem (no libmpv, a libmpv that will not load, one that
///    does not match this build) is *returned* as a classified
///    [LinuxPlaybackRuntimeFailure]. The app stays up, playback reports a
///    Linux runtime problem instead of an opaque track error, and a later
///    attempt can still succeed.
///  * Anything else is *rethrown* untouched. A bug in this registration path
///    is a bug, and dressing it up as "install libmpv" would send everyone who
///    hits it to reinstall a package that was never the problem.
class LinuxPlaybackBackendInitializer {
  LinuxPlaybackBackendInitializer({
    LinuxPlaybackBackendRegistration? registerBackend,
    bool? bundledRuntime,
  })  : _registerBackend = registerBackend ?? _registerDefaultBackend,
        _bundledRuntime = bundledRuntime ?? runsInFlatpak();

  final LinuxPlaybackBackendRegistration _registerBackend;
  final bool _bundledRuntime;

  bool _initialized = false;
  LinuxPlaybackRuntimeFailure? _failure;

  /// A runtime failure the engine only revealed once it was handed a source.
  ///
  /// Registration succeeded, so [_initialized] is true and re-running it
  /// would keep saying the backend is fine. Without a latch the next play
  /// would sail through the preflight, resolve a stream (a network round trip
  /// on a machine that has already proven it cannot play a note) and fail at
  /// the same symbol. Latched, the preflight answers immediately with the
  /// verdict it already has.
  LinuxPlaybackRuntimeFailure? _loadTimeFailure;

  /// Whether the backend is registered and the native runtime is loaded.
  bool get isReady => _initialized;

  /// What stopped the backend coming up on the most recent attempt, or null
  /// when it is up (or has not been asked yet).
  LinuxPlaybackRuntimeFailure? get failure => _failure;

  /// Registers the backend if it is not registered yet.
  ///
  /// Returns null when the backend is ready and a classified failure when it
  /// is not. Cheap to call on every playback attempt: once it has succeeded it
  /// short-circuits, and until then the work is one library load.
  LinuxPlaybackRuntimeFailure? ensureInitialized() {
    final LinuxPlaybackRuntimeFailure? loadTime = _loadTimeFailure;
    if (loadTime != null) return loadTime;
    if (_initialized) return null;
    try {
      _registerBackend();
    } catch (error) {
      final LinuxPlaybackRuntimeProblem? problem =
          LinuxPlaybackRuntime.recognise(error);
      // Not a native-runtime problem: a real bug, and it leaves as one.
      if (problem == null) rethrow;
      _failure = _classify(problem, error);
      LinuxPlaybackRuntime.logFailure(_failure!);
      return _failure;
    }
    _initialized = true;
    _failure = null;
    _loadTimeFailure = null;
    return null;
  }

  /// Classifies a failure the engine only reached once it was handed a source.
  ///
  /// A libmpv that opens but is not the libmpv this build needs gets through
  /// registration (the loader binds lazily) and fails at the first symbol, so
  /// the load path needs the same classification the registration path has.
  /// Returns null for everything that is not about the native runtime, which
  /// is how an ordinary codec, network or provider failure keeps the wording
  /// and the recovery it already had.
  LinuxPlaybackRuntimeFailure? classifyEngineFailure(Object error) {
    final LinuxPlaybackRuntimeProblem? problem =
        LinuxPlaybackRuntime.recognise(error);
    if (problem == null) return null;
    final LinuxPlaybackRuntimeFailure failure = _classify(problem, error);
    _failure = failure;
    _loadTimeFailure = failure;
    LinuxPlaybackRuntime.logFailure(failure);
    return failure;
  }

  /// Gives the engine one more genuine attempt after a load-time verdict.
  ///
  /// Called when the listener presses Retry, which is them saying they have
  /// fixed the machine. The latch exists to stop *automatic* attempts walking
  /// into a known-broken engine, not to refuse the one attempt that was asked
  /// for, so a deliberate retry clears it and the next load really reaches
  /// libmpv again.
  void allowAnotherAttempt() {
    _loadTimeFailure = null;
  }

  LinuxPlaybackRuntimeFailure _classify(
    LinuxPlaybackRuntimeProblem problem,
    Object error,
  ) =>
      LinuxPlaybackRuntimeFailure(
        problem: problem,
        message: LinuxPlaybackRuntime.messageFor(
          problem,
          bundledRuntime: _bundledRuntime,
        ),
        diagnostic: LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(error),
      );

  static void _registerDefaultBackend() {
    JustAudioMediaKit.title = 'Linthra';
    JustAudioMediaKit.mpvProperties =
        resolveLinuxMpvProperties(JustAudioMediaKit.mpvProperties);
    JustAudioMediaKit.ensureInitialized(linux: true, windows: false);
  }
}

/// Linux on-device playback backed by media_kit and the declared libmpv runtime.
///
/// The transport, queue, resolver fallback and completion behaviour deliberately
/// stay in [JustAudioPlaybackController]. This class only registers the Linux
/// federated implementation before that controller creates its [AudioPlayer],
/// reports a broken native runtime as a Linux runtime problem rather than as a
/// track that will not play, and enables post-suspend recovery so a system
/// sleep/wake can re-prime the audio device and re-resolve remote streams
/// without duplicating playback. Android never constructs this type and
/// therefore keeps just_audio's native ExoPlayer implementation and its
/// existing audio-service/audio-focus path.
class LinuxPlaybackController extends JustAudioPlaybackController {
  static final LinuxPlaybackBackendInitializer _backendInitializer =
      LinuxPlaybackBackendInitializer();

  /// What is wrong with this process's Linux audio runtime, for the Linux
  /// playback diagnostics report. Null when the backend came up.
  static LinuxPlaybackRuntimeFailure? get backendRuntimeFailure =>
      _backendInitializer.failure;

  factory LinuxPlaybackController({
    AudioPlayer? player,
    PlayableUriResolver resolver = const LocalPlayableUriResolver(),
    PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
    PlayableUriResolver? streamingFallbackResolver,
    Random? random,
    TrackCompletionCallback? onTrackCompleted,
    LinuxPlaybackBackendInitializer? backend,
  }) {
    // The production path registers media_kit before the superclass can
    // construct its AudioPlayer. Tests inject an AudioPlayer instead, which is
    // not media_kit's: nothing on that path loads libmpv, so there is no
    // native runtime to bring up or to guard, and a test that wants one says
    // so by passing a [backend].
    //
    // A runtime failure here is deliberately not fatal: it is recorded on the
    // initializer and reported at the first playback attempt, where the
    // listener is looking and where Retry can put it right. A bug still
    // throws.
    final LinuxPlaybackBackendInitializer? initializer =
        backend ?? (player == null ? _backendInitializer : null);
    initializer?.ensureInitialized();
    return LinuxPlaybackController._(
      backend: initializer,
      player: player,
      resolver: resolver,
      candidates: candidates,
      streamingFallbackResolver: streamingFallbackResolver,
      random: random,
      onTrackCompleted: onTrackCompleted,
    );
  }

  LinuxPlaybackController._({
    required LinuxPlaybackBackendInitializer? backend,
    super.player,
    required super.resolver,
    required super.candidates,
    super.streamingFallbackResolver,
    super.random,
    super.onTrackCompleted,
  })  : _backend = backend,
        super(recoverPlaybackAfterSuspend: true);

  /// The backend this controller is responsible for, or null when it was
  /// handed an engine and therefore never brings one up.
  final LinuxPlaybackBackendInitializer? _backend;

  /// Re-examines the native runtime before a source is resolved for it.
  ///
  /// This is both the guard and the retry. Nothing is handed to an engine that
  /// cannot take it (which is what used to turn "libmpv is not installed" into
  /// an opaque per-track failure somewhere deeper), and because the check is a
  /// fresh registration attempt every time it has not succeeded yet, the
  /// listener can install the package, press Retry and have music, with no
  /// restart of Linthra and certainly none of the machine.
  @override
  @protected
  PlaybackResolutionException? engineUnavailableFailure() =>
      _backend?.ensureInitialized()?.asResolutionException();

  /// Lets a deliberate Retry reach the engine again.
  ///
  /// A runtime failure discovered at load time is latched, so ordinary play
  /// attempts are refused at the preflight rather than resolving a stream for
  /// an engine that has already failed. Retry is the one case that should get
  /// through: it is the listener saying the machine is fixed, and the only
  /// way to find out is to ask libmpv.
  @override
  Future<void> retryCurrentTrack() {
    _backend?.allowAnotherAttempt();
    return super.retryCurrentTrack();
  }

  /// Classifies a load failure that is really the native runtime's.
  ///
  /// Deliberately narrow. A libmpv that loads but is the wrong one fails at
  /// the first symbol rather than at registration, and that is worth saying
  /// plainly. Everything else, a codec libmpv was not built with, a server
  /// that stopped answering, a provider's expired session, is not recognised
  /// here and keeps the classification the shared controller already gives it.
  @override
  @protected
  PlaybackResolutionException loadFailureFor(
    Object error,
    PlaybackSource source,
  ) =>
      _backend?.classifyEngineFailure(error)?.asResolutionException() ??
      super.loadFailureFor(error, source);
}
