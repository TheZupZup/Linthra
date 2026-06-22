import 'package:flutter/foundation.dart';

/// The persisted favourite sets, split by source so a remote refresh can replace
/// the server-owned set without disturbing favourites on local-only tracks.
///
/// Both sets hold the provider-namespaced [Track.uri] (`jellyfin:101`, a local
/// path), not the bare server-side id — so a favourite on `jellyfin:101` is
/// never confused with `subsonic:101`. The split is by *source*, not identity:
/// `localIds` are on-device tracks, `remoteIds` are the server-mirrored ones.
@immutable
class FavoritesData {
  const FavoritesData({
    this.localIds = const <String>{},
    this.remoteIds = const <String>{},
  });

  static const FavoritesData empty = FavoritesData();

  /// Favourite track uris that live only on this device (local-folder tracks).
  final Set<String> localIds;

  /// Favourite remote track uris (Jellyfin), mirrored from and pushed to the
  /// server. The server speaks bare item ids, so the repository maps each uri to
  /// its bare id at the request boundary.
  final Set<String> remoteIds;

  FavoritesData copyWith({Set<String>? localIds, Set<String>? remoteIds}) {
    return FavoritesData(
      localIds: localIds ?? this.localIds,
      remoteIds: remoteIds ?? this.remoteIds,
    );
  }
}

/// Durable storage for the user's favourites.
///
/// The persistence seam under [FavoritesRepository]: it knows nothing about
/// Jellyfin or sync — only which track ids are favourited, split into the
/// device-local set and the (server-mirrored) remote set. Splitting it out lets
/// the backing store swap freely (in-memory for tests, key/value in the app).
///
/// Security: only non-secret track/item ids are stored here — never a token.
abstract interface class FavoritesStore {
  Future<FavoritesData> load();
  Future<void> save(FavoritesData data);
}
