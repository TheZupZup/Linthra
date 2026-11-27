import '../native/native_playback_rules.dart';

/// Why a remote stream stopped mid-playback, classified from the audio engine's
/// raw error so the player can recover (a bounded retry) or show a precise,
/// friendly message.
enum StreamInterruptionKind {
  /// A transient connection glitch — usually recoverable with one retry.
  networkDropped,

  /// The server could not be reached (DNS, refused, unreachable).
  serverUnreachable,

  /// The server rejected the request — the session/token is no longer valid.
  sessionExpired,

  /// The engine can't decode this stream (unsupported container/codec).
  formatUnsupported,

  /// Anything else; treated as a transient glitch worth a single retry.
  unknown,

  /// An on-device file stopped being readable: deleted or moved, on an SD card
  /// or USB drive that was taken out, or a document whose access was revoked.
  ///
  /// Never produced by [classifyEngineError], because the engine's words don't
  /// say where the bytes came from: Android reports a file that can't be read
  /// and a stream that dropped with the same "Source error". The player picks
  /// this kind for an on-device file it has loaded that turns out to be gone,
  /// or a document that couldn't be read (which can't be checked further).
  /// Not worth a quick retry: no connection is involved, and a removed card or
  /// a deleted file is still gone a second later.
  localFileUnavailable,
}

/// A classified stream interruption: a [kind], a friendly, **secret-free**
/// [message] safe to show in the UI, and whether a retry is worth attempting.
class StreamInterruption {
  const StreamInterruption(
    this.kind,
    this.message, {
    required this.retryable,
  });

  final StreamInterruptionKind kind;
  final String message;
  final bool retryable;
}

/// The engine error code for "this source has audio, but no decoder on this
/// device can play it": Media3's `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`.
///
/// Linthra's patched just_audio raises it (see
/// third_party/just_audio/PATCHES.md) where Media3 alone would drop the audio
/// track and "play" silently, with the session reporting PLAYING and no error
/// at all. It means these bytes can't be decoded here, so it is never
/// retried.
const int unsupportedAudioFormatErrorCode = 4005;

/// Classifies an audio-engine error into a [StreamInterruption].
///
/// Security invariant: the engine's raw error can carry the tokenized stream URL
/// (e.g. a `ClientException` echoing the request URI). This NEVER echoes, logs,
/// or interpolates the error text — it only *reads* it to pick a branch and
/// returns a fixed, safe message. So a token can't leak through a playback error.
///
/// The track's own location is not evidence of anything: an item id, a
/// timestamp in a path or a token quoted in the text can hold `401` or
/// `403`, and read as a status would end a dropped connection as an expired
/// session. So locations are taken out before the text is read, all but the
/// slashes that aren't one: a status line's `HTTP/1.1` and an `I/O`, which
/// would otherwise take the status or the reason after them along.
///
/// The Rust core reads the text (native/linthra_core/src/playback_rules.rs).
StreamInterruption classifyEngineError(Object error) =>
    _interruptions[StreamInterruptionKind
        .values[NativePlaybackRules.classifyError(error.toString())]]!;

/// The one message and retry rule for each kind [classifyEngineError]
/// returns: fixed strings, so nothing of the engine's own text is ever shown.
const Map<StreamInterruptionKind, StreamInterruption> _interruptions =
    <StreamInterruptionKind, StreamInterruption>{
  StreamInterruptionKind.sessionExpired: StreamInterruption(
    StreamInterruptionKind.sessionExpired,
    'Your session expired. Sign in again to keep streaming.',
    retryable: false,
  ),
  StreamInterruptionKind.formatUnsupported: StreamInterruption(
    StreamInterruptionKind.formatUnsupported,
    "This track's format isn't supported on this device.",
    retryable: false,
  ),
  StreamInterruptionKind.serverUnreachable: StreamInterruption(
    StreamInterruptionKind.serverUnreachable,
    "Couldn't reach your music server. Check your connection and try again.",
    retryable: true,
  ),
  // Terminal-safe wording: the Now Playing UI shows "Reconnecting…" while
  // [PlaybackStatus.reconnecting] is active; this message is for a permanent
  // failure after the bounded retry is spent.
  StreamInterruptionKind.networkDropped: StreamInterruption(
    StreamInterruptionKind.networkDropped,
    'The connection dropped while streaming. Check your connection and try again.',
    retryable: true,
  ),
  StreamInterruptionKind.unknown: StreamInterruption(
    StreamInterruptionKind.unknown,
    'Playback was interrupted. Trying again…',
    retryable: true,
  ),
};
