import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/download_scheduler.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('DownloadScheduler', () {
    test('runs up to maxConcurrent tasks at once and queues the rest',
        () async {
      final scheduler = DownloadScheduler(maxConcurrent: 2);
      final gates = <Completer<void>>[
        Completer<void>(),
        Completer<void>(),
        Completer<void>(),
      ];
      final started = <int>[];

      for (var i = 0; i < gates.length; i++) {
        final index = i;
        unawaited(scheduler.schedule<void>(() async {
          started.add(index);
          await gates[index].future;
        }));
      }
      await _pump();

      // Only two slots, so only the first two tasks have started.
      expect(started, <int>[0, 1]);
      expect(scheduler.activeCount, 2);
      expect(scheduler.pendingCount, 1);

      // Finishing one frees its slot for the queued task.
      gates[0].complete();
      await _pump();
      expect(started, <int>[0, 1, 2]);
      expect(scheduler.activeCount, 2);
      expect(scheduler.pendingCount, 0);

      gates[1].complete();
      gates[2].complete();
      await _pump();
      expect(scheduler.activeCount, 0);
    });

    test('runs tasks right away when below the limit', () async {
      final scheduler = DownloadScheduler(maxConcurrent: 3);
      final results = <int>[];

      await Future.wait(<Future<void>>[
        scheduler.schedule<void>(() async {
          results.add(1);
        }),
        scheduler.schedule<void>(() async {
          results.add(2);
        }),
      ]);

      expect(results, containsAll(<int>[1, 2]));
      expect(scheduler.activeCount, 0);
      expect(scheduler.pendingCount, 0);
    });

    test('frees the slot even when a task throws', () async {
      final scheduler = DownloadScheduler(maxConcurrent: 1);

      await expectLater(
        scheduler.schedule<void>(() async {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );

      // The failed task released its slot, so the next one still runs.
      var ran = false;
      await scheduler.schedule<void>(() async {
        ran = true;
      });
      expect(ran, isTrue);
      expect(scheduler.activeCount, 0);
    });

    test('preserves FIFO order for queued tasks', () async {
      final scheduler = DownloadScheduler(maxConcurrent: 1);
      final order = <int>[];

      final futures = <Future<void>>[
        for (var i = 0; i < 4; i++)
          scheduler.schedule<void>(() async {
            order.add(i);
          }),
      ];
      await Future.wait(futures);

      expect(order, <int>[0, 1, 2, 3]);
    });
  });
}
