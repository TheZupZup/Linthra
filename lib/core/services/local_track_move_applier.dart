import '../repositories/local_store_write_exception.dart';
import '../repositories/pending_track_move_store.dart';
import '../repositories/track_identity_reassignable.dart';
import '../sources/local/local_catalog_reconciliation.dart';
import 'stability_diagnostics.dart';

/// Carries the state that lives *outside* the catalog across a local file's
/// move, by handing each proven move to every collaborator that keys something
/// on the track uri.
///
/// The catalog itself needs nothing from this: the moved file was re-scanned at
/// its new path and its row is written there. What breaks without it is
/// everything else keyed on that path: the play count behind Most played, the
/// heart, the "added on" date behind Recently added, the song's place in a
/// playlist, all of which would still be pointing at a file that no longer
/// exists, so the user's own listening history quietly resets because they
/// tidied up a folder.
///
/// Collaborators opt in by implementing [TrackIdentityReassignable]; anything
/// that does not is skipped, so a test fake or a store with no per-track state
/// needs no changes. They never throw, so this never fails a scan.
///
/// A store that can't save a move right now says so, and the move is kept in
/// [pending], with the names of the stores still to take it, and offered to
/// them again on every scan until they all have. It can't be left to the next
/// scan to find: once the catalog has the new path, the file is simply there,
/// and no scan sees a move any more. For the same reason the stores and the
/// catalog move together, through [apply].
class LocalTrackMoveApplier {
  const LocalTrackMoveApplier(this.targets, {this.pending});

  /// The names the stores are kept under in [pending]. Saved with pending
  /// moves, so they stay as they are.
  static const String library = 'library';
  static const String favorites = 'favorites';
  static const String playHistory = 'playHistory';
  static const String playlists = 'playlists';

  /// Everything that might key state on a track uri, by name. Entries that are
  /// not reassignable are ignored, so a caller can pass its repositories
  /// unconditionally rather than testing each one at the call site.
  final Map<String, Object> targets;

  /// Where moves a store couldn't take wait. Without one, such a move can't be
  /// kept, and [apply] says so.
  final PendingTrackMoveStore? pending;

  /// Applies every move in [reconciliation], and those still pending from
  /// earlier scans, to every reassignable target, and writes the catalog
  /// through [commit] where neither can get ahead of the other. Completes with
  /// whether the catalog was written; when it wasn't, no store moved either,
  /// and the catalog still at the old path lets the next scan find the move
  /// again. A [commit] that throws is rethrown.
  ///
  /// With a readable record, this scan's moves are saved to it first, for
  /// every store, then the catalog is written, then the stores are told, and
  /// the record keeps only what a store refused. So a store is never ahead of
  /// the catalog. If the app stops after the write, the record still names
  /// every store, and a move offered again to a store that has it changes
  /// nothing.
  ///
  /// If the write fails, or the app stops before it, the catalog still has
  /// the old path, and this scan's entries wait in the record until a scan
  /// settles them:
  ///
  ///  * one that proves a move from the same path replaces the entry,
  ///    wherever the file went since;
  ///  * one that finds a file at the old path again ([isPresent]) drops it:
  ///    what is under that path may be that file's now, and moving it would be
  ///    a guess (this goes for any pending move);
  ///  * one that confirms the file is gone from there lets it through;
  ///  * one that couldn't read the old path's folder leaves it waiting, and
  ///    with it every later move for the same stores. [wasIndexed] says the
  ///    old path is still in the catalog.
  ///
  /// Moves go to each target in the order they were made. Once one is refused,
  /// the target's later moves wait behind it, even those that would change
  /// nothing yet: after `a -> b` and `b -> c`, a playlist still on `a` needs
  /// both, in that order.
  ///
  /// A record that can't be read is never taken for an empty one, and never
  /// rewritten. When it didn't answer, it may hold a move this scan's must
  /// follow, so a scan that proved a move writes nothing. When it is corrupt,
  /// waiting won't make it readable, so this scan's moves are handled as with
  /// no record at all: the stores are told first, and the catalog is written
  /// only once all of them have the moves.
  ///
  /// The catalog write stamps any uri it has never seen with `now`. That is
  /// fine for a move told after it: the library keeps the earlier of two
  /// "added on" times, which is the moved file's.
  ///
  /// `moves` is how many moves the scan proved.
  Future<({int moves, bool committed})> apply(
    LocalCatalogReconciliation reconciliation, {
    Future<void> Function()? commit,
    bool Function(String uri)? isPresent,
    bool Function(String uri)? wasIndexed,
  }) async {
    final Map<String, TrackIdentityReassignable> stores =
        <String, TrackIdentityReassignable>{
      for (final MapEntry<String, Object> target in targets.entries)
        if (target.value is TrackIdentityReassignable)
          target.key: target.value as TrackIdentityReassignable,
    };
    final List<LocalTrackMove> moves = reconciliation.moves;
    final Future<void> Function() write = commit ?? () async {};
    if (stores.isEmpty) {
      await write();
      return (moves: moves.length, committed: true);
    }

    final PendingTrackMoveStore? store = pending;
    List<PendingTrackMove> waiting = const <PendingTrackMove>[];
    bool corrupt = false;
    if (store != null) {
      try {
        waiting = await store.load();
      } on PendingTrackMoveJournalUnreadable catch (error) {
        if (error.fault == PendingTrackMoveJournalFault.corrupt) {
          StabilityDiagnostics.trackMoveJournal('corrupt');
          corrupt = true;
        } else {
          StabilityDiagnostics.trackMoveJournal('read-failed');
          return _withoutMoving(moves.length, write);
        }
      } catch (error) {
        StabilityDiagnostics.trackMoveJournalFailedUnexpectedly(error);
        return _withoutMoving(moves.length, write);
      }
    }
    if (store == null || corrupt) return _storesFirst(stores, moves, write);

    final Set<String> movedNow = <String>{
      for (final LocalTrackMove move in moves) move.from,
    };
    final Set<String> goneNow = <String>{...reconciliation.removedUris};
    final List<_Move> work = <_Move>[
      for (final PendingTrackMove move in waiting)
        if (!(isPresent?.call(move.from) ?? false) &&
            !movedNow.contains(move.from))
          _Move(
            move.from,
            move.to,
            <String>{
              for (final String name in move.targets)
                if (stores.containsKey(name)) name,
            },
            waits: (wasIndexed?.call(move.from) ?? false) &&
                !goneNow.contains(move.from),
          ),
      for (final LocalTrackMove move in moves)
        _Move(move.from, move.to, <String>{...stores.keys}),
    ];
    List<PendingTrackMove> onDisk = waiting;
    final List<PendingTrackMove> ahead = _pending(work);
    if (!_same(ahead, onDisk)) {
      if (await _save(store, ahead)) {
        onDisk = ahead;
      } else if (moves.isNotEmpty) {
        return _heldBack(moves.length);
      }
    }
    await write();
    await _offer(stores, work);
    final List<PendingTrackMove> left = _pending(work);
    // Not saved, the record still holds moves some store has since taken:
    // offered again, they change nothing.
    if (!_same(left, onDisk)) await _save(store, left);
    return (moves: moves.length, committed: true);
  }

