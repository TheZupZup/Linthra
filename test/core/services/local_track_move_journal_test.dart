// How LocalTrackMoveApplier keeps a move some store couldn't take, and offers
// it again: only to the stores still missing it, in the order the moves were
// made, and never in a way that could move something it shouldn't.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/pending_track_move_store.dart';
import 'package:linthra/core/repositories/track_identity_reassignable.dart';
import 'package:linthra/core/services/local_track_move_applier.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';
import 'package:linthra/data/repositories/in_memory_pending_track_move_store.dart';

class _Store implements TrackIdentityReassignable {
  final List<String> calls = <String>[];
  bool refuse = false;

  @override
  Future<bool> reassignTrack({
    required String fromUri,
    required String toUri,
  }) async {
    calls.add('$fromUri -> $toUri');
    return !refuse;
  }
}

/// A pending record that can refuse its own save, or fail to be read.
class _Journal extends InMemoryPendingTrackMoveStore {
  bool refuse = false;

  /// Thrown by [load] instead of answering, when set.
  Object? loadError;

  /// Thrown by [save] instead of a refusal, when set.
  Object? saveError;

  /// Whether [setAside] can move a corrupt record out of the way, which
  /// leaves an empty record behind.
  bool setsAside = false;
  int setAsides = 0;
  int loads = 0;
  int saves = 0;

  @override
  Future<List<PendingTrackMove>> load() {
    loads++;
    if (loadError case final Object error) throw error;
    return super.load();
  }

  @override
  Future<bool> setAside() async {
    setAsides++;
    if (!setsAside) return false;
    loadError = null;
    await super.save(const <PendingTrackMove>[]);
    return true;
  }

  @override
  Future<void> save(List<PendingTrackMove> moves) async {
    saves++;
    if (saveError case final Object error) throw error;
    if (refuse) throw const LocalStoreWriteException(LocalStoreArea.trackMoves);
    return super.save(moves);
  }
}

const PendingTrackMoveJournalUnreadable _corrupt =
    PendingTrackMoveJournalUnreadable(PendingTrackMoveJournalFault.corrupt);
const PendingTrackMoveJournalUnreadable _readFailed =
    PendingTrackMoveJournalUnreadable(PendingTrackMoveJournalFault.readFailed);

/// What the journal's diagnostics recorded since the test began.
List<String> _reported() => <String>[
      for (final SafeEvent event in SafeEventLog.instance.events)
        if (event.category == 'track-move-journal') event.detail,
    ];

LocalCatalogReconciliation _moves(List<(String, String)> moves) =>
    LocalCatalogReconciliation(moves: <LocalTrackMove>[
      for (final (String from, String to) in moves)
        LocalTrackMove(from: from, to: to),
    ]);

