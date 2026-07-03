import '../../models/lyrics.dart';
import '../../models/subsonic_session.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';

/// The single seam through which Linthra talks HTTP to a Subsonic-compatible
/// server (such as Navidrome).
///
/// Every request goes through this interface, so the rest of the app
/// (authenticator, source, settings) depends only on it — never on `http`,
/// URLs, the auth query, or JSON. That keeps networking swappable and lets
/// tests drive the whole feature with a fake client and canned responses.
///
/// Implementations throw a [SubsonicException] (with a friendly message and a
/// [SubsonicErrorKind]) for every failure — including a Subsonic error returned
/// *inside a 200 response* — and must never put the password, salt, or token
/// into an exception, log, or any other output.
abstract interface class SubsonicClient {
  /// Confirms [baseUrl] is a reachable Subsonic server that accepts the given
  /// credentials, returning its public info. Backs "Test connection" and the
  /// credential check at sign-in.
  Future<SubsonicServerInfo> ping(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  });

  /// Confirms [session] is still accepted by the server (its credential is
  /// valid and the server reachable) without fetching anything large. Backs the
  /// pre-stream check the playback resolver runs.
  Future<void> verifySession(SubsonicSession session);

  /// The ID3 artist index for the signed-in user.
  Future<List<SubsonicArtistDto>> getArtists(SubsonicSession session);

  /// The full ID3 album list, paginated internally so the caller gets every
  /// album in one call.
  Future<List<SubsonicAlbumDto>> getAlbums(SubsonicSession session);

  /// The songs of one album.
  Future<List<SubsonicSongDto>> getAlbumSongs(
    SubsonicSession session,
    String albumId,
  );

  /// Fetches lyrics for the song [songId], or `null` when none are available.
  ///
  /// Tries the OpenSubsonic `getLyricsBySongId` extension first (synced or plain
  /// lyrics, as Navidrome exposes them), then falls back to the legacy
  /// `getLyrics` (plain text, matched by [artist] + [title]) for servers without
  /// the extension. Lyrics are best-effort: only a transport failure throws a
  /// [SubsonicException]; a server that has no lyrics, doesn't support the
  /// endpoint, or returns an unusable body yields `null` so the UI keeps its
  /// calm "no lyrics" state. The credential is woven into the request URL and is
  /// never logged or placed in a thrown error.
  Future<Lyrics?> fetchLyrics(
    SubsonicSession session,
    String songId, {
    String? artist,
    String? title,
  });

  /// Probes a minted stream [url] with a tiny ranged request to confirm the
  /// server returns playable audio *before* the URL is handed to the audio
  /// engine, returning the observed status and content type. The [url] carries
  /// the credential, so it must never be logged or placed in a thrown error;
  /// only a transport failure throws (a non-2xx status is returned for the
  /// caller to classify).
  Future<SubsonicStreamProbe> probeStream(Uri url);

  /// Registers playback of the song [songId] with the server's `scrobble`
  /// endpoint: `submission: false` marks it as "now playing" (so Navidrome's
  /// activity panel shows this client), `submission: true` records a completed
  /// play (play count / last played / configured scrobble forwarding).
  ///
  /// Throws a [SubsonicException] on failure — including a server that
  /// doesn't support scrobbling, which answers with a Subsonic error
  /// envelope; the *caller* (the playback reporter) treats every failure as
  /// best-effort and swallows it. The credential is woven into the request
  /// URL on demand and never logged or placed in a thrown error.
  Future<void> scrobble(
    SubsonicSession session,
    String songId, {
    required bool submission,
  });

  /// The song ids the signed-in user has starred (favourited), read from
  /// `getStarred2` (the ID3 starred list). Only songs are returned — Linthra
  /// mirrors track hearts, not album/artist stars.
  Future<Set<String>> getStarredSongIds(SubsonicSession session);

  /// Stars (favourites) the song [songId] for the signed-in user via `star`.
  Future<void> star(SubsonicSession session, String songId);

  /// Removes the star (favourite) from the song [songId] via `unstar`.
  Future<void> unstar(SubsonicSession session, String songId);

  /// The signed-in user's playlists — id + name only, without entries. Contents
  /// are fetched per-playlist with [getPlaylistSongIds].
  Future<List<SubsonicPlaylistDto>> getPlaylists(SubsonicSession session);

  /// The ordered song ids of the playlist [playlistId] (its `getPlaylist`
  /// `entry` list, in server order).
  Future<List<String>> getPlaylistSongIds(
    SubsonicSession session,
    String playlistId,
  );

  /// Creates a playlist named [name] seeded with [songIds] (in order), and
  /// returns the new server playlist id. Throws on failure.
  Future<String> createPlaylist(
    SubsonicSession session, {
    required String name,
    List<String> songIds = const <String>[],
  });

  /// Replaces the full ordered song list of the playlist [playlistId] with
  /// [songIds] (the Subsonic `createPlaylist`-with-`playlistId` replace form),
  /// so one call covers a Navidrome playlist's add, remove, and reorder. Throws
  /// on failure.
  Future<void> setPlaylistSongs(
    SubsonicSession session,
    String playlistId,
    List<String> songIds,
  );

  /// Renames the playlist [playlistId] to [name] via `updatePlaylist`. Throws
  /// on failure.
  Future<void> renamePlaylist(
    SubsonicSession session,
    String playlistId,
    String name,
  );

  /// Deletes the playlist [playlistId] from the server via `deletePlaylist`.
  /// Only ever called behind an explicit user confirmation. Throws on failure.
  Future<void> deletePlaylist(SubsonicSession session, String playlistId);
}
