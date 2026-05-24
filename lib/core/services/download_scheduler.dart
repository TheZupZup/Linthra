import 'dart:async';
import 'dart:collection';

/// A small, fair concurrency gate for offline downloads.
///
/// It lets several downloads fetch their bytes at once — which is dramatically
/// faster than the old strictly-sequential path — while keeping a hard ceiling
/// so the app never opens an unbounded number of network requests. Work handed
/// to [schedule] runs immediately when a slot is free; otherwise it waits in a
/// FIFO queue and starts as soon as an earlier task finishes (success *or*
/// failure — a failed download must always free its slot).
///
/// This is deliberately a tiny, dependency-free primitive: the download
/// *policy* (status, dedup, cache limit, Wi-Fi) stays in the repository, and
/// the *concurrency* lives here, so each is small and testable on its own.
class DownloadScheduler {
  DownloadScheduler({this.maxConcurrent = defaultMaxConcurrent})
      : assert(maxConcurrent >= 1, 'maxConcurrent must be at least 1'),
        _permits = maxConcurrent;

  /// A safe, fixed default: fast enough to feel parallel, small enough that it
  /// never floods the network or the server with requests.
  static const int defaultMaxConcurrent = 3;

  /// The most downloads allowed to fetch their bytes at the same time.
  final int maxConcurrent;

  int _permits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// How many tasks are currently running (holding a slot).
  int get activeCount => maxConcurrent - _permits;

  /// How many tasks are waiting for a slot to free up.
  int get pendingCount => _waiters.length;

  /// Runs [task] once a slot is free, releasing the slot when it completes
  /// (whether it returns or throws). Returns [task]'s result or rethrows its
  /// error, so callers can `await` a scheduled download exactly as before.
  Future<T> schedule<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_permits > 0) {
      _permits -= 1;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // Hand the slot straight to the next waiter (it stays "active"), keeping
      // exactly [maxConcurrent] tasks running while any are queued.
      _waiters.removeFirst().complete();
    } else {
      _permits += 1;
    }
  }
}
