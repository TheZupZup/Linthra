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

/// Classifies an audio-engine error into a [StreamInterruption].
///
/// Security invariant: the engine's raw error can carry the tokenized stream URL
/// (e.g. a `ClientException` echoing the request URI). This NEVER echoes, logs,
/// or interpolates the error text — it only *reads* it to pick a branch and
/// returns a fixed, safe message. So a token can't leak through a playback error.
StreamInterruption classifyEngineError(Object error) {
  final String text = error.toString().toLowerCase();

  bool mentions(List<String> needles) =>
      needles.any((String needle) => text.contains(needle));

  // Auth first: a rejected session is not worth retrying — prompt a sign-in.
  if (mentions(<String>['401', '403', 'unauthor', 'forbidden'])) {
    return const StreamInterruption(
      StreamInterruptionKind.sessionExpired,
      'Your session expired. Sign in again to keep streaming.',
      retryable: false,
    );
  }
  // A decode failure won't fix itself by retrying the same bytes.
  if (mentions(<String>[
    'unsupported',
    'decoder',
    'codec',
    'unable to instantiate',
    'parse',
  ])) {
    return const StreamInterruption(
      StreamInterruptionKind.formatUnsupported,
      "This track's format isn't supported on this device.",
      retryable: false,
    );
  }
  // The server isn't answering at all — worth one retry, then a friendly notice.
  if (mentions(<String>[
    'unreachable',
    'refused',
    'failed host lookup',
    'no address',
    'name resolution',
  ])) {
    return const StreamInterruption(
      StreamInterruptionKind.serverUnreachable,
      "Couldn't reach your music server. Check your connection and try again.",
      retryable: true,
    );
  }
  // A transient network drop mid-stream — the common case to recover from.
  if (mentions(<String>[
    'timeout',
    'timed out',
    'network',
    'connection',
    'reset',
    'source error',
    'socket',
    'broken pipe',
    'eof',
  ])) {
    return const StreamInterruption(
      StreamInterruptionKind.networkDropped,
      'The connection dropped while streaming. Reconnecting…',
      retryable: true,
    );
  }
  // Unknown: assume a transient glitch and allow a single retry.
  return const StreamInterruption(
    StreamInterruptionKind.unknown,
    'Playback was interrupted. Trying again…',
    retryable: true,
  );
}
