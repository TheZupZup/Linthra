import '../../core/models/jellyfin_session.dart';
import '../../core/models/playlist.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/sources/jellyfin/jellyfin_api.dart';
import '../../core/sources/jellyfin/jellyfin_client.dart';
import '../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';

/// The [RemotePlaylistGateway] for Jellyfin.
///
/// Preserves Jellyfin's established sync shape: membership changes are pushed
/// **incrementally** (add/remove of bare item ids), while rename and reorder
/// stay local-only (a refresh re-adopts the server name/order) — see
/// docs/playlists-and-delete.md. A Jellyfin playlist can only hold Jellyfin
/// items, so non-`jellyfin:` uris are dropped at the request boundary. The
/// session (with its token) is read lazily and never logged; failures surface as
/// a friendly, secret-free [RemoteSyncException].
class JellyfinPlaylistGateway implements RemotePlaylistGateway {
  const JellyfinPlaylistGateway({
    JellyfinClient? client,
    JellyfinSession? Function()? session,
  })  : _client = client,
        _session = session;

  final JellyfinClient? _client;
  final JellyfinSession? Function()? _session;

  @override
  PlaylistSource get source => PlaylistSource.jellyfin;

  @override
  bool get isConnected => _client != null && _session?.call() != null;

  // Rename/reorder of a synced Jellyfin playlist are local-only for now.
  @override
  bool get pushesRename => false;

  @override
  bool get pushesReorder => false;

  @override
  Future<List<RemotePlaylistData>> fetchPlaylists() async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) return const <RemotePlaylistData>[];
    final List<JellyfinPlaylistDto> remote;
    try {
      remote = await client.fetchPlaylists(session);
    } on JellyfinException catch (error) {
      throw RemoteSyncException(error.message);
    }
    final List<RemotePlaylistData> result = <RemotePlaylistData>[];
    for (final JellyfinPlaylistDto dto in remote) {
      final List<JellyfinPlaylistEntry> entries;
      try {
        entries = await client.fetchPlaylistEntries(session, dto.id);
      } on JellyfinException catch (_) {
        // Skip this playlist's membership; keep importing the rest (matches the
        // prior repository behaviour of not failing the whole sync on one bad
        // playlist).
        continue;
      }
      result.add(RemotePlaylistData(
        remoteId: dto.id,
        name: dto.name,
        trackUris: <String>[
          for (final JellyfinPlaylistEntry e in entries) _uri(e.itemId),
        ],
      ));
    }
    return result;
  }

  @override
  Future<String> createRemotePlaylist(
    String name,
    List<String> trackUris,
  ) async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) {
      throw const RemoteSyncException('Not signed in to Jellyfin.');
    }
    try {
      return await client.createPlaylist(
        session,
        name: name,
        itemIds: _itemIds(trackUris),
      );
    } on JellyfinException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) {
      throw const RemoteSyncException('Not signed in to Jellyfin.');
    }
    try {
      if (added.isNotEmpty) {
        await client.addItemsToPlaylist(session, remoteId, _itemIds(added));
      }
      if (removed.isNotEmpty) {
        await client.removeItemsFromPlaylist(
            session, remoteId, _itemIds(removed));
      }
    } on JellyfinException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  // Never called (pushesRename is false); a no-op keeps the contract total.
  @override
  Future<void> renameRemote(String remoteId, String name) async {}

  @override
  Future<void> deleteRemote(String remoteId) async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) {
      throw const RemoteSyncException('Not signed in to Jellyfin.');
    }
    try {
      await client.deletePlaylist(session, remoteId);
    } on JellyfinException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  static String _uri(String itemId) =>
      '${JellyfinTrackMapper.uriScheme}$itemId';

  /// The bare Jellyfin item ids for the `jellyfin:` uris in [uris], in order.
  /// Non-Jellyfin uris are dropped: a Jellyfin server playlist can only hold
  /// Jellyfin items.
  static List<String> _itemIds(List<String> uris) => <String>[
        for (final String uri in uris)
          if (uri.startsWith(JellyfinTrackMapper.uriScheme))
            uri.substring(JellyfinTrackMapper.uriScheme.length),
      ];
}
