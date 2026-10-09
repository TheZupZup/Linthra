import 'dart:async';

import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_client.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';

/// A configurable [AudiobookshelfClient] that returns canned responses (or
/// throws) and records what it was asked, so the authenticator can be tested
/// without a real server or HTTP.
class FakeAudiobookshelfClient implements AudiobookshelfClient {
  FakeAudiobookshelfClient({
    this.serverStatus,
    this.authResult,
    this.libraries = const <AudiobookshelfLibraryDto>[],
    this.serverStatusError,
    this.authError,
    this.librariesError,
    this.libraryItemsError,
  });

  AudiobookshelfServerStatus? serverStatus;
  AudiobookshelfAuthResult? authResult;
  List<AudiobookshelfLibraryDto> libraries;
  AudiobookshelfException? serverStatusError;
  AudiobookshelfException? authError;
  AudiobookshelfException? librariesError;
  AudiobookshelfException? libraryItemsError;

  /// Canned item pages by library id. A library with no entry here answers
  /// with an empty page, the same as a library with nothing in it.
  final Map<String, List<AudiobookshelfLibraryItemDto>> itemsByLibrary =
      <String, List<AudiobookshelfLibraryItemDto>>{};

  /// Exact pages by library id, for the cases the sliced list above can't
  /// express: a page the parser skipped every record on (items shorter than
  /// `rawCount`), or a server total that disagrees with what arrives. Takes
  /// precedence over [itemsByLibrary]; a page index past the end answers
  /// empty, as the server would.
  final Map<String, List<AudiobookshelfLibraryItemsPage>> pagesByLibrary =
      <String, List<AudiobookshelfLibraryItemsPage>>{};

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  String? lastPassword;
  AudiobookshelfSession? lastSession;

  /// How many times [fetchServerStatus] was called, so a test can prove the
  /// authenticator reuses a status the caller already fetched instead of
  /// asking again.
  int serverStatusCallCount = 0;

  /// Every [fetchLibraryItems] call, in order, so a test can assert what was
  /// asked for (which library, which page).
  final List<({String libraryId, int limit, int page})> itemRequests =
      <({String libraryId, int limit, int page})>[];

  /// While set, [fetchLibraries] and [fetchLibraryItems] wait for it before
  /// answering, so a test can keep a request in flight while something else
  /// happens and then let it land. The answer is worked out when the gate
  /// opens, the way a slow server would answer from its state at that point.
  Completer<void>? librariesGate;
  Completer<void>? itemsGate;

  @override
  Future<AudiobookshelfServerStatus> fetchServerStatus(
    String baseUrl,
  ) async {
    lastBaseUrl = baseUrl;
    serverStatusCallCount++;
    if (serverStatusError != null) throw serverStatusError!;
    final AudiobookshelfServerStatus? status = serverStatus;
    if (status == null) {
      throw AudiobookshelfException.notReachable();
    }
    return status;
  }

  @override
  Future<AudiobookshelfAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    lastBaseUrl = baseUrl;
    lastUsername = username;
    lastPassword = password;
    if (authError != null) throw authError!;
    final AudiobookshelfAuthResult? result = authResult;
    if (result == null) {
      throw AudiobookshelfException.unauthorized();
    }
    return result;
  }

  @override
  Future<List<AudiobookshelfLibraryDto>> fetchLibraries(
    AudiobookshelfSession session,
  ) async {
    lastSession = session;
    final Completer<void>? gate = librariesGate;
    if (gate != null) await gate.future;
    if (librariesError != null) throw librariesError!;
    return libraries;
  }

  @override
  Future<AudiobookshelfLibraryItemsPage> fetchLibraryItems(
    AudiobookshelfSession session, {
    required String libraryId,
    required int limit,
    required int page,
  }) async {
    lastSession = session;
    itemRequests.add((libraryId: libraryId, limit: limit, page: page));
    final Completer<void>? gate = itemsGate;
    if (gate != null) await gate.future;
    if (libraryItemsError != null) throw libraryItemsError!;
    final List<AudiobookshelfLibraryItemsPage>? canned =
        pagesByLibrary[libraryId];
    if (canned != null) {
      if (page >= canned.length) {
        return AudiobookshelfLibraryItemsPage(
          items: const <AudiobookshelfLibraryItemDto>[],
          rawCount: 0,
          total: canned.isEmpty ? 0 : canned.last.total,
          page: page,
        );
      }
      return canned[page];
    }
    final List<AudiobookshelfLibraryItemDto> all =
        itemsByLibrary[libraryId] ?? const <AudiobookshelfLibraryItemDto>[];
    // Page the canned list the way the server would, so a test can drive the
    // real "load more" path instead of a special case.
    final int start = page * limit;
    final List<AudiobookshelfLibraryItemDto> slice = start >= all.length
        ? const <AudiobookshelfLibraryItemDto>[]
        : all.sublist(start, (start + limit).clamp(0, all.length));
    return AudiobookshelfLibraryItemsPage(
      items: slice,
      rawCount: slice.length,
      total: all.length,
      page: page,
    );
  }
}
