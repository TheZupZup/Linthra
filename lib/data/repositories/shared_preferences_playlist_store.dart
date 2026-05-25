import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/playlist.dart';
import '../../core/repositories/playlist_store.dart';

/// A [PlaylistStore] backed by `shared_preferences`.
///
/// Playlists are a small set of user-authored documents (a name, an ordered list
/// of stable track ids, and sync bookkeeping), so a JSON key/value document is
/// the right weight — the same reasoning favourites and the offline-download set
/// follow. A corrupt or unrecognised record reads as "no playlists" rather than
/// crashing the app.
///
/// Security: only non-secret metadata and track ids are written. The Jellyfin
/// [remoteId] is a non-secret server id; no token or authenticated URL is stored.
class SharedPreferencesPlaylistStore implements PlaylistStore {
  const SharedPreferencesPlaylistStore();

  static const String _key = 'playlists_v1';

  @override
  Future<List<Playlist>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <Playlist>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <Playlist>[];
    }
    if (decoded is! List) return const <Playlist>[];
    final List<Playlist> playlists = <Playlist>[];
    for (final Object? entry in decoded) {
      if (entry is Map<String, dynamic>) {
        final Playlist? playlist = _fromJson(entry);
        if (playlist != null) playlists.add(playlist);
      }
    }
    return playlists;
  }

  @override
  Future<void> save(List<Playlist> playlists) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(<Map<String, dynamic>>[
      for (final Playlist playlist in playlists) _toJson(playlist),
    ]);
    await prefs.setString(_key, raw);
  }

  static Map<String, dynamic> _toJson(Playlist playlist) {
    return <String, dynamic>{
      'id': playlist.id,
      'name': playlist.name,
      if (playlist.description != null) 'description': playlist.description,
      'source': playlist.source.providerId,
      if (playlist.remoteId != null) 'remoteId': playlist.remoteId,
      'trackIds': playlist.trackIds,
      if (playlist.createdAt != null)
        'createdAt': playlist.createdAt!.toIso8601String(),
      if (playlist.updatedAt != null)
        'updatedAt': playlist.updatedAt!.toIso8601String(),
      'syncState': playlist.syncState.name,
      if (playlist.lastSyncError != null)
        'lastSyncError': playlist.lastSyncError,
    };
  }

  static Playlist? _fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    return Playlist(
      id: id,
      name: name,
      description: json['description'] as String?,
      source: PlaylistSource.fromProviderId(json['source'] as String?),
      remoteId: json['remoteId'] as String?,
      trackIds: _ids(json['trackIds']),
      createdAt: _date(json['createdAt']),
      updatedAt: _date(json['updatedAt']),
      syncState: PlaylistSyncState.fromName(json['syncState'] as String?),
      lastSyncError: json['lastSyncError'] as String?,
    );
  }

  static List<String> _ids(Object? value) {
    if (value is! List) return const <String>[];
    return <String>[
      for (final Object? id in value)
        if (id is String && id.isNotEmpty) id,
    ];
  }

  static DateTime? _date(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}
