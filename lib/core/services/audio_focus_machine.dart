import '../native/native_audio_focus.dart';
import 'just_audio_playback_controller.dart' show AudioFocusAction;

/// One thing that happened to the player, as [AudioFocusMachine] takes it.
///
/// The codes are shared with the Rust core
/// (native/linthra_core/src/audio_focus.rs): 0 to 4 are an interruption by its
/// [AudioFocusAction], then the rest in this order.
enum FocusEvent {
  pauseTransient,
  pausePermanent,
  resume,
  duck,
  unduck,

  /// A transient loss outlasted its debounce.
  pauseDebounceFired,

  /// The foreground hold ran out before the regain came.
  holdExpired,

  /// Headphones were unplugged.
  becomingNoisy,

  /// The app came back to the foreground.
  appForegrounded,

  /// The listener pressed play.
  play,

  /// The listener paused.
  pause,

  /// The listener stopped.
  stop,

  /// A cast receiver took over the audio.
  suspend,

  /// The engine reports playing again.
  enginePlaying,

  /// Playback ended in an error.
  error;

  /// The event an audio focus change is.
  static FocusEvent of(AudioFocusAction action) =>
      FocusEvent.values[action.index];
}

/// What the player is to do, in order. A step is a [FocusCommand] code, or
/// [diagnosticBase] plus a [FocusDiagnostic] code.
enum FocusCommand {
  startPauseTimer,
  cancelPauseTimer,

  /// Supersede any focus pause or resume still queued.
  bumpEpoch,
  enqueuePause,
  enqueueResume,

  /// Queue the engine volume for the current duck state.
  applyVolume,
  startHoldTimer,
  cancelHoldTimer,

  /// Publish the state again, so the media session sees the hold change.
  emitState,

  /// A track still loading must not start when it lands.
  clearPlayWhenLoaded,

  /// No automatic retry or move may start a track.
  haltRecovery,
}

/// The breadcrumbs the machine leaves, with the text the diagnostics log
/// keeps.
enum FocusDiagnostic {
  lossTransientArmed('loss-transient:scheduled armed=true'),
  lossTransientNotArmed('loss-transient:scheduled armed=false'),
  lossPermanent('loss-permanent:paused'),
  ducked('loss-duck:ducked'),
  unduckRestored('unduck:restored'),
  unduckIgnored('unduck:ignored'),
  regainChurnAbsorbed('regain:churn-absorbed'),
  regainRecoveryStarts('regain:recovery-starts'),
  regainResumed('regain:resumed'),
  regainIgnored('regain:ignored'),
  lossTransientPaused('loss-transient:paused'),
  lossTransientAlreadyPaused('loss-transient:already-paused'),
  holdExpiredAfterRegain('hold:expired-after-regain'),
  holdExpired('hold:expired'),
  noisyPaused('noisy:paused');

  const FocusDiagnostic(this.label);

  final String label;
}

/// A step code at or above this is a [FocusDiagnostic].
const int diagnosticBase = 32;

/// What the player knows when an interruption arrives.
class FocusContext {
  const FocusContext({
    this.playing = false,
    this.loadingToPlay = false,
    this.recoveryUnderway = false,
  });

  final bool playing;

  /// A track is loading and the listener wants it to play when it lands.
  final bool loadingToPlay;

  /// An automatic retry or move is scheduled or loading.
  final bool recoveryUnderway;

  int get bits =>
      (playing ? 1 : 0) | (loadingToPlay ? 2 : 0) | (recoveryUnderway ? 4 : 0);
}

/// The player's audio focus machine: what a call, a voice prompt, a
/// navigation cue, unplugged headphones or the listener's own transport does
/// to playback. The player carries out the steps it returns (timers, a queued
/// pause or resume, the volume); this decides.
///
/// Its state is four facts:
///  * [resumeArmed]: a transient loss interrupted playback the regain is to
///    resume;
///  * [pausePending]: a transient loss is waiting out its debounce before it
///    pauses, so a brief blip (screen off, Doze) never pauses at all;
///  * [ducked]: the volume is lowered for a duckable interruption;
///  * [held]: the media service stays in the foreground across the pause, so
///    the resume can still get audio focus from the background.
///
/// The Rust core runs the machine (native/linthra_core/src/audio_focus.rs);
/// this holds its state and hands it each event.
class AudioFocusMachine {
  int _bits = 0;

  bool get resumeArmed => _bits & 1 != 0;
  bool get pausePending => _bits & 2 != 0;
  bool get ducked => _bits & 4 != 0;
  bool get held => _bits & 8 != 0;

  /// The state as the Rust core numbers it.
  int get bits => _bits;
  set bits(int value) => _bits = value & 0x0F;

  /// Whether a transient loss holds playback paused for the regain to resume:
  /// armed, and past the debounce. A load landing meanwhile waits.
  bool get heldForTransientFocus => resumeArmed && !pausePending;

  /// Moves on for [event] and returns the steps to carry out, in order.
  List<int> handle(
    FocusEvent event, {
    FocusContext context = const FocusContext(),
  }) {
    final (int, List<int>) next =
        NativeAudioFocus.step(_bits, event.index, context.bits);
    _bits = next.$1;
    return next.$2;
  }
}
