import '../../core/models/playlist.dart';
import '../../core/models/subsonic_session.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/sources/subsonic/subsonic_api.dart';
import '../../core/sources/subsonic/subsonic_client.dart';
import '../../core/sources/subsonic/subsonic_exception.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';

/// The [RemotePlaylistGateway] for Subsonic/Navidrome.
///
/// Membership changes are pushed as a single **full ordered replace** (the
/// Subsonic `createPlaylist`-with-`playlistId` form), so add, remove, and
/// reorder are one idempotent call — which is why this gateway also pushes
/// rename ([updatePlaylist]) and reorder. A Subsonic playlist can only hold
/// Subsonic songs, so non-`subsonic:` uris are dropped at the request boundary.
/// The session (with its salt+token) is read lazily and never logged; failures
/// surface as a friendly, secret-free [RemoteSyncException].
class SubsonicPlaylistGateway implements RemotePlaylistGateway {
  const SubsonicPlaylistGateway({
    required SubsonicClient client,
    required SubsonicSession? Function() session,
  })  : _client = client,
        _session = session;

  final SubsonicClient _client;
  final SubsonicSession? Function() _session;

  @override
  PlaylistSource get source => PlaylistSource.subsonic;

  @override
  bool get isConnected => _session() != null;

  // Subsonic's replace form pushes the full ordered list, so rename and reorder
  // both reach the server.
  @override
  bool get pushesRename => true;

  @override
  bool get pushesReorder => true;

  @override
  Future<List<RemotePlaylistData>> fetchPlaylists() async {
    final SubsonicSession? session = _session();
    if (session == null) return const <RemotePlaylistData>[];
    final List<SubsonicPlaylistDto> headers;
    try {
      headers = await _client.getPlaylists(session);
    } on SubsonicException catch (error) {
      throw RemoteSyncException(error.message);
    }
    final List<RemotePlaylistData> result = <RemotePlaylistData>[];
    for (final SubsonicPlaylistDto header in headers) {
      final List<String> songIds;
      try {
        songIds = await _client.getPlaylistSongIds(session, header.id);
      } on SubsonicException catch (_) {
        // Skip this playlist's membership; keep importing the rest.
        continue;
      }
      result.add(RemotePlaylistData(
        remoteId: header.id,
        name: header.name,
        trackUris: <String>[for (final String id in songIds) _uri(id)],
      ));
    }
    return result;
  }

  @override
  Future<String> createRemotePlaylist(
    String name,
    List<String> trackUris,
  ) async {
    final SubsonicSession? session = _session();
    if (session == null) {
      throw const RemoteSyncException('Not signed in to Subsonic/Navidrome.');
    }
    try {
      return await _client.createPlaylist(
        session,
        name: name,
        songIds: _songIds(trackUris),
      );
    } on SubsonicException catch (error) {
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
    final SubsonicSession? session = _session();
    if (session == null) {
      throw const RemoteSyncException('Not signed in to Subsonic/Navidrome.');
    }
    try {
      // A single ordered replace covers add, remove, and reorder in one call.
      await _client.setPlaylistSongs(
        session,
        remoteId,
        _songIds(orderedTrackUris),
      );
    } on SubsonicException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  @override
  Future<void> renameRemote(String remoteId, String name) async {
    final SubsonicSession? session = _session();
    if (session == null) {
      throw const RemoteSyncException('Not signed in to Subsonic/Navidrome.');
    }
    try {
      await _client.renamePlaylist(session, remoteId, name);
    } on SubsonicException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  @override
  Future<void> deleteRemote(String remoteId) async {
    final SubsonicSession? session = _session();
    if (session == null) {
      throw const RemoteSyncException('Not signed in to Subsonic/Navidrome.');
    }
    try {
      await _client.deletePlaylist(session, remoteId);
    } on SubsonicException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  static String _uri(String songId) =>
      '${SubsonicTrackMapper.uriScheme}$songId';

  /// The bare Subsonic song ids for the `subsonic:` uris in [uris], in order.
  /// Non-Subsonic uris are dropped: a Subsonic server playlist can only hold
  /// Subsonic songs.
  static List<String> _songIds(List<String> uris) => <String>[
        for (final String uri in uris)
          if (uri.startsWith(SubsonicTrackMapper.uriScheme))
            uri.substring(SubsonicTrackMapper.uriScheme.length),
      ];
}
