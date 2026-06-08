import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/source_priority.dart';
import '../../data/repositories/preferred_source_store_provider.dart';

/// Holds the user's preferred provider order as a [SourcePriority] and lets a
/// successful server sign-in promote that server to the front.
///
/// "Active/default first": the server the user most recently signed into becomes
/// the preferred copy when the same song exists on more than one provider. The
/// order is loaded from the [PreferredSourceStore] at startup and persisted on
/// every change, so the choice survives a restart. Until the async load lands
/// the controller serves an empty preference (the deterministic
/// [SourcePriority.fallback] default), which only affects *which* duplicate is
/// preferred — never whether a row is de-duplicated — so a brief default is
/// harmless.
class SourcePreferenceController extends Notifier<SourcePriority> {
  @override
  SourcePriority build() {
    _load();
    return SourcePriority.fallback;
  }

  Future<void> _load() async {
    try {
      final List<String> order =
          await ref.read(preferredSourceStoreProvider).read();
      if (order.isNotEmpty) {
        state = SourcePriority(order);
      }
    } catch (_) {
      // A storage hiccup must never break library loading; keep the default.
    }
  }

  /// Promotes [sourceId] to the front of the preference (the user is actively
  /// using it) and persists the new order. A no-op for an already-front source.
  Future<void> markPreferred(String sourceId) async {
    final SourcePriority next = state.promote(sourceId);
    if (next == state) return;
    state = next;
    try {
      await ref.read(preferredSourceStoreProvider).write(next.preferredOrder);
    } catch (_) {
      // Best-effort persistence: the in-memory order still applies this session.
    }
  }
}

/// The user's live source preference. The unified-library providers watch this
/// so a freshly-preferred server is reflected without a manual refresh.
final librarySourcePriorityProvider =
    NotifierProvider<SourcePreferenceController, SourcePriority>(
  SourcePreferenceController.new,
);
