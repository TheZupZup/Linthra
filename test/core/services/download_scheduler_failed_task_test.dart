// A task that throws while others wait hands its slot straight on.
//
// The scheduler's existing failure test throws with nobody waiting, where
// the slot only has to come back to the pool. With a download queued behind
// it, the failed one's slot must go to that download (the queue is how
// "Download all" gets through an album three at a time), and the count of
// running tasks must never pass the limit on the way.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/download_scheduler.dart';

Future<void> _pump() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a task that throws while another waits lets the waiting one run',
      () async {
    final DownloadScheduler scheduler = DownloadScheduler(maxConcurrent: 1);
    final Completer<void> aGate = Completer<void>();
    final Completer<void> bGate = Completer<void>();
    final List<int> activeWhileRunning = <int>[];
    bool bStarted = false;
    Object? aError;
    bool bDone = false;

    unawaited(scheduler.schedule<void>(() async {
      activeWhileRunning.add(scheduler.activeCount);
      await aGate.future;
      throw StateError('Jellyfin download failed.');
    }).catchError((Object error) {
      aError = error;
    }));
    unawaited(scheduler.schedule<void>(() async {
      bStarted = true;
      activeWhileRunning.add(scheduler.activeCount);
      await bGate.future;
    }).then((_) => bDone = true));
    await _pump();

    expect(bStarted, isFalse);
    expect(scheduler.activeCount, 1);
    expect(scheduler.pendingCount, 1);

    aGate.complete();
    await _pump();

    // a's error still reaches whoever scheduled it.
    expect(aError, isA<StateError>());
    // Its slot went to b: nothing is queued, and still only one runs.
    expect(bStarted, isTrue);
    expect(scheduler.pendingCount, 0);
    expect(scheduler.activeCount, 1);

    bGate.complete();
    await _pump();

    expect(bDone, isTrue);
    expect(scheduler.activeCount, 0);
    expect(activeWhileRunning, everyElement(lessThanOrEqualTo(1)));
  });
}
