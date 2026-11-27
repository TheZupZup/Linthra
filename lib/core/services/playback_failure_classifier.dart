import '../models/playback_failure.dart';
import '../native/native_playback_rules.dart';
import 'playable_uri_resolver.dart';
import 'stream_interruption.dart';

/// Decided by the Rust core (native/linthra_core/src/playback_rules.rs).
///
/// Bridges the two typed failure vocabularies playback already has,
/// [PlaybackResolutionErrorKind] (couldn't produce a playable URI) and
/// [StreamInterruptionKind] (the engine stopped mid-stream), onto the single
/// [PlaybackFailureKind] the UI reasons about. A session the server no longer
/// accepts asks for a sign-in; a missing file or undecodable audio won't fix
/// itself; a source that misbehaves (unreachable, a login page, no stream
/// right now, an interruption Linthra can't place) may be fine next time.
/// Nothing here touches an error's *text*, so no message, URL, or token can
/// leak through the mapping.
PlaybackFailureKind playbackFailureKindForResolution(
  PlaybackResolutionErrorKind kind,
) =>
    PlaybackFailureKind
        .values[NativePlaybackRules.failureForResolution(kind.index).$1];

/// The [PlaybackFailureKind] a classified mid-stream interruption implies.
PlaybackFailureKind playbackFailureKindForInterruption(
  StreamInterruptionKind kind,
) =>
    PlaybackFailureKind
        .values[NativePlaybackRules.failureForInterruption(kind.index).$1];

/// The [PlaybackFailureCause] a resolution or load failure of [kind] records.
PlaybackFailureCause playbackFailureCauseForResolution(
  PlaybackResolutionErrorKind kind,
) =>
    PlaybackFailureCause
        .values[NativePlaybackRules.failureForResolution(kind.index).$2];

/// The [PlaybackFailureCause] a mid-stream interruption of [kind] records.
PlaybackFailureCause playbackFailureCauseForInterruption(
  StreamInterruptionKind kind,
) =>
    PlaybackFailureCause
        .values[NativePlaybackRules.failureForInterruption(kind.index).$2];
