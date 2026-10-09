import '../../models/audiobookshelf_session.dart';
import 'audiobookshelf_api.dart';

/// The single seam through which Linthra talks HTTP to an Audiobookshelf
/// server.
///
/// Every request to Audiobookshelf goes through this interface, so the rest
/// of the app (authenticator, future library/playback code) depends only on
/// it — never on `http`, URLs, headers, or JSON. That keeps networking
/// swappable and, crucially, lets tests drive the feature with a fake client
/// and canned responses (no real server).
///
/// Implementations throw an [AudiobookshelfException] (with a friendly
/// message and an [AudiobookshelfErrorKind]) for every failure, and must
/// never put the password or either token into an exception, log, or any
/// other output.
abstract interface class AudiobookshelfClient {
  /// Confirms an address is a reachable Audiobookshelf server and returns its
  /// status. Backs "Test connection"; needs no credentials.
  Future<AudiobookshelfServerStatus> fetchServerStatus(String baseUrl);

  /// Exchanges a username + password for an access token (and, when the
  /// server grants one, a refresh token).
  Future<AudiobookshelfAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
  });

  /// Trades [refreshToken] for a new access token and a new refresh token.
  ///
  /// Throws [AudiobookshelfErrorKind.unauthorized] when the server turns the
  /// refresh token down (expired, already rotated, or the session was
  /// revoked); only a sign-in with the password gets a new one then.
  Future<AudiobookshelfAuthResult> refreshTokens({
    required String baseUrl,
    required String refreshToken,
  });

  /// Lists the signed-in user's accessible libraries.
  Future<List<AudiobookshelfLibraryDto>> fetchLibraries(
    AudiobookshelfSession session,
  );

  /// Fetches one page of the books in [libraryId], title-sorted, with [page]
  /// zero-based. A library can hold thousands of books, so this is paged
  /// rather than "everything at once".
  Future<AudiobookshelfLibraryItemsPage> fetchLibraryItems(
    AudiobookshelfSession session, {
    required String libraryId,
    required int limit,
    required int page,
  });
}
