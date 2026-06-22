import '../models/track.dart';
import 'remote_sync_result.dart';

/// Tracks the user's favourites and keeps them in sync with the source.
///
/// Favourites on **Jellyfin** tracks are synced to the server (the server is the
/// source of truth there, so they follow the user across clients); favourites on
/// **local-folder** tracks are kept on-device. The UI reads [favoritesStream] /
/// [isFavorite] and toggles through [setFavorite], never touching Jellyfin or
/// storage directly — mirroring how the player reads a [PlaybackState] and never
/// the audio engine.
abstract interface class FavoritesRepository {
  /// Emits the current favourite track-uri set immediately, then on every
  /// change. Entries are provider-namespaced [Track.uri]s, so a same-id track
  /// from another provider is never wrongly reported as a favourite.
  Stream<Set<String>> get favoritesStream;

  /// Whether [trackUri] is currently a favourite. A synchronous best-effort read
  /// of the in-memory mirror (empty until the first load); the stream is what
  /// the UI should bind to. Keyed by the provider-namespaced uri.
  bool isFavorite(String trackUri);

  /// Marks (or unmarks) [track] as a favourite. Updates immediately and, for a
  /// Jellyfin track while signed in, pushes the change to the server. Never
  /// throws: a failed server push keeps the local intent and reconciles on the
  /// next [refreshFromRemote].
  Future<void> setFavorite(Track track, bool favorite);

  /// Pulls the signed-in user's server favourites and adopts them as the remote
  /// set (server is the source of truth there), leaving local-track favourites
  /// untouched. Never throws: it returns a [FavoritesSyncResult] describing the
  /// outcome (not configured / synced + count / failed) so a caller — the
  /// "Sync library" action — can report "synced favorites" or "favorites could
  /// not be synced" instead of guessing.
  Future<FavoritesSyncResult> refreshFromRemote();

  /// Drops the server-sourced favourites (the signed-in account's), keeping
  /// on-device favourites. Called on sign-out so one account's hearts can't
  /// linger — or be re-pushed to a different account — after disconnecting.
  /// A no-op when there are none. Never throws.
  Future<void> clearRemote();
}
