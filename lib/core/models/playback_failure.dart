import 'package:flutter/foundation.dart';

/// What broadly stopped a track from playing, in the terms a listener can act
/// on, not in the terms the backend failed in.
///
/// The cases exist because each one has a *different* useful recovery:
/// waiting/retrying, reconnecting a drive, signing in again, moving on, or
/// fixing the machine's audio runtime. A failure Linthra cannot place lands on
/// [temporarySource], the kind whose recovery (try again) is the least likely
/// to waste the listener's time.
enum PlaybackFailureKind {
  /// A network or provider problem that may well clear on its own: the server
  /// is unreachable, the connection dropped, the stream came back as something
  /// other than audio.
  temporarySource,

  /// An on-device file that isn't where the catalog has it: moved, deleted, or
  /// on a drive that isn't mounted right now. Nothing here is a server.
  localFileUnavailable,

  /// The source rejected the session, or no account backs this track's source.
  /// The fix is a sign-in, not another attempt with the same credentials.
  sourceSignInRequired,

  /// The audio backend cannot play these bytes: an unsupported container or
  /// codec, a corrupt file, a decoder the platform doesn't have, or, on a host
  /// with no audio engine at all, nothing to play them with.
  unplayableMedia,

  /// The audio engine itself is not usable on this machine: the native runtime
  /// it plays through is missing, cannot be loaded, or would not start.
  ///
  /// The odd one out, and deliberately so. Every other kind is about *this
  /// track*, so the queue still means something and another copy of the song
  /// or the next track is worth a try. This one is about the engine every
  /// track shares, so nothing else in the queue would play either and the fix
  /// is outside the app. Raised on Linux, where the runtime is a system
  /// package (see `LinuxPlaybackRuntime`); Android ships its engine inside the
  /// app and never produces it.
  playbackEngineUnavailable,
}

/// What Linthra found out about a failure, one step finer than its
/// [PlaybackFailureKind], for the details a listener can open and the report
/// they can copy from there.
///
/// A closed set of constants, like the kind, and for the same reason: the
/// error it is worked out from is classified, never quoted, so neither can
/// carry the error's own text (where a URL, a token or a path would be).
enum PlaybackFailureCause {
  /// No account is signed in for this track's source.
  notSignedIn,

  /// The source turned the saved sign-in down.
  sessionExpired,

  /// The server didn't answer, or stopped answering mid-stream.
  serverUnreachable,

  /// The connection dropped while the track was playing.
  connectionDropped,

  /// The server answered with a web page instead of audio.
  serverReturnedWebPage,

  /// The server's answer wasn't a stream Linthra could use.
  invalidStream,

  /// The server had no stream for this track when asked.
  streamUnavailable,

  /// The file isn't where the library has it, or can't be read there.
  fileUnavailable,

  /// The audio engine couldn't open or decode the audio.
  audioNotDecoded,

  /// The audio engine itself isn't working on this machine.
  engineUnavailable,

  /// Playback stopped with an engine error Linthra couldn't place.
  unrecognized,
}

/// A recovery the listener can take from a failed track.
///
/// Deliberately small: everything else (open Settings, rescan, sign in) is a
/// trip out of the player, and the player's job here is to get the music going
/// again or get out of the way.
enum PlaybackRecoveryAction {
  /// Try the same copy of the same track again.
  retry,

  /// Play the same song from another provider that has it.
  tryAnotherSource,

  /// Give up on this track and advance to the next queued one.
  skip,
}

extension PlaybackFailureKindRecovery on PlaybackFailureKind {
  /// Whether trying the *same* copy again can plausibly work.
  ///
  /// A server that was unreachable a second ago may answer now, and a drive
  /// that wasn't mounted may be mounted, so those two get a Retry. A rejected
  /// session re-presented unchanged is rejected again, and bytes that would not
  /// decode do not decode on the second read: offering Retry there would only
  /// spend the listener's taps on a fixed answer.
  bool get isWorthRetrying => switch (this) {
        PlaybackFailureKind.temporarySource => true,
        PlaybackFailureKind.localFileUnavailable => true,
        PlaybackFailureKind.sourceSignInRequired => false,
        PlaybackFailureKind.unplayableMedia => false,
        // The retry here is the listener saying "I fixed it": installing the
        // runtime package and trying again is the whole recovery, and it is
        // the only one on offer.
        PlaybackFailureKind.playbackEngineUnavailable => true,
      };

  /// Whether this failure is the *engine's* rather than this track's.
  ///
  /// It changes what the error panel may offer. One audio engine plays every
  /// track, so when the engine is what failed, another copy of the song and
  /// the next track in the queue fail identically: offering either would be
  /// offering a button that cannot work. It also lifts the bounded attempt
  /// budget, because that budget exists to stop a listener tapping Retry at a
  /// source with a fixed answer, and here the answer changes the moment they
  /// fix their machine. Taking the only button away after three taps would
  /// leave a dead player and nothing to press.
  bool get isEngineFailure =>
      this == PlaybackFailureKind.playbackEngineUnavailable;

  /// A few words for a surface with one line to spare (the mini-player), where
  /// the full [PlaybackFailure.message] would be cut off mid-sentence.
  String get shortLabel => switch (this) {
        PlaybackFailureKind.temporarySource => 'Playback problem',
        PlaybackFailureKind.localFileUnavailable => 'File unavailable',
        PlaybackFailureKind.sourceSignInRequired => 'Sign-in needed',
        PlaybackFailureKind.unplayableMedia => "Can't play this track",
        PlaybackFailureKind.playbackEngineUnavailable =>
          'Audio engine unavailable',
      };
}

