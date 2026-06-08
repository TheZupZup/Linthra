import 'source_capability.dart';

/// A user-selectable strategy for ordering the source candidates of a song that
/// exists on more than one provider, so playback tries the best copy first.
///
/// The strategy only *reorders* candidates; it never invents one, never changes
/// de-duplication, and never decides the final source on its own — PR2 runtime
/// fallback still tries the next candidate if the first fails, and the
/// "Playing from …" indicator still reflects whichever copy actually started.
///
/// Determinism: ordering is a stable transform of the candidate list with the
/// original (default-provider) order as the final tie-breaker (see
/// [orderBySourceStrategy]). [preferDefault] is the identity, preserving the
/// PR1/PR2 behaviour exactly.
enum PlaybackSourceStrategy {
  /// Keep the default-provider order (PR1/PR2). The identity ordering.
  preferDefault(
    'Prefer default provider',
    'Use your default source order. Linthra still falls back to another copy '
        'if it fails.',
  ),

  /// Prefer copies that need no network — a downloaded/offline copy first, then
  /// an on-device file — before any server copy. Best for battery and data.
  preferLocalCache(
    'Prefer local/cache',
    'Play a downloaded or on-device copy when there is one. Best for battery '
        'and data.',
  ),

  /// Prefer the copy with the higher known quality. When quality is unknown it
  /// is left in its default position (never guessed), so a lower-quality copy is
  /// not silently chosen.
  preferHighestQuality(
    'Prefer highest quality',
    'Play the higher-quality copy when Linthra knows the quality; otherwise '
        'keep your default order.',
  ),

  /// Prefer the copy that uses less data — cache/local first, then the known
  /// lower-bitrate server copy. Unknown bitrate/size is left in default order.
  preferLowerData(
    'Prefer lower data usage',
    'Play a cached/on-device copy first, then the lighter server copy when '
        'Linthra knows the bitrate.',
  ),

  /// A conservative smart default: cache/local first, otherwise the default
  /// order. It avoids reordering server copies on guesses, so the chosen source
  /// stays stable between songs.
  automaticBalanced(
    'Automatic (balanced)',
    'Use cached/on-device copies when handy, otherwise your default order.',
  );

  const PlaybackSourceStrategy(this.label, this.description);

  /// A short, safe label for the settings UI.
  final String label;

  /// A one-line, safe explanation for the settings UI.
  final String description;

  /// Parses a persisted [name], falling back to [preferDefault] for an absent or
  /// unrecognised value — so a missing/old setting never changes behaviour.
  static PlaybackSourceStrategy fromStorage(String? name) {
    for (final PlaybackSourceStrategy s in values) {
      if (s.name == name) return s;
    }
    return preferDefault;
  }
}

/// Reorders [candidates] according to [strategy], using [profileOf] to read each
/// candidate's [PlaybackSourceCapability]. Pure and deterministic: the original
/// order is the final tie-breaker, so equal candidates never swap and
/// [PlaybackSourceStrategy.preferDefault] returns the list unchanged.
///
/// Conservative by design: a candidate is only moved by a quality/data rule when
/// the relevant value is actually known; unknown values keep their default slot
/// and are never faked. Generic over the candidate type so it can order `Track`s
/// in the app and `PlaybackSourceCapability`s directly in tests.
List<T> orderBySourceStrategy<T>(
  List<T> candidates,
  PlaybackSourceStrategy strategy,
  PlaybackSourceCapability Function(T) profileOf,
) {
  switch (strategy) {
    case PlaybackSourceStrategy.preferDefault:
      return List<T>.of(candidates);

    case PlaybackSourceStrategy.preferLocalCache:
      // Downloaded/offline first, then on-device, then server — default order
      // within each tier.
      return _stableByTier(candidates, (T c) => _localCacheTier(profileOf(c)));

    case PlaybackSourceStrategy.automaticBalanced:
      // Anything that needs no network first; otherwise the default order. No
      // server-vs-server guessing, so the source stays stable between songs.
      return _stableByTier(candidates, (T c) => _cheapTier(profileOf(c)));

    case PlaybackSourceStrategy.preferLowerData:
      // No-network copies first, then reorder *known* lower-bitrate server
      // copies among themselves; unknown bitrate stays in its default slot.
      final List<T> cheapFirst =
          _stableByTier(candidates, (T c) => _cheapTier(profileOf(c)));
      return _reorderKnownInPlace<T>(
        cheapFirst,
        eligible: (T c) => _cheapTier(profileOf(c)) != 0, // server copies only
        keyOf: (T c) => profileOf(c).bitrateKbps,
        better: (int a, int b) => a.compareTo(b), // lower bitrate = less data
      );

    case PlaybackSourceStrategy.preferHighestQuality:
      // Reorder *known* higher-bitrate copies among themselves; unknown quality
      // stays in its default slot (never guessed, never silently downgraded).
      return _reorderKnownInPlace<T>(
        candidates,
        eligible: (T c) => true,
        keyOf: (T c) => profileOf(c).bitrateKbps,
        better: (int a, int b) => b.compareTo(a), // higher bitrate = better
      );
  }
}

/// Tier for "prefer local/cache": a downloaded/offline copy (0) beats an
/// on-device file (1) beats a server copy (2).
int _localCacheTier(PlaybackSourceCapability c) {
  if (c.isCachedOffline) return 0;
  if (c.isLocalFile) return 1;
  return 2;
}

/// Tier for "needs no network": cache or local (0) beats a server copy (1).
int _cheapTier(PlaybackSourceCapability c) =>
    (c.isCachedOffline || c.isLocalFile) ? 0 : 1;

/// Stable sort by an integer [tierOf], with the original index as the final
/// tie-breaker so equal-tier candidates keep their default order.
List<T> _stableByTier<T>(List<T> items, int Function(T) tierOf) {
  final List<({T item, int tier, int index})> indexed =
      <({T item, int tier, int index})>[
    for (int i = 0; i < items.length; i++)
      (item: items[i], tier: tierOf(items[i]), index: i),
  ];
  indexed.sort((a, b) {
    final int byTier = a.tier.compareTo(b.tier);
    return byTier != 0 ? byTier : a.index.compareTo(b.index);
  });
  return <T>[for (final e in indexed) e.item];
}

/// Reorders only the candidates that are [eligible] *and* have a known [keyOf],
/// among the slots they already occupy, by [better] (original index breaks
/// ties). Every other candidate — ineligible, or with an unknown key — stays
/// exactly where it was, so unknown metadata never moves a row and the result is
/// fully deterministic.
List<T> _reorderKnownInPlace<T>(
  List<T> items, {
  required bool Function(T) eligible,
  required int? Function(T) keyOf,
  required int Function(int a, int b) better,
}) {
  final List<int> slots = <int>[];
  final List<({T item, int key, int index})> movable =
      <({T item, int key, int index})>[];
  for (int i = 0; i < items.length; i++) {
    final int? key = eligible(items[i]) ? keyOf(items[i]) : null;
    if (key != null) {
      slots.add(i);
      movable.add((item: items[i], key: key, index: i));
    }
  }
  if (movable.length < 2) return List<T>.of(items);
  movable.sort((a, b) {
    final int byKey = better(a.key, b.key);
    return byKey != 0 ? byKey : a.index.compareTo(b.index);
  });
  final List<T> result = List<T>.of(items);
  for (int s = 0; s < slots.length; s++) {
    result[slots[s]] = movable[s].item;
  }
  return result;
}
