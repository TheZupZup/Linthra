import '../../core/models/track.dart';

/// Which tracks a list has selected, and where a Shift-click measures from.
///
/// Held by the screen rather than by the rows, so it survives a rebuild of the
/// list — a catalog refresh, a download finishing, a position tick — and so a
/// row never has to know anything about its neighbours (#387).
///
/// Membership is keyed by the provider-namespaced uri, never the bare id: a
/// local `file:///…` copy and a `jellyfin:101` copy of the same song are
/// different rows with different actions, and two providers' same-id copies
/// must never end up selected together.
///
/// Pure, so the awkward parts — an anchor for a row that has since been
/// filtered out, a range dragged backwards, a selection that outlives the
/// tracks it named — are unit-testable without pumping a list.
class TrackSelection {
  final Set<String> _uris = <String>{};

  /// The row a Shift-click extends from: the last row the user picked
  /// deliberately, which is what every desktop list means by it.
  String? _anchorUri;

  bool get isActive => _uris.isNotEmpty;

  int get length => _uris.length;

  bool contains(String uri) => _uris.contains(uri);

  /// The selected uris, for a list that renders its own rows' checkboxes.
  Set<String> get uris => _uris;

  /// The uri a Shift-click would extend from, or null when there is none.
  String? get anchorUri => _anchorUri;

  /// Starts a fresh selection at [track] — a long-press, or a plain click on a
  /// row while nothing is selected.
  void start(Track track) {
    _uris
      ..clear()
      ..add(track.uri);
    _anchorUri = track.uri;
  }

  /// Adds or removes one row, the way Ctrl-click does.
  ///
  /// The anchor follows the click either way: after Ctrl-clicking a row, a
  /// Shift-click extends from *there*, whether the Ctrl-click selected the row
  /// or deselected it.
  void toggle(Track track) {
    if (!_uris.add(track.uri)) {
      _uris.remove(track.uri);
    }
    _anchorUri = track.uri;
    if (_uris.isEmpty) _anchorUri = null;
  }

  /// Selects everything between the anchor and [index] of [tracks], inclusive.
  ///
  /// [tracks] is the list the clicked row is actually in — already sorted and
  /// filtered as the user sees it — so a range can never span rows that are not
  /// on screen between the two ends. With no anchor, or an anchor no longer in
  /// this list (it was filtered out, or removed), the click behaves as a plain
  /// [start]: extending from a row that is not there would select an arbitrary
  /// run.
  void extendTo(List<Track> tracks, int index) {
    if (index < 0 || index >= tracks.length) return;
    final String? anchor = _anchorUri;
    final int from = anchor == null
        ? -1
        : tracks.indexWhere((Track track) => track.uri == anchor);
    if (from < 0) {
      start(tracks[index]);
      return;
    }
    final int lo = from < index ? from : index;
    final int hi = from < index ? index : from;
    for (int i = lo; i <= hi; i++) {
      _uris.add(tracks[i].uri);
    }
    // The anchor stays where it was, so dragging a Shift-click back and forth
    // grows and shrinks from the same end rather than walking away from it.
  }

  void clear() {
    _uris.clear();
    _anchorUri = null;
  }

  /// The selected tracks, in the order [tracks] has them.
  ///
  /// Filtering here rather than storing [Track]s is what keeps a bulk action
  /// honest: rows that have since left the list (removed, or filtered out by a
  /// search) simply are not in the result, so an action can never reach a row
  /// the count in the app bar does not describe.
  List<Track> resolve(List<Track> tracks) {
    return <Track>[
      for (final Track track in tracks)
        if (_uris.contains(track.uri)) track,
    ];
  }
}