/// Why the current track isn't playing, and what the listener can do about it.
///
/// This is the single error model the player surfaces: the mini-player, the
/// now-playing screen and (later) any other playback surface read this rather
/// than each deciding for itself what a failure means. The controller builds it
/// at the moment playback gives up, because that is the only place that knows
/// all three inputs: what failed, whether another copy of the song exists, and
/// whether the retry budget is spent.
///
/// Security invariant, inherited from every failure that feeds it: [message] is
/// fixed, friendly text. It NEVER carries an access token, an authenticated
/// stream URL, a server address, a local file path, or a raw backend exception.
/// Constructing one from an engine or HTTP error means *classifying* that error
/// and picking safe wording, never interpolating it.
@immutable
class PlaybackFailure {
  const PlaybackFailure({
    required this.kind,
    required this.message,
    this.cause,
    this.canRetry = false,
    this.canTryAnotherSource = false,
    this.canSkip = false,
    this.canAutoSkip = false,
  });

  /// What broadly went wrong, for the UI to branch on instead of matching text.
  final PlaybackFailureKind kind;

  /// A friendly, secret-free explanation safe to show as-is.
  final String message;

  /// What went wrong, more precisely than [kind], when the controller knows.
  /// Null when it doesn't, which the details say rather than guess at.
  final PlaybackFailureCause? cause;

  /// Whether trying this same copy again is worth offering: the kind can
  /// plausibly recover ([PlaybackFailureKindRecovery.isWorthRetrying]) *and*
  /// this track's bounded attempt budget still has room.
  final bool canRetry;

  /// Whether this song has another provider copy to try, and the attempt budget
  /// still has room for it. False for a single-source track (the everyday
  /// case), so the action never appears where it cannot do anything.
  final bool canTryAnotherSource;

  /// Whether there is a next track in the queue to move on to.
  final bool canSkip;

  /// Whether an automatic skip would have somewhere to go: the next track
  /// that hasn't failed, wrapping to the start under repeat-all, and never
  /// under repeat-one. Wider than [canSkip], which is the listener's own Skip
  /// and follows the queue as it reads. Not an action of its own: it is what
  /// decides whether asking about automatic skip can help with this failure.
  final bool canAutoSkip;

  /// The offered recoveries, in the order the UI should show them: the cheapest
  /// and most likely to work first, giving up last. Empty when nothing can be
  /// done here, which is an honest answer the UI renders as a plain message.
  List<PlaybackRecoveryAction> get actions => <PlaybackRecoveryAction>[
        if (canRetry) PlaybackRecoveryAction.retry,
        if (canTryAnotherSource) PlaybackRecoveryAction.tryAnotherSource,
        if (canSkip) PlaybackRecoveryAction.skip,
      ];

  /// Whether any recovery is on offer.
  bool get hasActions => actions.isNotEmpty;

  /// A few words for a one-line surface; the full [message] everywhere else.
  String get shortLabel => kind.shortLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackFailure &&
          other.kind == kind &&
          other.message == message &&
          other.cause == cause &&
          other.canRetry == canRetry &&
          other.canTryAnotherSource == canTryAnotherSource &&
          other.canSkip == canSkip &&
          other.canAutoSkip == canAutoSkip);

  @override
  int get hashCode => Object.hash(kind, message, cause, canRetry,
      canTryAnotherSource, canSkip, canAutoSkip);

  /// Safe to log: the kind, the cause and the flags, never the message (which
  /// is fixed text anyway) and never anything quoted from the underlying error.
  @override
  String toString() => 'PlaybackFailure(${kind.name}, '
      '${cause == null ? '' : 'cause: ${cause!.name}, '}'
      'retry: $canRetry, anotherSource: $canTryAnotherSource, skip: $canSkip, '
      'autoSkip: $canAutoSkip)';
}

/// An automatic move past a track that could not be recovered, counting down.
///
/// Published on [PlaybackState] by the controller for exactly as long as its
/// own timer is pending, and never by anything else, so a surface showing the
/// countdown shows the skip that is actually going to happen: it disappears
/// the moment a skip, a pause, a new queue or a Retry calls the move off, and
/// the move itself can only ever come from the controller. A surface that
/// renders the seconds left reads them from [skipsAt]; it never decides when
/// to skip.
@immutable
class PendingAutoSkip {
  const PendingAutoSkip({
    required this.failure,
    required this.skipsAt,
    required this.countdown,
  });

  /// Why the track is being skipped, in the same safe terms the error panel
  /// uses.
  final PlaybackFailure failure;

  /// When the controller moves on, unless something calls it off first.
  final DateTime skipsAt;

  /// How long the whole countdown is, for a surface that shows its progress.
  final Duration countdown;

  /// Whole seconds left before the move at [now], never below zero and never
  /// above the [countdown] rounded up. For display only.
  int secondsLeft(DateTime now) {
    final int left = skipsAt.difference(now).inMilliseconds;
    if (left <= 0) return 0;
    final int total = (countdown.inMilliseconds / 1000).ceil();
    final int seconds = (left / 1000).ceil();
    return seconds > total ? total : seconds;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingAutoSkip &&
          other.failure == failure &&
          other.skipsAt == skipsAt &&
          other.countdown == countdown);

  @override
  int get hashCode => Object.hash(failure, skipsAt, countdown);

  @override
  String toString() =>
      'PendingAutoSkip($failure, in ${countdown.inMilliseconds}ms)';
}
