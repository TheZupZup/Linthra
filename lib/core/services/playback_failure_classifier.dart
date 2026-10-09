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

    // There is no working backend to hand anything to. Kept apart from
    // [mediaUnsupported] because the recovery is different in kind: not
    // another copy of the song, but the machine's audio runtime.
    case PlaybackResolutionErrorKind.playbackEngineUnavailable:
      return PlaybackFailureKind.playbackEngineUnavailable;

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
    case StreamInterruptionKind.localFileUnavailable:
      return PlaybackFailureKind.localFileUnavailable;
    case StreamInterruptionKind.networkDropped:
    case StreamInterruptionKind.serverUnreachable:
    // An interruption Linthra can't place is treated as a glitch, here as in
    // [classifyEngineError]: the recovery it offers (try again) is the one most
    // likely to help and the cheapest to be wrong about.
    case StreamInterruptionKind.unknown:
      return PlaybackFailureKind.temporarySource;
  }
}

/// The [PlaybackFailureCause] a resolution or load failure of [kind] records.
PlaybackFailureCause playbackFailureCauseForResolution(
  PlaybackResolutionErrorKind kind,
) {
  switch (kind) {
    case PlaybackResolutionErrorKind.notSignedIn:
      return PlaybackFailureCause.notSignedIn;
    case PlaybackResolutionErrorKind.sessionExpired:
      return PlaybackFailureCause.sessionExpired;
    case PlaybackResolutionErrorKind.serverUnreachable:
      return PlaybackFailureCause.serverUnreachable;
    case PlaybackResolutionErrorKind.invalidStream:
      return PlaybackFailureCause.invalidStream;
    case PlaybackResolutionErrorKind.serverReturnedWebPage:
      return PlaybackFailureCause.serverReturnedWebPage;
    case PlaybackResolutionErrorKind.streamUnavailable:
      return PlaybackFailureCause.streamUnavailable;
    case PlaybackResolutionErrorKind.localFileMissing:
      return PlaybackFailureCause.fileUnavailable;
    case PlaybackResolutionErrorKind.mediaUnsupported:
      return PlaybackFailureCause.audioNotDecoded;
    case PlaybackResolutionErrorKind.playbackEngineUnavailable:
      return PlaybackFailureCause.engineUnavailable;
  }
}

/// The [PlaybackFailureCause] a mid-stream interruption of [kind] records.
PlaybackFailureCause playbackFailureCauseForInterruption(
  StreamInterruptionKind kind,
) {
  switch (kind) {
    case StreamInterruptionKind.networkDropped:
      return PlaybackFailureCause.connectionDropped;
    case StreamInterruptionKind.serverUnreachable:
      return PlaybackFailureCause.serverUnreachable;
    case StreamInterruptionKind.sessionExpired:
      return PlaybackFailureCause.sessionExpired;
    case StreamInterruptionKind.formatUnsupported:
      return PlaybackFailureCause.audioNotDecoded;
    case StreamInterruptionKind.localFileUnavailable:
      return PlaybackFailureCause.fileUnavailable;
    case StreamInterruptionKind.unknown:
      return PlaybackFailureCause.unrecognized;
  }
}
