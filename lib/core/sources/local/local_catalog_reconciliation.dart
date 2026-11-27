import 'dart:typed_data';

import '../../models/track.dart';
import '../../native/native_local_reconcile.dart';
import 'local_track_identity.dart';

/// One file that the scan proved is the same track at a new path.
///
/// [from] and [to] are both [Track.uri]s, which for a local file is its path.
/// The catalog row itself needs no help (the file was re-scanned at [to] and
/// written there), but everything Linthra keys on the uri *outside* the catalog
/// (play counts, hearts, "added on") would otherwise be left pointing at a path
/// that no longer exists.
class LocalTrackMove {
  const LocalTrackMove({required this.from, required this.to});

  /// Where the file used to be.
  final String from;

  /// Where the scan just found it.
  final String to;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalTrackMove && other.from == from && other.to == to);

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'LocalTrackMove($from -> $to)';
}

/// What a scan learned about files that are no longer where the catalog says
/// they are: which ones moved, and which ones are simply gone.
class LocalCatalogReconciliation {
  const LocalCatalogReconciliation({
    this.moves = const <LocalTrackMove>[],
    this.removedUris = const <String>[],
  });

  static const LocalCatalogReconciliation none = LocalCatalogReconciliation();

  /// Files that turned up somewhere else, with identity proven.
  final List<LocalTrackMove> moves;

  /// Files a readable folder no longer contains, and that did not turn up
  /// anywhere else. These are confirmed deletions: the folder answered, and the
  /// file was not in it.
  final List<String> removedUris;

  bool get isEmpty => moves.isEmpty && removedUris.isEmpty;

  /// Works out which of [previous] moved and which are gone, given the tracks
  /// [scanned] just found.
  ///
  /// Only tracks under a folder the scan actually **read** are considered:
  /// [wasRefreshed] answers whether a previously indexed uri belonged to one of
  /// those folders. A track under an unplugged drive was never looked for, so it
  /// is neither moved nor deleted, just unknown this time, and saying
  /// otherwise is how a library loses an album to a loose USB cable.
  ///
  /// The matching rule is deliberately conservative, and refuses in three
  /// separate ways:
  ///
  ///  * a track with no tag-derived identity ([LocalTrackIdentity.of] returning
  ///    null) never matches, because its title and folders come from the path;
  ///  * an identity carried by more than one disappeared track is ambiguous,
  ///    because we cannot tell which of them the new file is;
  ///  * an identity carried by more than one newly-seen file is ambiguous too,
  ///    because a duplicated file must not consume the original's history.
  ///
  /// Every refusal falls back to the same safe outcome: the old path counts as
  /// deleted, the new path counts as a brand-new track, and no history changes
  /// hands.
  ///
  /// Runs in the Rust core (native/linthra_core/src/local_reconcile.rs).
  static LocalCatalogReconciliation resolve({
    required List<Track> previous,
    required List<Track> scanned,
    required bool Function(String uri) wasRefreshed,
  }) {
    if (previous.isEmpty) return none;
    // The uri sets stay in Dart: only the files that left a folder the scan
    // read, and the ones that turned up, need an identity, and those are
    // all that cross to Rust.
    final Set<String> scannedUris = <String>{
      for (final Track track in scanned) track.uri,
    };
    final List<Track> disappeared = <Track>[
      for (final Track track in previous)
        if (!scannedUris.contains(track.uri) && wasRefreshed(track.uri)) track,
    ];
    if (disappeared.isEmpty) return none;
    final Set<String> previousUris = <String>{
      for (final Track track in previous) track.uri,
    };
    final List<Track> appeared = <Track>[
      for (final Track track in scanned)
        if (!previousUris.contains(track.uri)) track,
    ];
    final ({Uint32List moves, Uint32List removed}) native =
        NativeLocalReconcile.resolve(
      previous: disappeared,
      refreshed: List<bool>.filled(disappeared.length, true),
      scanned: appeared,
    );
    return LocalCatalogReconciliation(
      moves: List<LocalTrackMove>.unmodifiable(<LocalTrackMove>[
        for (int i = 0; i < native.moves.length; i += 2)
          LocalTrackMove(
            from: disappeared[native.moves[i]].uri,
            to: appeared[native.moves[i + 1]].uri,
          ),
      ]),
      removedUris: List<String>.unmodifiable(<String>[
        for (final int i in native.removed) disappeared[i].uri,
      ]),
    );
  }
}
