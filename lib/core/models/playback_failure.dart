import 'package:flutter/foundation.dart';

/// What broadly stopped a track from playing, in the terms a listener can act
/// on, not in the terms the backend failed in.
///
/// The four cases exist because each one has a *different* useful recovery:
/// waiting/retrying, reconnecting a drive, signing in again, or moving on. A
/// failure Linthra cannot place lands on [temporarySource], the kind whose
/// recovery (try again) is the least likely to waste the listener's time.
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
      };

  /// A few words for a surface with one line to spare (the mini-player), where
  /// the full [PlaybackFailure.message] would be cut off mid-sentence.
  String get shortLabel => switch (this) {
        PlaybackFailureKind.temporarySource => 'Playback problem',
        PlaybackFailureKind.localFileUnavailable => 'File unavailable',
        PlaybackFailureKind.sourceSignInRequired => 'Sign-in needed',
        PlaybackFailureKind.unplayableMedia => "Can't play this track",
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
    this.canRetry = false,
    this.canTryAnotherSource = false,
    this.canSkip = false,
  });

  /// What broadly went wrong, for the UI to branch on instead of matching text.
  final PlaybackFailureKind kind;

  /// A friendly, secret-free explanation safe to show as-is.
  final String message;

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
          other.canRetry == canRetry &&
          other.canTryAnotherSource == canTryAnotherSource &&
          other.canSkip == canSkip);

  @override
  int get hashCode =>
      Object.hash(kind, message, canRetry, canTryAnotherSource, canSkip);

  /// Safe to log: the kind and the flags, never the message (which is fixed
  /// text anyway) and never anything derived from the underlying error.
  @override
  String toString() => 'PlaybackFailure(${kind.name}, '
      'retry: $canRetry, anotherSource: $canTryAnotherSource, skip: $canSkip)';
}
