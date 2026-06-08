import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/source_strategy.dart';
import '../../data/repositories/playback_source_strategy_store_provider.dart';

/// Holds the user's chosen [PlaybackSourceStrategy] and persists changes.
///
/// Defaults to [PlaybackSourceStrategy.preferDefault] — the PR1/PR2 behaviour —
/// so until the user picks a smart strategy nothing about source selection
/// changes. The choice is loaded from the store at startup and written on every
/// change, so it survives a restart. Until the async load lands the controller
/// serves the default, which only affects *ordering* of duplicate candidates —
/// never de-duplication, runtime fallback, or which copy actually plays when one
/// fails — so a brief default is harmless.
class PlaybackSourceStrategyController
    extends Notifier<PlaybackSourceStrategy> {
  bool _loadStarted = false;

  /// Whether the user has chosen a strategy this session. If a choice lands
  /// before the async startup load finishes, the load must not clobber it.
  bool _userChose = false;

  @override
  PlaybackSourceStrategy build() {
    if (!_loadStarted) {
      _loadStarted = true;
      _load();
    }
    return PlaybackSourceStrategy.preferDefault;
  }

  Future<void> _load() async {
    try {
      final String? stored =
          await ref.read(playbackSourceStrategyStoreProvider).read();
      // Nothing persisted, or the user already chose while the read was in
      // flight: keep the current value rather than resetting to the default.
      if (stored == null || _userChose) return;
      final PlaybackSourceStrategy parsed =
          PlaybackSourceStrategy.fromStorage(stored);
      if (parsed != state) state = parsed;
    } catch (_) {
      // A storage hiccup must never break playback; keep the default.
    }
  }

  /// Sets the strategy and persists it. A no-op when nothing changes.
  Future<void> setStrategy(PlaybackSourceStrategy strategy) async {
    _userChose = true;
    if (strategy == state) return;
    state = strategy;
    try {
      await ref.read(playbackSourceStrategyStoreProvider).write(strategy.name);
    } catch (_) {
      // Best-effort persistence: the in-memory choice still applies this session.
    }
  }
}

/// The user's live playback source strategy. The unified-library candidate
/// provider watches this so a freshly-chosen strategy reorders candidates
/// without a manual refresh.
final playbackSourceStrategyProvider =
    NotifierProvider<PlaybackSourceStrategyController, PlaybackSourceStrategy>(
  PlaybackSourceStrategyController.new,
);
