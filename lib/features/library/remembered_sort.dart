import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/library_song_sort_store.dart';

/// The order a Library list is in, remembered across launches.
///
/// Starts on [fallback] and moves to the stored order once the read lands. An
/// order the user picks before then wins over the stored one, the same rule
/// the remembered Library tab follows. A storage failure on either side only
/// costs the memory of the choice, never the choice itself.
abstract class RememberedSortController<T extends Enum> extends Notifier<T> {
  /// The order the list shows when nothing is stored.
  T get fallback;

  /// The order stored as [name], or null for an absent or unknown one.
  T? byName(String? name);

  /// Where this list's order is kept.
  LibrarySongSortStore get store;

  bool _loadStarted = false;

  /// Whether the user has picked an order in this session, so a late stored
  /// value can't take it back.
  bool _chosen = false;

  /// Writes run one after another, so a slow write can't land after a newer
  /// one and store an order the user already left.
  Future<void> _writes = Future<void>.value();

  @override
  T build() {
    if (!_loadStarted) {
      _loadStarted = true;
      unawaited(_load());
    }
    return fallback;
  }

  Future<void> _load() async {
    final String? stored;
    try {
      stored = await store.read();
    } catch (_) {
      // No remembered order: the list stays in its fallback order.
      return;
    }
    final T? sort = byName(stored);
    if (_chosen || sort == null) return;
    state = sort;
  }

  /// Sorts the list by [sort] and remembers it.
  ///
  /// Stored even when it is the order already on screen: until the stored
  /// order has loaded the list shows the fallback, and picking it then means
  /// it.
  void select(T sort) {
    _chosen = true;
    state = sort;
    final LibrarySongSortStore target = store;
    _writes = _writes.then((_) async {
      try {
        await target.write(sort.name);
      } catch (_) {
        // The order still applies for this session; the next launch simply
        // opens on the last one that was saved.
      }
    });
  }
}
