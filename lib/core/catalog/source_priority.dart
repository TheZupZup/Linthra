import 'package:flutter/foundation.dart';

/// The deterministic order in which providers are preferred for playback when a
/// single logical track can be played from more than one source.
///
/// "Active/default first": the user's preferred order (most-recently-signed-in
/// server at the front) is consulted first; any source not named there falls
/// back to a fixed default tail so the ordering is *total* and predictable —
/// the same catalog always resolves to the same preferred source. Local files
/// sit last by default, so a server copy (which can also cast and sync) is
/// preferred when the same song exists both on a server and on the device,
/// while a device-only track still plays locally.
@immutable
class SourcePriority {
  const SourcePriority(this.preferredOrder);

  /// The fixed fallback order used for any source the user's [preferredOrder]
  /// does not mention. Remote servers before local; among servers this is just a
  /// stable, documented default that the live preference normally overrides.
  static const List<String> defaultOrder = <String>[
    'jellyfin',
    'subsonic',
    'plex',
    'local',
  ];

  /// A priority with no explicit user preference — everything falls back to
  /// [defaultOrder]. Used by surfaces that only need *a* deterministic choice
  /// (e.g. the Android Auto browse tree) rather than the user's live preference.
  static const SourcePriority fallback = SourcePriority(<String>[]);

  /// The user-preferred source ids, most-preferred first. May be empty (then
  /// only [defaultOrder] applies) and may omit sources (they fall back).
  final List<String> preferredOrder;

  /// The rank of [sourceId] — lower is more preferred. A source named in
  /// [preferredOrder] always outranks one that is only in [defaultOrder], which
  /// in turn outranks a wholly unknown source; ties never occur for distinct
  /// known ids. Unknown ids share a single trailing rank and are then separated
  /// by the candidate comparator's stable id tiebreak.
  int rankOf(String sourceId) {
    final int preferred = preferredOrder.indexOf(sourceId);
    if (preferred >= 0) return preferred;
    final int fallbackIndex = defaultOrder.indexOf(sourceId);
    if (fallbackIndex >= 0) return preferredOrder.length + fallbackIndex;
    // An unknown source: after everything else, but still deterministic.
    return preferredOrder.length + defaultOrder.length;
  }

  /// Moves [sourceId] to the front of the preference, returning a new priority.
  /// Used when the user signs into a server: the one they are actively using
  /// becomes the default for picking among duplicate sources.
  SourcePriority promote(String sourceId) {
    return SourcePriority(<String>[
      sourceId,
      for (final String id in preferredOrder)
        if (id != sourceId) id,
    ]);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourcePriority &&
          listEquals(other.preferredOrder, preferredOrder));

  @override
  int get hashCode => Object.hashAll(preferredOrder);
}