void main() {
  late _Store a;
  late _Store b;
  late _Store c;
  late _Journal journal;

  setUp(() {
    SafeEventLog.instance.clear();
    a = _Store();
    b = _Store();
    c = _Store();
    journal = _Journal();
  });

  LocalTrackMoveApplier applier() => LocalTrackMoveApplier(
        <String, Object>{'a': a, 'b': b, 'c': c},
        pending: journal,
      );

  test('only the store that missed a move is asked again, once', () async {
    b.refuse = true;
    final result = await applier().apply(_moves(<(String, String)>[
      ('/old.flac', '/new.flac'),
    ]));

    expect(result.committed, isTrue);
    expect(await journal.load(), <PendingTrackMove>[
      const PendingTrackMove(
        from: '/old.flac',
        to: '/new.flac',
        targets: <String>{'b'},
      ),
    ]);

    a.calls.clear();
    b.calls.clear();
    c.calls.clear();
    b.refuse = false;
    await applier().apply(LocalCatalogReconciliation.none);

    expect(a.calls, isEmpty);
    expect(b.calls, <String>['/old.flac -> /new.flac']);
    expect(c.calls, isEmpty);
    expect(await journal.load(), isEmpty);

    // Nothing is left to do, so nothing is asked or written again.
    b.calls.clear();
    final int saves = journal.saves;
    await applier().apply(LocalCatalogReconciliation.none);
    expect(b.calls, isEmpty);
    expect(journal.saves, saves);
  });

  test("a store's later moves wait behind the one it refused, in order",
      () async {
    b.refuse = true;
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));
    // The song moves again before the store can take the first move. It
    // still holds /a.flac, so /b.flac -> /c.flac alone would change nothing.
    await applier().apply(_moves(<(String, String)>[('/b.flac', '/c.flac')]));

    expect(b.calls, <String>['/a.flac -> /b.flac', '/a.flac -> /b.flac']);
    expect(a.calls, <String>['/a.flac -> /b.flac', '/b.flac -> /c.flac']);
    expect(await journal.load(), <PendingTrackMove>[
      const PendingTrackMove(
        from: '/a.flac',
        to: '/b.flac',
        targets: <String>{'b'},
      ),
      const PendingTrackMove(
        from: '/b.flac',
        to: '/c.flac',
        targets: <String>{'b'},
      ),
    ]);

    b
      ..calls.clear()
      ..refuse = false;
    await applier().apply(LocalCatalogReconciliation.none);

    expect(b.calls, <String>['/a.flac -> /b.flac', '/b.flac -> /c.flac']);
    expect(await journal.load(), isEmpty);
  });

  test('a kept move is dropped once a file is at its old path again', () async {
    b.refuse = true;
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));
    b
      ..calls.clear()
      ..refuse = false;

    // Another file is at /a.flac now: what /a.flac holds may be its own.
    await applier().apply(
      LocalCatalogReconciliation.none,
      isPresent: (String uri) => uri == '/a.flac',
    );

    expect(b.calls, isEmpty);
    expect(await journal.load(), isEmpty);
  });

  test('a move that can neither land nor be kept holds the catalog back',
      () async {
    b.refuse = true;
    journal.refuse = true;

    final result = await applier().apply(
      _moves(<(String, String)>[('/old.flac', '/new.flac')]),
    );

    expect(result.committed, isFalse);
  });

  test('a kept move whose record is not rewritten is still kept', () async {
    b.refuse = true;
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));
    // Now b takes it, but the shorter record can't be saved.
    b.refuse = false;
    journal.refuse = true;

    final result = await applier().apply(LocalCatalogReconciliation.none);

    // The old record still names the move; asked again, b changes nothing.
    expect(result.committed, isTrue);
    expect(await journal.load(), hasLength(1));
  });

  group('a record that is there but cannot be read', () {
    setUp(() async {
      await journal.save(const <PendingTrackMove>[
        PendingTrackMove(
          from: '/a.flac',
          to: '/b.flac',
          targets: <String>{'b'},
        ),
      ]);
      journal.saves = 0;
    });

    test('is reported, never rewritten, and not taken for nothing pending',
        () async {
      journal.loadError = _corrupt;

      final result = await applier().apply(
        _moves(<(String, String)>[('/old.flac', '/new.flac')]),
      );

      // Every store took this scan's move, so there is nothing to keep.
      expect(result.committed, isTrue);
      expect(a.calls, <String>['/old.flac -> /new.flac']);
      expect(b.calls, <String>['/old.flac -> /new.flac']);
      expect(journal.saves, 0);
      expect(_reported(), <String>['corrupt']);

      // One store misses it: with nowhere to keep it, the catalog waits.
      b.refuse = true;
      final refused = await applier().apply(
        _moves(<(String, String)>[('/x.flac', '/y.flac')]),
      );
      expect(refused.committed, isFalse);
      expect(journal.saves, 0);
      expect(_reported(), <String>['corrupt', 'corrupt', 'held-back']);
    });

    test('holds back a scan that moved anything while it cannot be read',
        () async {
      journal.loadError = _readFailed;

      final result = await applier().apply(
        _moves(<(String, String)>[('/b.flac', '/c.flac')]),
      );

      // What it holds may come before this move, so nothing is moved yet:
      // with the catalog still at the old path, the next scan finds it again.
      expect(result.committed, isFalse);
      expect(a.calls, isEmpty);
      expect(b.calls, isEmpty);
      expect(journal.saves, 0);
      expect(_reported(), <String>['read-failed', 'held-back']);

      // A scan that moved nothing has nothing to lose.
      expect(
        (await applier().apply(LocalCatalogReconciliation.none)).committed,
        isTrue,
      );
      expect(journal.saves, 0);
    });

    test('an unexpected error reading it counts as a failed read', () async {
      journal.loadError = StateError('bug');

      final result = await applier().apply(
        _moves(<(String, String)>[('/b.flac', '/c.flac')]),
      );

      expect(result.committed, isFalse);
      expect(a.calls, isEmpty);
      expect(journal.saves, 0);
      expect(_reported(), <String>['unexpected: StateError', 'held-back']);
    });

    test(
        'once it can be read again, the moves land in the order they were made',
        () async {
      journal.loadError = _readFailed;
      await applier().apply(_moves(<(String, String)>[('/b.flac', '/c.flac')]));

      journal.loadError = null;
      // The catalog was held back, so the next scan proves the move again.
      final result = await applier().apply(
        _moves(<(String, String)>[('/b.flac', '/c.flac')]),
      );

      expect(result.committed, isTrue);
      expect(b.calls, <String>['/a.flac -> /b.flac', '/b.flac -> /c.flac']);
      expect(a.calls, <String>['/b.flac -> /c.flac']);
      expect(await journal.load(), isEmpty);
    });
  });

  test('a record that could not be saved is reported', () async {
    b.refuse = true;
    journal.refuse = true;
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));
    expect(_reported(), <String>['write-failed', 'held-back']);

    SafeEventLog.instance.clear();
    journal
      ..refuse = false
      ..saveError = StateError('bug');
    final result = await applier()
        .apply(_moves(<(String, String)>[('/c.flac', '/d.flac')]));
    expect(result.committed, isFalse);
    expect(_reported(), <String>['unexpected: StateError', 'held-back']);
  });

  test('the diagnostics never carry a path', () async {
    journal.loadError = _corrupt;
    b.refuse = true;
    await applier().apply(
      _moves(<(String, String)>[('/music/Private Name.flac', '/music/x.flac')]),
    );

    expect(_reported(), isNotEmpty);
    for (final String line in SafeEventLog.instance.lines) {
      expect(line, isNot(contains('/')));
      expect(line, isNot(contains('Private')));
    }
  });

  test('a scan with no moves and nothing kept writes nothing', () async {
    final result = await applier().apply(LocalCatalogReconciliation.none);

    expect(result.committed, isTrue);
    expect(journal.saves, 0);
  });

  test('a move every store takes leaves no record behind', () async {
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));

    expect(await journal.load(), isEmpty);
  });

  group('with the catalog write', () {
    test('the moves are on disk before it, and no store has moved yet',
        () async {
      List<PendingTrackMove>? onDiskAtCommit;
      List<String>? toldAtCommit;
      final result = await applier().apply(
        _moves(<(String, String)>[('/a.flac', '/b.flac')]),
        commit: () async {
          onDiskAtCommit = await journal.load();
          toldAtCommit = <String>[...a.calls, ...b.calls, ...c.calls];
        },
      );

      expect(result.committed, isTrue);
      expect(onDiskAtCommit, const <PendingTrackMove>[
        PendingTrackMove(
          from: '/a.flac',
          to: '/b.flac',
          targets: <String>{'a', 'b', 'c'},
        ),
      ]);
      expect(toldAtCommit, isEmpty);
      expect(a.calls, <String>['/a.flac -> /b.flac']);
      expect(await journal.load(), isEmpty);
    });

    test(
        'one that fails moves no store, and the next scan proves the move '
        'again from where the catalog still is', () async {
      await expectLater(
        applier().apply(
          _moves(<(String, String)>[('/a.flac', '/b.flac')]),
          commit: () async => throw StateError('disk full'),
        ),
        throwsStateError,
      );
      expect(<String>[...a.calls, ...b.calls, ...c.calls], isEmpty);

      // The file moved again meanwhile; the catalog still has /a.flac.
      final result = await applier().apply(
        _moves(<(String, String)>[('/a.flac', '/c.flac')]),
        wasIndexed: (String uri) => uri == '/a.flac',
      );

      expect(result.committed, isTrue);
      for (final _Store store in <_Store>[a, b, c]) {
        expect(store.calls, <String>['/a.flac -> /c.flac']);
      }
      expect(await journal.load(), isEmpty);
    });

    test('a move written but never told is told on the next scan', () async {
      // As left by an app stopped right after the catalog write.
      await journal.save(const <PendingTrackMove>[
        PendingTrackMove(
          from: '/a.flac',
          to: '/b.flac',
          targets: <String>{'a', 'b', 'c'},
        ),
      ]);

      await applier().apply(
        LocalCatalogReconciliation.none,
        wasIndexed: (String uri) => uri == '/b.flac',
      );

      for (final _Store store in <_Store>[a, b, c]) {
        expect(store.calls, <String>['/a.flac -> /b.flac']);
      }
      expect(await journal.load(), isEmpty);
    });

    test(
        'an entry it never wrote waits while its old folder is unread, and '
        'later moves for the same stores wait behind it', () async {
      await journal.save(const <PendingTrackMove>[
        PendingTrackMove(
          from: '/a.flac',
          to: '/b.flac',
          targets: <String>{'a', 'b', 'c'},
        ),
      ]);
      // /a.flac is still in the catalog, and this scan says nothing about it.
      await applier().apply(
        _moves(<(String, String)>[('/b.flac', '/c.flac')]),
        wasIndexed: (String uri) => uri == '/a.flac' || uri == '/b.flac',
      );
      expect(<String>[...a.calls, ...b.calls, ...c.calls], isEmpty);
      expect(await journal.load(), hasLength(2));

      // Its folder is read again, and the file is gone from there. The
      // catalog has moved on to /c.flac since.
      await applier().apply(
        const LocalCatalogReconciliation(removedUris: <String>['/a.flac']),
        wasIndexed: (String uri) => uri == '/a.flac' || uri == '/c.flac',
      );
      for (final _Store store in <_Store>[a, b, c]) {
        expect(
            store.calls, <String>['/a.flac -> /b.flac', '/b.flac -> /c.flac']);
      }
      expect(await journal.load(), isEmpty);
    });

    test('is not reached when the moves cannot be written ahead', () async {
      journal.refuse = true;
      int commits = 0;

      final result = await applier().apply(
        _moves(<(String, String)>[('/a.flac', '/b.flac')]),
        commit: () async => commits++,
      );

      expect(result.committed, isFalse);
      expect(commits, 0);
      expect(<String>[...a.calls, ...b.calls, ...c.calls], isEmpty);
    });

    test(
        'a corrupt record set aside leaves a new one, which keeps moves '
        'as usual', () async {
      journal
        ..loadError = _corrupt
        ..setsAside = true;
      b.refuse = true;
      List<String>? toldAtCommit;

      final result = await applier().apply(
        _moves(<(String, String)>[('/a.flac', '/b.flac')]),
        commit: () async =>
            toldAtCommit = <String>[...a.calls, ...b.calls, ...c.calls],
      );

      expect(result.committed, isTrue);
      expect(toldAtCommit, isEmpty);
      expect(_reported(), <String>['corrupt', 'set-aside']);
      expect(await journal.load(), const <PendingTrackMove>[
        PendingTrackMove(
          from: '/a.flac',
          to: '/b.flac',
          targets: <String>{'b'},
        ),
      ]);
    });

    test(
        'with a corrupt record that cannot be set aside, it waits until '
        'every store has the move, and is skipped when one refuses', () async {
      journal.loadError = _corrupt;
      final List<String> order = <String>[];

      await applier().apply(
        _moves(<(String, String)>[('/a.flac', '/b.flac')]),
        commit: () async => order.add('commit:${a.calls.length}'),
      );
      expect(order, <String>['commit:1']);

      b.refuse = true;
      final result = await applier().apply(
        _moves(<(String, String)>[('/c.flac', '/d.flac')]),
        commit: () async => order.add('commit'),
      );
      expect(result.committed, isFalse);
      expect(order, <String>['commit:1']);
    });
  });

  test('a scan whose record change cannot be saved waits, even with no moves',
      () async {
    await journal.save(const <PendingTrackMove>[
      PendingTrackMove(from: '/a.flac', to: '/b.flac', targets: <String>{'b'}),
    ]);
    journal.refuse = true;
    int commits = 0;

    // A file is at /a.flac again, so the kept move is dropped; written as
    // it is, the catalog would make that move look sound next time.
    final result = await applier().apply(
      LocalCatalogReconciliation.none,
      commit: () async => commits++,
      isPresent: (String uri) => uri == '/a.flac',
    );

    expect(result.committed, isFalse);
    expect(commits, 0);
    expect(b.calls, isEmpty);
  });

  group('a written move whose new path has left the catalog', () {
    test('is dropped', () async {
      await journal.save(const <PendingTrackMove>[
        PendingTrackMove(
            from: '/a.flac', to: '/b.flac', targets: <String>{'b'}),
      ]);

      await applier().apply(
        LocalCatalogReconciliation.none,
        wasIndexed: (String uri) => false,
      );

      expect(b.calls, isEmpty);
      expect(await journal.load(), isEmpty);
    });

    test('is kept when a later one goes on from there', () async {
      await journal.save(const <PendingTrackMove>[
        PendingTrackMove(
            from: '/a.flac', to: '/b.flac', targets: <String>{'b'}),
        PendingTrackMove(
            from: '/b.flac', to: '/c.flac', targets: <String>{'b'}),
      ]);

      await applier().apply(
        LocalCatalogReconciliation.none,
        wasIndexed: (String uri) => uri == '/c.flac',
      );

      expect(b.calls, <String>['/a.flac -> /b.flac', '/b.flac -> /c.flac']);
      expect(await journal.load(), isEmpty);
    });

    test('goes with the whole chain when its end has left too', () async {
      await journal.save(const <PendingTrackMove>[
        PendingTrackMove(
            from: '/a.flac', to: '/b.flac', targets: <String>{'b'}),
        PendingTrackMove(
            from: '/b.flac', to: '/c.flac', targets: <String>{'b'}),
      ]);

      await applier().apply(
        LocalCatalogReconciliation.none,
        wasIndexed: (String uri) => false,
      );

      expect(b.calls, isEmpty);
      expect(await journal.load(), isEmpty);
    });
  });

  test('a kept move for a store that is no longer there is dropped', () async {
    await journal.save(const <PendingTrackMove>[
      PendingTrackMove(
        from: '/a.flac',
        to: '/b.flac',
        targets: <String>{'gone'},
      ),
    ]);

    await applier().apply(LocalCatalogReconciliation.none);

    expect(a.calls, isEmpty);
    expect(await journal.load(), isEmpty);
  });

  test('without a record, a refused move holds the catalog back', () async {
    b.refuse = true;

    final result = await LocalTrackMoveApplier(
      <String, Object>{'a': a, 'b': b},
    ).apply(_moves(<(String, String)>[('/old.flac', '/new.flac')]));

    expect(result.committed, isFalse);
  });
}
