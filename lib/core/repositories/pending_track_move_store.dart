import 'package:flutter/foundation.dart' show immutable, setEquals;

/// A local file's move that the scan proved but some stores could not take
/// yet: what was saved under [from] still has to go to [to] in each store
/// named in [targets].
@immutable
class PendingTrackMove {
  const PendingTrackMove({
    required this.from,
    required this.to,
    required this.targets,
  });

  final String from;
  final String to;

  /// The names of the stores still to be told, as `LocalTrackMoveApplier`
  /// knows them.
  final Set<String> targets;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingTrackMove &&
          other.from == from &&
          other.to == to &&
          setEquals(other.targets, targets));

  @override
  int get hashCode => Object.hash(from, to, Object.hashAllUnordered(targets));

  @override
  String toString() => 'PendingTrackMove($from -> $to, $targets)';
}

/// Where the moves some store missed wait to be applied again, in the order
/// they were made.
///
/// It has to outlive the process. The catalog is written at the new path
/// whether or not every store took the move, and from then on no scan can tell
/// that the song moved: a move kept only in memory is lost on the next launch,
/// and with it the playlist entry or heart still pointing at the old path.
///
/// Holds local paths only, the same ones the catalog and the other stores
/// keep. Empty almost always: a move is here only until every store has it.
abstract interface class PendingTrackMoveStore {
  Future<List<PendingTrackMove>> load();

  /// Replaces what is kept with [moves]; an empty list clears it. Throws
  /// `LocalStoreWriteException` when the platform did not save it.
  Future<void> save(List<PendingTrackMove> moves);
}
