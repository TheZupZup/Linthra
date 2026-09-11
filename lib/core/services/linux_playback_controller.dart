import 'dart:math';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'just_audio_playback_controller.dart';
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

/// Registers just_audio's Linux implementation once for this process.
///
/// Registration is synchronous, so the success flag cannot race another call
/// in the same isolate. It is deliberately set after registration returns: if
/// native setup throws, the next controller construction can retry.
class LinuxPlaybackBackendInitializer {
  LinuxPlaybackBackendInitializer({
    LinuxPlaybackBackendRegistration? registerBackend,
  }) : _registerBackend = registerBackend ?? _registerDefaultBackend;

  final LinuxPlaybackBackendRegistration _registerBackend;
  bool _initialized = false;

  void ensureInitialized() {
    if (_initialized) return;
    _registerBackend();
    _initialized = true;
  }

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
/// and enables post-suspend recovery so a system sleep/wake can re-prime the
/// audio device and re-resolve remote streams without duplicating playback.
/// Android never constructs this type and therefore keeps just_audio's native
/// ExoPlayer implementation and its existing audio-service/audio-focus path.
class LinuxPlaybackController extends JustAudioPlaybackController {
  static final LinuxPlaybackBackendInitializer _backendInitializer =
      LinuxPlaybackBackendInitializer();

  factory LinuxPlaybackController({
    AudioPlayer? player,
    PlayableUriResolver resolver = const LocalPlayableUriResolver(),
    PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
    PlayableUriResolver? streamingFallbackResolver,
    Random? random,
    TrackCompletionCallback? onTrackCompleted,
  }) {
    // Tests inject an AudioPlayer explicitly. The production path registers
    // media_kit before the superclass can construct its AudioPlayer.
    if (player == null) _backendInitializer.ensureInitialized();
    return LinuxPlaybackController._(
      player: player,
      resolver: resolver,
      candidates: candidates,
      streamingFallbackResolver: streamingFallbackResolver,
      random: random,
      onTrackCompleted: onTrackCompleted,
    );
  }

  LinuxPlaybackController._({
    super.player,
    required super.resolver,
    required super.candidates,
    super.streamingFallbackResolver,
    super.random,
    super.onTrackCompleted,
  }) : super(recoverPlaybackAfterSuspend: true);
}
