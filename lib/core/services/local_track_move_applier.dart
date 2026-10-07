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
/// and no scan sees a move any more.
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

  /// Offers the moves still pending from earlier scans, then every move in
  /// [reconciliation], in order, to every reassignable target, and keeps
  /// whatever a target couldn't take.
  ///
  /// A pending move whose old path [isPresent] reports has a file again is
  /// dropped: what is left under that path may be that file's now, and moving
  /// it would be a guess.
  ///
  /// Moves go to each target in the order they were made. Once one is refused,
  /// the target's later moves wait behind it, even those that would change
  /// nothing yet: after `a -> b` and `b -> c`, a playlist still on `a` needs
  /// both, in that order.
  ///
  /// **Call this before the catalog write.** `RecordingMusicLibraryRepository`
  /// stamps any uri it has never seen with `now`, so a write that introduces
  /// the new path first would mark the moved file as newly added before its
  /// real date could be carried over. And only write the catalog when the
  /// result says `kept`: otherwise a move some store missed couldn't be saved
  /// for later, and the catalog still at the old path is the only record of it
  /// (the next scan finds the move again).
  ///
  /// `moves` is how many moves the scan proved.
  Future<({int moves, bool kept})> apply(
    LocalCatalogReconciliation reconciliation, {
    bool Function(String uri)? isPresent,
  }) async {
    final Map<String, TrackIdentityReassignable> stores =
        <String, TrackIdentityReassignable>{
      for (final MapEntry<String, Object> target in targets.entries)
        if (target.value is TrackIdentityReassignable)
          target.key: target.value as TrackIdentityReassignable,
    };
    final List<LocalTrackMove> moves = reconciliation.moves;

    List<PendingTrackMove> waiting = const <PendingTrackMove>[];
    bool readable = true;
    final PendingTrackMoveStore? store = pending;
    if (store != null) {
      try {
        waiting = await store.load();
      } catch (_) {
        // What was kept can't be read now. It is still there, so it is left
        // alone; only this scan's moves are offered.
        readable = false;
      }
    }
    if (waiting.isEmpty && (moves.isEmpty || stores.isEmpty)) {
      return (moves: moves.length, kept: true);
    }

    final List<_Move> work = <_Move>[
      for (final PendingTrackMove move in waiting)
        if (!(isPresent?.call(move.from) ?? false))
          _Move(
            move.from,
            move.to,
            <String>{
              for (final String name in move.targets)
                if (stores.containsKey(name)) name,
            },
            fromThisScan: false,
          ),
      for (final LocalTrackMove move in moves)
        _Move(
          move.from,
          move.to,
          <String>{...stores.keys},
          fromThisScan: true,
        ),
    ];
    for (final MapEntry<String, TrackIdentityReassignable> target
        in stores.entries) {
      for (final _Move move in work) {
        if (!move.left.contains(target.key)) continue;
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

    final List<PendingTrackMove> left = <PendingTrackMove>[
      for (final _Move move in work)
        if (move.left.isNotEmpty)
          PendingTrackMove(from: move.from, to: move.to, targets: move.left),
    ];
    // A move from an earlier scan whose record isn't rewritten is still kept
    // as it was, at worst naming stores that have it since: offering it to
    // them again changes nothing. One from this scan has no record elsewhere.
    final bool newOnesLeft =
        work.any((_Move move) => move.fromThisScan && move.left.isNotEmpty);
    if (store == null || !readable) {
      return (moves: moves.length, kept: !newOnesLeft);
    }
    if (_same(left, waiting)) return (moves: moves.length, kept: true);
    try {
      await store.save(left);
    } catch (_) {
      return (moves: moves.length, kept: !newOnesLeft);
    }
    return (moves: moves.length, kept: true);
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
  _Move(this.from, this.to, this.left, {required this.fromThisScan});

  final String from;
  final String to;
  final Set<String> left;
  final bool fromThisScan;
}
