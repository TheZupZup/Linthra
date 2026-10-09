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
    this.pendingWrites = const <String, bool>{},
    this.owners = const <String, String>{},
  });

  static const FavoritesData empty = FavoritesData();

  /// Favourite track uris that live only on this device (local-folder tracks).
  final Set<String> localIds;

  /// Favourite remote track uris (Jellyfin), mirrored from and pushed to the
  /// server. The server speaks bare item ids, so the repository maps each uri to
  /// its bare id at the request boundary.
  final Set<String> remoteIds;

  /// Remote hearts and un-hearts whose server push hasn't been confirmed yet
  /// (uri → the favourite state to push). Kept with the sets so a heart made
  /// offline still reaches its server after a restart, instead of the first
  /// refresh adopting a starred list that never heard of it.
  final Map<String, bool> pendingWrites;

  /// Whose each provider's [remoteIds] and [pendingWrites] are: uri scheme
  /// (`subsonic:`) → the account key its gateway reported
  /// (`RemoteFavoritesGateway.accountKey`). A remote id means something only
  /// on its own server, so these are never shown to, or pushed to, another
  /// account. A provider with no entry has no account behind its hearts:
  /// signed out, never signed in, or recorded before owners were kept.
  final Map<String, String> owners;

  FavoritesData copyWith({
    Set<String>? localIds,
    Set<String>? remoteIds,
    Map<String, bool>? pendingWrites,
    Map<String, String>? owners,
  }) {
    return FavoritesData(
      localIds: localIds ?? this.localIds,
      remoteIds: remoteIds ?? this.remoteIds,
      pendingWrites: pendingWrites ?? this.pendingWrites,
      owners: owners ?? this.owners,
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
