import '../models/playback_failure.dart';
import 'playable_uri_resolver.dart';
import 'stream_interruption.dart';

/// Bridges the two typed failure vocabularies playback already has,
/// [PlaybackResolutionErrorKind] (couldn't produce a playable URI) and
/// [StreamInterruptionKind] (the engine stopped mid-stream), onto the single
/// [PlaybackFailureKind] the UI reasons about.
///
/// Both switches are exhaustive on purpose: adding a resolution or interruption
/// kind is a compile error here rather than a failure that silently lands on
/// the wrong recovery. Nothing in this file touches an error's *text*, so no
/// message, URL, or token can leak through the mapping.
PlaybackFailureKind playbackFailureKindForResolution(
  PlaybackResolutionErrorKind kind,
) {
  switch (kind) {
    // No session, or one the server no longer accepts: another attempt with the
    // same credentials gets the same answer.
    case PlaybackResolutionErrorKind.notSignedIn:
    case PlaybackResolutionErrorKind.sessionExpired:
      return PlaybackFailureKind.sourceSignInRequired;

    // The file is the thing that isn't there; no server was involved.
    case PlaybackResolutionErrorKind.localFileMissing:
      return PlaybackFailureKind.localFileUnavailable;

    // The backend could not open or decode what it was handed.
    case PlaybackResolutionErrorKind.mediaUnsupported:
      return PlaybackFailureKind.unplayableMedia;

    // Everything else is the source misbehaving rather than the music being
    // unplayable: unreachable, a challenge/login page, a non-audio answer, or
    // no stream right now. All of them can be fine on the next attempt.
    case PlaybackResolutionErrorKind.serverUnreachable:
    case PlaybackResolutionErrorKind.invalidStream:
    case PlaybackResolutionErrorKind.serverReturnedWebPage:
    case PlaybackResolutionErrorKind.streamUnavailable:
      return PlaybackFailureKind.temporarySource;
  }
}

/// The [PlaybackFailureKind] a classified mid-stream interruption implies.
PlaybackFailureKind playbackFailureKindForInterruption(
  StreamInterruptionKind kind,
) {
  switch (kind) {
    case StreamInterruptionKind.sessionExpired:
      return PlaybackFailureKind.sourceSignInRequired;
    case StreamInterruptionKind.formatUnsupported:
      return PlaybackFailureKind.unplayableMedia;
    case StreamInterruptionKind.networkDropped:
    case StreamInterruptionKind.serverUnreachable:
    // An interruption Linthra can't place is treated as a glitch, here as in
    // [classifyEngineError]: the recovery it offers (try again) is the one most
    // likely to help and the cheapest to be wrong about.
    case StreamInterruptionKind.unknown:
      return PlaybackFailureKind.temporarySource;
  }
}
