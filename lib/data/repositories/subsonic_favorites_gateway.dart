import '../../core/models/subsonic_session.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/sources/subsonic/subsonic_client.dart';
import '../../core/sources/subsonic/subsonic_exception.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';

/// The [RemoteFavoritesGateway] for Subsonic/Navidrome: mirrors track hearts
/// with the signed-in server via `star`/`unstar`/`getStarred2`.
///
/// Owns the `subsonic:` scheme, mapping each provider-namespaced uri to the bare
/// song id the Subsonic API stars by. The session (with its salt+token) is read
/// lazily so signing in/out is picked up without rebuilding, and is never
/// logged; every failure becomes a friendly, secret-free [RemoteSyncException].
class SubsonicFavoritesGateway implements RemoteFavoritesGateway {
  const SubsonicFavoritesGateway({
    required SubsonicClient client,
    required SubsonicSession? Function() session,
  })  : _client = client,
        _session = session;

  final SubsonicClient _client;
  final SubsonicSession? Function() _session;

  @override
  String get uriScheme => SubsonicTrackMapper.uriScheme;

  @override
  bool get isConnected => _session() != null;

  @override
  Future<Set<String>> fetchFavoriteUris() async {
    final SubsonicSession? session = _session();
    if (session == null) return const <String>{};
    try {
      final Set<String> ids = await _client.getStarredSongIds(session);
      // The server speaks bare song ids; namespace them to the subsonic: uri so
      // a starred song matches its catalog track.
      return <String>{for (final String id in ids) '$uriScheme$id'};
    } on SubsonicException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    final SubsonicSession? session = _session();
    if (session == null) return;
    final String songId = _songId(trackUri);
    try {
      if (favorite) {
        await _client.star(session, songId);
      } else {
        await _client.unstar(session, songId);
      }
    } on SubsonicException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  /// The bare Subsonic song id behind a `subsonic:` uri (the fallback keeps an
  /// unprefixed value intact rather than truncating it).
  String _songId(String trackUri) => trackUri.startsWith(uriScheme)
      ? trackUri.substring(uriScheme.length)
      : trackUri;
}