  /// With no record to keep a move in, the stores are told first, and the
  /// catalog is written only once all of them have this scan's moves.
  static Future<({int moves, bool committed})> _storesFirst(
    Map<String, TrackIdentityReassignable> stores,
    List<LocalTrackMove> moves,
    Future<void> Function() write,
  ) async {
    final List<_Move> work = <_Move>[
      for (final LocalTrackMove move in moves)
        _Move(move.from, move.to, <String>{...stores.keys}),
    ];
    await _offer(stores, work);
    if (work.any((_Move move) => move.left.isNotEmpty)) {
      return _heldBack(moves.length);
    }
    await write();
    return (moves: moves.length, committed: true);
  }

  /// The catalog is written only when this scan proved no move.
  static Future<({int moves, bool committed})> _withoutMoving(
    int moves,
    Future<void> Function() write,
  ) async {
    if (moves > 0) return _heldBack(moves);
    await write();
    return (moves: moves, committed: true);
  }

  /// Offers [work] to each store in order, up to the first move it refuses or
  /// that has to wait.
  static Future<void> _offer(
    Map<String, TrackIdentityReassignable> stores,
    List<_Move> work,
  ) async {
    for (final MapEntry<String, TrackIdentityReassignable> target
        in stores.entries) {
      for (final _Move move in work) {
        if (!move.left.contains(target.key)) continue;
        if (move.waits) break;
        final bool saved = await target.value.reassignTrack(
          fromUri: move.from,
          toUri: move.to,
        );
        if (!saved) {
          StabilityDiagnostics.trackMoveKept(target.key);
          break;
        }
        move.left.remove(target.key);
      }
    }
  }

  static List<PendingTrackMove> _pending(List<_Move> work) =>
      <PendingTrackMove>[
        for (final _Move move in work)
          if (move.left.isNotEmpty)
            PendingTrackMove(
              from: move.from,
              to: move.to,
              targets: <String>{...move.left},
            ),
      ];

  static Future<bool> _save(
    PendingTrackMoveStore store,
    List<PendingTrackMove> moves,
  ) async {
    try {
      await store.save(moves);
      return true;
    } on LocalStoreWriteException {
      StabilityDiagnostics.trackMoveJournal('write-failed');
    } catch (error) {
      StabilityDiagnostics.trackMoveJournalFailedUnexpectedly(error);
    }
    return false;
  }

  static ({int moves, bool committed}) _heldBack(int moves) {
    StabilityDiagnostics.trackMoveJournal('held-back');
    return (moves: moves, committed: false);
  }

  static bool _same(List<PendingTrackMove> a, List<PendingTrackMove> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A move being offered, and the targets it is still to reach.
class _Move {
  _Move(this.from, this.to, this.left, {this.waits = false});

  final String from;
  final String to;
  final Set<String> left;

  /// Its catalog write never happened, and this scan couldn't settle it.
  final bool waits;
}
