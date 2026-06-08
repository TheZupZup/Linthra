import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/source_priority.dart';
import '../../data/repositories/default_provider_store_provider.dart';
import '../../data/repositories/preferred_source_store_provider.dart';

/// Holds the user's *explicit* default playback provider, or `null` for
/// **Automatic** (no explicit choice).
///
/// This is the single setting the user toggles on the Settings screen. When set
/// to a source id (`jellyfin`, `subsonic`, `local`) the
/// [SourcePreferenceController] pins that provider to the front of the playback
/// preference; when `null` the library keeps its automatic, most-recently-
/// signed-in behaviour. The choice is loaded from the [DefaultProviderStore] at
/// startup and persisted on every change, so it survives a restart. Until the
/// async load lands the controller serves `null` (Automatic), which only affects
/// *which* duplicate is preferred — never whether a row is de-duplicated — so a
/// brief default is harmless.
class DefaultProviderController extends Notifier<String?> {
  bool _loadStarted = false;

  @override
  String? build() {
    if (!_loadStarted) {
      _loadStarted = true;
      _load();
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final String? stored =
          await ref.read(defaultProviderStoreProvider).read();
      if (stored != null && stored.isNotEmpty) state = stored;
    } catch (_) {
      // A storage hiccup must never break library loading; keep Automatic.
    }
  }

  /// Sets the explicit default provider to [sourceId], or clears it (`null`,
  /// Automatic), and persists the choice. A no-op when nothing changes.
  Future<void> setDefaultProvider(String? sourceId) async {
    final String? next =
        (sourceId != null && sourceId.isEmpty) ? null : sourceId;
    if (next == state) return;
    state = next;
    try {
      await ref.read(defaultProviderStoreProvider).write(next);
    } catch (_) {
      // Best-effort persistence: the in-memory choice still applies this session.
    }
  }
}

/// The user's explicit default provider (a source id), or `null` for Automatic.
/// The settings UI reads and writes this; [SourcePreferenceController] watches it
/// to fold the choice into the effective playback preference.
final defaultProviderControllerProvider =
    NotifierProvider<DefaultProviderController, String?>(
  DefaultProviderController.new,
);

/// Resolves the effective [SourcePriority] the library unifies with, by layering
/// the user's explicit default provider over the automatic, most-recently-
/// signed-in order.
///
/// Two inputs feed the result:
///
///  * **Automatic order** — the server the user most recently signed into is
///    promoted to the front ([markPreferred], called on a successful Jellyfin /
///    Subsonic sign-in) and persisted across restarts ([PreferredSourceStore]).
///    This is the behaviour Linthra has always had.
///  * **Explicit default** — when the user picks a default provider in Settings
///    ([DefaultProviderController]), that source is *pinned to the head* of the
///    preference. A later sign-in still updates the automatic order underneath
///    (so switching back to Automatic restores it), but it never displaces an
///    explicit pin.
///
/// Either way the result is a *total*, deterministic order, so the same catalog
/// always resolves to the same preferred source — and when the preferred source
/// does not have a given song, [unifyTracks] simply orders that song's real
/// candidates by the rest of the preference, falling back to the next available
/// copy.
class SourcePreferenceController extends Notifier<SourcePriority> {
  /// The automatic, most-recently-signed-in order. Maintained even while an
  /// explicit default is pinned, so switching back to Automatic restores it.
  List<String> _automaticOrder = const <String>[];

  /// The latest explicit default, cached from [build] so async callbacks
  /// (`_loadAutomaticOrder`, `markPreferred`) can fold it in without re-reading
  /// the watched provider — illegal while a dependency change is pending a
  /// rebuild. [build] re-runs (and refreshes this) whenever the choice changes.
  String? _explicit;

  /// Whether the one-shot load of [_automaticOrder] has been kicked off, so a
  /// rebuild (e.g. when the explicit default changes) doesn't re-read it.
  bool _loadStarted = false;

  /// Whether a sign-in has updated [_automaticOrder] in this session, so a
  /// late-arriving initial load can't clobber the fresher in-memory order.
  bool _automaticDirty = false;

  @override
  SourcePriority build() {
    _explicit = ref.watch(defaultProviderControllerProvider);
    if (!_loadStarted) {
      _loadStarted = true;
      _loadAutomaticOrder();
    }
    return _effectivePriority(_automaticOrder, _explicit);
  }

  Future<void> _loadAutomaticOrder() async {
    List<String> order;
    try {
      order = await ref.read(preferredSourceStoreProvider).read();
    } catch (_) {
      // A storage hiccup must never break library loading; keep the default.
      return;
    }
    // A sign-in may have updated the order while the read was in flight; the
    // fresher in-memory value wins.
    if (_automaticDirty) return;
    _automaticOrder = order;
    _recompute();
  }

  /// Recomputes the effective priority from the current automatic order and the
  /// last-known explicit default. Called when the automatic order changes; an
  /// explicit change rebuilds [build] on its own via the watched provider.
  void _recompute() {
    state = _effectivePriority(_automaticOrder, _explicit);
  }

  /// The effective preference: an [explicit] default pinned to the head followed
  /// by the [automatic] order (with the pin de-duplicated out of the tail); or
  /// just the [automatic] order when Automatic (`null`).
  static SourcePriority _effectivePriority(
    List<String> automatic,
    String? explicit,
  ) {
    if (explicit == null || explicit.isEmpty) {
      return automatic.isEmpty
          ? SourcePriority.fallback
          : SourcePriority(automatic);
    }
    return SourcePriority(<String>[
      explicit,
      for (final String id in automatic)
        if (id != explicit) id,
    ]);
  }

  /// Promotes [sourceId] to the front of the *automatic* order (the user just
  /// signed into it) and persists it. The effective priority still pins an
  /// explicit default ahead of it, so a sign-in never overrides the user's
  /// chosen default. A no-op for an already-front source.
  Future<void> markPreferred(String sourceId) async {
    final List<String> next = <String>[
      sourceId,
      for (final String id in _automaticOrder)
        if (id != sourceId) id,
    ];
    // Mark dirty even on a no-op so a late initial load can't clobber the order.
    _automaticDirty = true;
    if (listEquals(next, _automaticOrder)) return;
    _automaticOrder = next;
    _recompute();
    try {
      await ref.read(preferredSourceStoreProvider).write(_automaticOrder);
    } catch (_) {
      // Best-effort persistence: the in-memory order still applies this session.
    }
  }
}

/// The user's live source preference. The unified-library providers watch this
/// so a freshly-preferred server — or a freshly-chosen default — is reflected
/// without a manual refresh.
final librarySourcePriorityProvider =
    NotifierProvider<SourcePreferenceController, SourcePriority>(
  SourcePreferenceController.new,
);
