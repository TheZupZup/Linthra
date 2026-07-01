import '../../core/models/jellyfin_session.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/sources/jellyfin/jellyfin_client.dart';
import '../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';

/// The [RemoteFavoritesGateway] for Jellyfin: mirrors track hearts with the
/// signed-in server through a [JellyfinClient].
///
/// Owns the `jellyfin:` scheme, mapping each provider-namespaced uri to the bare
/// item id the server API speaks. The session (with its token) is read lazily so
/// signing in/out is picked up without rebuilding, and is never logged; every
/// failure becomes a friendly, secret-free [RemoteSyncException].
class JellyfinFavoritesGateway implements RemoteFavoritesGateway {
  const JellyfinFavoritesGateway({
    JellyfinClient? client,
    JellyfinSession? Function()? session,
  })  : _client = client,
        _session = session;

  final JellyfinClient? _client;
  final JellyfinSession? Function()? _session;

  @override
  String get uriScheme => JellyfinTrackMapper.uriScheme;

  @override
  bool get isConnected => _client != null && _session?.call() != null;

  @override
  Future<Set<String>> fetchFavoriteUris() async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) return const <String>{};
    try {
      final Set<String> ids = await client.fetchFavoriteIds(session);
      // The server speaks bare item ids; namespace them to the jellyfin: uri the
      // store and UI key on, so a server favourite matches its catalog track.
      return <String>{for (final String id in ids) '$uriScheme$id'};
    } on JellyfinException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) return;
    try {
      await client.setFavorite(session, _itemId(trackUri), favorite: favorite);
    } on JellyfinException catch (error) {
      throw RemoteSyncException(error.message);
    }
  }

  /// The bare Jellyfin item id behind a `jellyfin:` uri (the fallback keeps an
  /// unprefixed value intact rather than truncating it).
  String _itemId(String trackUri) => trackUri.startsWith(uriScheme)
      ? trackUri.substring(uriScheme.length)
      : trackUri;
}
