import '../models/playback_failure.dart';
import 'provider_reachability.dart';

/// What the player does next, on its own, after a track failed.
enum PlaybackRecoveryStep {
  /// Try the same track once more after a pause, re-resolving it (a fresh
  /// stream URL) at the position it stopped.
  retry,

  /// Move on to the next track in the queue after a pause.
  advance,

  /// Stop and show the failure. Nothing further happens until the listener
  /// does something.
  settle,
}

/// One decision from [PlaybackRecoveryPolicy.decide]: the step, and how long to
/// wait before taking it.
class PlaybackRecoveryDecision {
  const PlaybackRecoveryDecision._(this.step, this.delay);

  static const PlaybackRecoveryDecision settle =
      PlaybackRecoveryDecision._(PlaybackRecoveryStep.settle, Duration.zero);

  const PlaybackRecoveryDecision.retry(Duration delay)
      : this._(PlaybackRecoveryStep.retry, delay);

  const PlaybackRecoveryDecision.advance(Duration delay)
      : this._(PlaybackRecoveryStep.advance, delay);

  final PlaybackRecoveryStep step;
  final Duration delay;

  @override
  String toString() =>
      'PlaybackRecoveryDecision(${step.name}, ${delay.inMilliseconds}ms)';
}

/// The tracks that have failed back to back since something last played to its
/// end or the listener last did something, plus whether this run of failures
/// has already had its one automatic retry.
///
/// Identity is the track's opaque `uri`, never the bare id, so two providers'
/// copies of one song are tracked apart. Holds no URL, token or title.
class PlaybackFailureStreak {
  final Set<String> _failed = <String>{};
  int _failures = 0;
  bool _retrySpent = false;

  /// How many failures have been recorded in a row. Counts every one, even a
  /// track failing twice, so the cap holds whatever the queue looks like.
  int get length => _failures;

  bool get isEmpty => _failures == 0;

  /// Whether the one automatic retry this streak allows has been used.
  bool get retrySpent => _retrySpent;

  bool contains(String uri) => _failed.contains(uri);

  void noteRetry() => _retrySpent = true;

  void record(String uri) {
    _failed.add(uri);
    _failures++;
  }

  /// Starts over: a track played to its end, or the listener took over.
  void clear() {
    _failed.clear();
    _failures = 0;
    _retrySpent = false;
  }
}

/// How far the player goes on its own when a track can't be played, before it
/// stops and waits for the listener.
///
/// Pure and I/O-free, so the rules below are unit-testable without an engine,
/// and every limit lives here rather than as numbers spread through the
/// controller:
///
///  1. **An engine failure settles at once.** Every track plays through the
///     same engine, so moving on would fail identically for each of them.
///  2. **The first failure in a streak gets one more try** when the source may
///     come back on its own ([PlaybackFailureKind.temporarySource]): wait
///     [retryDelay], then re-resolve the same track. That covers a network
///     handover or a server that blinked. The default wait outlasts the
///     provider's reachability memory, so the retry really reaches the server
///     instead of being answered with the outage it just recorded. Later
///     failures in the same streak don't get one: they are almost certainly the
///     same outage, and retrying each of them would only slow the listener down
///     and hit the server more.
///  3. **Then it moves on**, to the next track, or back to the first under
///     repeat-all, waiting [advanceDelay] before the first move and twice as
///     long before each later one (capped at [maxAdvanceDelay]). Cached and
///     local tracks further on still play while a server is down.
///  4. **It stops** when [maxConsecutiveFailures] tracks have failed in a row,
///     when the next track already failed in this streak (the queue has come
///     all the way round, which is what stops repeat-all cycling through a dead
///     server forever), or when there is nothing left to move to.
///
/// Worst case with the defaults: one retry and five moves, about 33 seconds of
/// waiting in total, then a stable error. The provider's own short
/// reachability memory means a down server is contacted at most about once
/// per ten seconds while this runs; the rest fail fast without a request.
class PlaybackRecoveryPolicy {
  const PlaybackRecoveryPolicy({
    this.retryDelay = CachingProviderReachability.defaultTtl,
    this.advanceDelay = const Duration(seconds: 1),
    this.maxAdvanceDelay = const Duration(seconds: 8),
    this.maxConsecutiveFailures = 6,
  }) : assert(maxConsecutiveFailures >= 1);

  /// How long to wait before the one automatic retry of a failed track.
  final Duration retryDelay;

  /// How long to wait before moving past the first failed track. Doubles for
  /// each further failure in the same streak, up to [maxAdvanceDelay].
  final Duration advanceDelay;

  final Duration maxAdvanceDelay;

  /// How many different tracks may fail back to back before the player stops.
  final int maxConsecutiveFailures;

  /// Whether a failure of [kind] may clear up if the same track is simply tried
  /// again in a moment. Only a source problem can: a rejected sign-in, bytes
  /// that won't decode, or a missing file give the same answer seconds later.
  bool retriesAutomatically(PlaybackFailureKind kind) =>
      kind == PlaybackFailureKind.temporarySource;

  /// Whether a failure of [kind] is about this track (so another track may
  /// well play) rather than about the engine every track plays through.
  bool movesPast(PlaybackFailureKind kind) => !kind.isEngineFailure;

  /// The wait before moving past the [failures]th consecutive failed track.
  Duration delayBeforeAdvance(int failures) {
    Duration delay = advanceDelay;
    for (int i = 1; i < failures && delay < maxAdvanceDelay; i++) {
      delay *= 2;
    }
    return delay > maxAdvanceDelay ? maxAdvanceDelay : delay;
  }

  /// What to do after the track [failedUri] failed with [kind], given the
  /// [streak] so far and the track the queue would move to next ([nextUri],
  /// `null` when there is none). Doesn't touch [streak]; the caller records the
  /// retry or the failure once it acts on the decision.
  PlaybackRecoveryDecision decide({
    required PlaybackFailureKind kind,
    required String failedUri,
    required String? nextUri,
    required PlaybackFailureStreak streak,
  }) {
    if (!movesPast(kind)) return PlaybackRecoveryDecision.settle;
    if (streak.isEmpty && !streak.retrySpent && retriesAutomatically(kind)) {
      return PlaybackRecoveryDecision.retry(retryDelay);
    }
    // This failure plus the ones before it.
    final int failures = streak.length + 1;
    if (failures >= maxConsecutiveFailures) {
      return PlaybackRecoveryDecision.settle;
    }
    if (nextUri == null || nextUri == failedUri || streak.contains(nextUri)) {
      return PlaybackRecoveryDecision.settle;
    }
    return PlaybackRecoveryDecision.advance(delayBeforeAdvance(failures));
  }
}
