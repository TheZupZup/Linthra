import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/favorites_store.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/music_provider.dart';

/// A [FavoritesStore] backed by `shared_preferences`.
///
/// Favourites are a small set of non-secret track identities, so a key/value
/// document is the right weight (the same reasoning the offline-download set
/// follows). Stored as `{ "local": [...], "remote": [...] }` so the
/// device-local favourites and the server-mirrored ones survive a restart and
/// can be reconciled independently.
///
/// Identity is the provider-namespaced [Track.uri] (`jellyfin:101`, a local
/// path), matching the catalog re-key — so favouriting `jellyfin:101` can never
/// be confused with `subsonic:101`. The local set already held uris (a local
/// track's id *is* its path); the remote set held bare Jellyfin item ids.
///
/// Versioning:
///  * **v1** (`favorites_v1`) — bare ids: local paths in `local`, bare Jellyfin
///    item ids in `remote`.
///  * **v2** (`favorites_v2`) — provider-namespaced uris in both sets.
///
/// A v1 store is migrated to uris on first load (the v1 key is left untouched so
/// the data is recoverable). The remote set could only ever hold Jellyfin items
/// — Subsonic/Plex don't support favouriting — so prefixing each bare id with
/// the `jellyfin:` scheme is unambiguous and never mis-attributes a favourite.
class SharedPreferencesFavoritesStore implements FavoritesStore {
  const SharedPreferencesFavoritesStore();

  static const String _key = 'favorites_v2';
  static const String _legacyKey = 'favorites_v1';

  @override
  Future<FavoritesData> load() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      return _decode(raw) ?? FavoritesData.empty;
    }
    // No v2 yet: migrate a pre-uri v1 store if present. Local ids were already
    // the track's uri (a local path); remote ids were bare Jellyfin item ids,
    // so namespacing them yields the provider uri the rest of the app keys on.
    final String? legacy = prefs.getString(_legacyKey);
    if (legacy == null || legacy.isEmpty) return FavoritesData.empty;
    final FavoritesData? old = _decode(legacy);
    if (old == null) return FavoritesData.empty;
    return FavoritesData(
      localIds: old.localIds,
      remoteIds: <String>{
        for (final String id in old.remoteIds) _remoteUriForLegacyId(id),
      },
    );
  }

  @override
  Future<void> save(FavoritesData data) async {
    final prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(<String, dynamic>{
      'local': data.localIds.toList(),
      'remote': data.remoteIds.toList(),
    });
    await prefs.setString(_key, raw);
  }

  /// The provider-namespaced uri for a legacy v1 remote id. A bare Jellyfin item
  /// id (the v1 form) gets the `jellyfin:` scheme; an id that already carries a
  /// known scheme (a partially-migrated or hand-edited store) is left as-is.
  static String _remoteUriForLegacyId(String id) =>
      MusicProviders.bareRemoteIdForTrackUri(id) != null
          ? id
          : '${JellyfinTrackMapper.uriScheme}$id';

  static FavoritesData? _decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A corrupt record reads as "no favourites" rather than crashing.
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    return FavoritesData(
      localIds: _ids(decoded['local']),
      remoteIds: _ids(decoded['remote']),
    );
  }

  static Set<String> _ids(Object? value) {
    if (value is! List) return <String>{};
    return <String>{
      for (final Object? id in value)
        if (id is String && id.isNotEmpty) id,
    };
  }
}
