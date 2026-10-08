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

/// Why a [PendingTrackMoveStore] could not say what is pending.
enum PendingTrackMoveJournalFault {
  /// The storage did not answer. What it holds may be fine, and may be
  /// readable on the next try.
  readFailed,

  /// The record is there but is not one this version can read, in whole or
  /// in part: cut short by an interrupted write, damaged, or written by
  /// something else. Reading it again won't change that.
  corrupt,
}

/// Thrown by [PendingTrackMoveStore.load] when it can't tell what is pending.
/// Never the same as nothing pending: the record it couldn't read may be the
/// only trace of a move some store still has to take.
class PendingTrackMoveJournalUnreadable implements Exception {
  const PendingTrackMoveJournalUnreadable(this.fault);

  final PendingTrackMoveJournalFault fault;

  @override
  String toString() => 'PendingTrackMoveJournalUnreadable(${fault.name})';
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
  /// What is pending, in order: empty only when nothing is. Throws
  /// [PendingTrackMoveJournalUnreadable] when that can't be told.
  Future<List<PendingTrackMove>> load();

  /// Replaces what is kept with [moves]; an empty list clears it. Throws
  /// `LocalStoreWriteException` when the platform did not save it.
  Future<void> save(List<PendingTrackMove> moves);

  /// Moves a record [load] found corrupt out of the way, unchanged, to a place
  /// of its own where it is never deleted, so a new record can start.
  /// Completes with whether that is done: never by overwriting a record set
  /// aside earlier, and never for one that reads fine. Never throws.
  Future<bool> setAside();
}
