import '../repositories/track_identity_reassignable.dart';
import '../sources/local/local_catalog_reconciliation.dart';

/// Carries the state that lives *outside* the catalog across a local file's
/// move, by handing each proven move to every collaborator that keys something
/// on the track uri.
///
/// The catalog itself needs nothing from this: the moved file was re-scanned at
/// its new path and its row is written there. What breaks without it is
/// everything else keyed on that path: the play count behind Most played, the
/// heart, the "added on" date behind Recently added, all of which would still
/// be pointing at a file that no longer exists, so the user's own listening
/// history quietly resets because they tidied up a folder.
///
/// Collaborators opt in by implementing [TrackIdentityReassignable]; anything
/// that does not is skipped, so a test fake or a store with no per-track state
/// needs no changes. Failures are swallowed by the implementations themselves
/// (that is their contract), so this never fails a scan.
class LocalTrackMoveApplier {
  const LocalTrackMoveApplier(this.targets);

  /// Everything that might key state on a track uri. Non-reassignable entries
  /// are ignored, so a caller can pass its repositories unconditionally rather
  /// than testing each one at the call site.
  final List<Object> targets;

  /// Applies every move in [reconciliation], in order, to every reassignable
  /// target.
  ///
  /// **Call this before the catalog write.** `RecordingMusicLibraryRepository`
  /// stamps any uri it has never seen with `now`, so a write that introduces
  /// the new path first would mark the moved file as newly added before its
  /// real date could be carried over.
  ///
  /// Returns the number of moves applied, which is what the caller logs or
  /// asserts on; zero when there was nothing to move.
  Future<int> apply(LocalCatalogReconciliation reconciliation) async {
    final List<LocalTrackMove> moves = reconciliation.moves;
    if (moves.isEmpty) return 0;
    final List<TrackIdentityReassignable> reassignable =
        <TrackIdentityReassignable>[
      for (final Object target in targets)
        if (target is TrackIdentityReassignable) target,
    ];
    if (reassignable.isEmpty) return 0;
    for (final LocalTrackMove move in moves) {
      for (final TrackIdentityReassignable target in reassignable) {
        await target.reassignTrack(fromUri: move.from, toUri: move.to);
      }
    }
    return moves.length;
  }
}
