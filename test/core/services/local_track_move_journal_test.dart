// How LocalTrackMoveApplier keeps a move some store couldn't take, and offers
// it again: only to the stores still missing it, in the order the moves were
// made, and never in a way that could move something it shouldn't.
import 'package:flutter_test/flutter_test.dart';
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
  bool unreadable = false;
  int loads = 0;
  int saves = 0;

  @override
  Future<List<PendingTrackMove>> load() {
    loads++;
    if (unreadable) throw StateError('unreadable');
    return super.load();
  }

  @override
  Future<void> save(List<PendingTrackMove> moves) async {
    saves++;
    if (refuse) throw const LocalStoreWriteException(LocalStoreArea.trackMoves);
    return super.save(moves);
  }
}

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

    expect(result.kept, isTrue);
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

    expect(result.kept, isFalse);
  });

  test('a kept move whose record is not rewritten is still kept', () async {
    b.refuse = true;
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));
    // Now b takes it, but the shorter record can't be saved.
    b.refuse = false;
    journal.refuse = true;

    final result = await applier().apply(LocalCatalogReconciliation.none);

    // The old record still names the move; asked again, b changes nothing.
    expect(result.kept, isTrue);
    expect(await journal.load(), hasLength(1));
  });

  test('an unreadable record is left alone; this scan still moves', () async {
    journal.unreadable = true;

    final result = await applier().apply(
      _moves(<(String, String)>[('/old.flac', '/new.flac')]),
    );

    expect(result.kept, isTrue);
    expect(a.calls, <String>['/old.flac -> /new.flac']);
    expect(journal.saves, 0);

    b.refuse = true;
    final refused = await applier().apply(
      _moves(<(String, String)>[('/x.flac', '/y.flac')]),
    );
    expect(refused.kept, isFalse);
    expect(journal.saves, 0);
  });

  test('a scan with no moves and nothing kept writes nothing', () async {
    await applier().apply(LocalCatalogReconciliation.none);
    await applier().apply(_moves(<(String, String)>[('/a.flac', '/b.flac')]));

    expect(journal.saves, 0);
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

    expect(result.kept, isFalse);
  });
}
