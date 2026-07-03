import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/playlist_repository_provider.dart';

/// Coordinates a **smart, throttled** refresh of server-synced playlists and
/// favourites, so the user doesn't have to press "Sync" to see changes made on a
/// connected server (Navidrome/Subsonic, Jellyfin) from another client.
///
/// It is deliberately lightweight and battery-friendly: it only reconciles the
/// cheap account state (playlists + starred/favourite tracks), **never** a full
/// library re-scan, and it is throttled so the natural UI triggers that call it
/// — app resume, opening the Playlists screen, opening a provider's settings —
/// can fire freely without hammering the server. There is no background work and
/// no polling timer: a refresh only happens in response to something the user
/// did. Both underlying refreshes are non-throwing and offline-tolerant, so a
/// trigger is always safe and a failure leaves existing local data intact (and,
/// for favourites, retries any un-landed heart on the next refresh).
class RemoteLibraryRefresher {
  RemoteLibraryRefresher(this._ref, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Ref _ref;
  final DateTime Function() _now;

  /// The minimum gap between throttled refreshes. Short enough to feel live when
  /// moving between screens, long enough to avoid a burst of duplicate work.
  static const Duration cooldown = Duration(seconds: 20);

  DateTime? _lastRefresh;
  bool _inFlight = false;

  /// Reconciles server playlists + favourites best-effort. Coalesces concurrent
  /// callers and, unless [force] is set, skips a call that lands within
  /// [cooldown] of the previous one. Never throws.
  Future<void> refresh({bool force = false}) async {
    if (_inFlight) return;
    final DateTime current = _now();
    final DateTime? last = _lastRefresh;
    if (!force && last != null && current.difference(last) < cooldown) {
      return;
    }
    _inFlight = true;
    _lastRefresh = current;
    try {
      // Start both concurrently, then await; each is non-throwing and returns a
      // result we don't need here (the repositories update their own streams).
      final Future<void> favorites = _ref
          .read(favoritesRepositoryProvider)
          .refreshFromRemote()
          .then((_) {});
      final Future<void> playlists = _ref
          .read(playlistRepositoryProvider)
          .refreshFromRemote()
          .then((_) {});
      await favorites;
      await playlists;
    } catch (_) {
      // Never let a refresh trigger throw into the UI/lifecycle callback.
    } finally {
      _inFlight = false;
    }
  }
}

/// The app-wide smart refresher. Read it and call `refresh()` from natural
/// trigger points (app resume, opening Playlists, opening provider settings).
final remoteLibraryRefresherProvider = Provider<RemoteLibraryRefresher>((ref) {
  return RemoteLibraryRefresher(ref);
});
