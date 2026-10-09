import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/audiobookshelf_session.dart';
import '../../core/sources/audiobookshelf/audiobookshelf_api.dart';
import '../../core/sources/audiobookshelf/audiobookshelf_exception.dart';
import '../settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import '../settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'audiobooks_library_state.dart';

/// Drives the audiobook browser: picks a library and pages through its books.
///
/// It reads the live session from the connection controller (the one place a
/// signed-in Audiobookshelf session lives) and never touches storage, HTTP
/// headers or the tokens itself. Nothing here goes near the music providers,
/// the music catalog or the source preference: this is the audiobook seam,
/// same as the connection screen.
///
/// Listing only. Opening a book, chapters and playback come with the domain
/// model in the next milestone.
class AudiobooksLibraryController extends Notifier<AudiobooksLibraryState> {
  /// How many books one request asks for. Big enough that most libraries
  /// arrive in a single page, small enough that a large one doesn't spend
  /// seconds parsing before the first row appears.
  static const int pageSize = 100;

  /// The page index the next [loadMore] asks for. Counted rather than
  /// derived from the number of loaded books: a page can come back one book
  /// short because a half-scanned record was skipped, and dividing by
  /// [pageSize] would then ask for the same page again.
  int _nextPage = 1;

  /// How many entries the server has sent for the current library, skipped
  /// records included. Paging is measured against this rather than against
  /// the books on screen, so a page nothing could be read from still moves
  /// the list forward instead of ending it.
  int _rawRead = 0;

  /// Bumped whenever what the screen is showing changes underneath a request:
  /// a different account, a refresh, another library. A response carrying an
  /// older generation is dropped, so no in-flight page can land on a list it
  /// doesn't belong to (or leave a spinner running on one).
  int _generation = 0;

  /// The sign-in the loaded state belongs to. Any other one owns the screen
  /// now, even for the same account, and none of the books or library names
  /// on it may be shown to it. Renewed tokens are still the same sign-in.
  int? _loadedFor;

  @override
  AudiobooksLibraryState build() => const AudiobooksLibraryState();

  /// Loads the libraries and the first page of the selected one.
  ///
  /// Called when the screen opens. Already-loaded state is kept unless
  /// [force] is set (pull to refresh / the refresh action), so returning to
  /// the screen doesn't re-fetch the whole library. Any new sign-in always
  /// re-fetches, even to the same account: the cache belongs to the sign-in
  /// that filled it.
  Future<void> load({bool force = false}) async {
    final AudiobookshelfSettingsController connection =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    // A cold open is still reading the keyring: without this the check below
    // would see "not connected" and offer the connection to a signed-in user.
    await connection.ensureLoaded();
    final AudiobookshelfSession? session = connection.session;
    if (session == null) {
      _forget();
      state = const AudiobooksLibraryState();
      return;
    }
    final bool sameSignIn = connection.currentSignIn == _loadedFor;
    if (sameSignIn && state.hasLoaded && !force && state.errorMessage == null) {
      return;
    }

    final int generation = _begin(connection);
    if (sameSignIn) {
      // A refresh keeps what is on screen, and the paging position that
      // describes it, until the new first page is in: a refresh that fails
      // must leave Load more asking for the page after the last one shown.
      state = state.copyWith(
        isConnected: true,
        isLoading: true,
        isLoadingMore: false,
      );
    } else {
      // A different sign-in: nothing of the previous one survives into this
      // load, not its books, not its library names, not which library was
      // open, not how far through it the list had got.
      _resetPaging();
      state = const AudiobooksLibraryState(isConnected: true, isLoading: true);
    }

    final List<AudiobookshelfLibraryDto> libraries;
    try {
      libraries = await connection.authorized(
        session,
        ref.read(audiobookshelfClientProvider).fetchLibraries,
      );
    } on AudiobookshelfException catch (error) {
      _fail(generation, connection, error);
      return;
    }
    if (_isStale(generation, connection)) return;

    final List<AudiobookLibrarySummary> bookLibraries =
        <AudiobookLibrarySummary>[
      for (final AudiobookshelfLibraryDto library in libraries)
        // A library that reports no media type at all is treated as books
        // rather than hidden: the browser would otherwise show nothing on a
        // server whose response is a shape older than the one documented.
        if (library.mediaType == null || library.mediaType == 'book')
          AudiobookLibrarySummary(id: library.id, name: library.name),
    ];
    if (bookLibraries.isEmpty) {
      _resetPaging();
      state = const AudiobooksLibraryState(
        isConnected: true,
        hasLoaded: true,
      );
      return;
    }

    // The new library list is only shown with the first page it opens on, so
    // a first page that fails leaves the previous list, books and paging
    // position on screen together.
    await _loadFirstPage(
      generation,
      session,
      connection,
      libraries: bookLibraries,
      libraryId: _pickLibrary(bookLibraries, session),
    );
  }

  /// Switches to another library and loads its first page. A no-op for the
  /// library already showing.
  Future<void> selectLibrary(String libraryId) async {
    if (libraryId == state.selectedLibraryId) return;
    final AudiobookshelfSettingsController connection =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    final AudiobookshelfSession? session = connection.session;
    if (session == null) {
      _forget();
      state = const AudiobooksLibraryState();
      return;
    }
    final int generation = _begin(connection);
    // The previous library's books leave the screen now, and so does the
    // paging position that described them.
    _resetPaging();
    state = state.copyWith(
      selectedLibraryId: libraryId,
      hasMore: false,
      books: const <AudiobookSummary>[],
      totalBooks: 0,
      isLoading: true,
      // A page still in flight for the previous library is abandoned by the
      // new generation, so its spinner must not be left running here.
      isLoadingMore: false,
    );
    await _loadFirstPage(
      generation,
      session,
      connection,
      libraries: state.libraries,
      libraryId: libraryId,
    );
  }

  /// Appends the next page. A no-op when everything is already loaded or a
  /// request is already running, so a keen scroller can't fire two.
  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoading || state.isLoadingMore) return;
    final String? libraryId = state.selectedLibraryId;
    if (libraryId == null) return;
    final AudiobookshelfSettingsController connection =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    final AudiobookshelfSession? session = connection.session;
    if (session == null) {
      _forget();
      state = const AudiobooksLibraryState();
      return;
    }

    // A continuation of what is already on screen, so it joins the current
    // generation rather than starting one.
    final int generation = _generation;
    final int nextPage = _nextPage;
    state = state.copyWith(isLoadingMore: true);
    try {
      final AudiobookshelfLibraryItemsPage page = await connection.authorized(
        session,
        (AudiobookshelfSession current) =>
            ref.read(audiobookshelfClientProvider).fetchLibraryItems(
                  current,
                  libraryId: libraryId,
                  limit: pageSize,
                  page: nextPage,
                ),
      );
      if (_isStale(generation, connection)) return;
      _nextPage = nextPage + 1;
      _rawRead += page.rawCount;
      state = state.copyWith(
        books: <AudiobookSummary>[...state.books, ..._toSummaries(page.items)],
        totalBooks: page.total,
        hasMore: _hasMore(page),
        isLoadingMore: false,
      );
    } on AudiobookshelfException catch (error) {
      if (_isStale(generation, connection)) return;
      // The books already on screen stay there; only the footer reports that
      // the next page didn't come.
      state = state.copyWith(
        isLoadingMore: false,
        errorMessage: error.message,
        errorKind: error.kind,
      );
    }
  }

  /// Re-fetches the libraries and the current library's first page.
  Future<void> refresh() => load(force: true);

  /// Loads page 0 of [libraryId] and, only once it is in, shows it together
  /// with [libraries], the selection and the paging position it starts.
  /// Nothing is committed on failure: the screen keeps whatever it had.
  Future<void> _loadFirstPage(
    int generation,
    AudiobookshelfSession session,
    AudiobookshelfSettingsController connection, {
    required List<AudiobookLibrarySummary> libraries,
    required String libraryId,
  }) async {
    try {
      final AudiobookshelfLibraryItemsPage page = await connection.authorized(
        session,
        (AudiobookshelfSession current) =>
            ref.read(audiobookshelfClientProvider).fetchLibraryItems(
                  current,
                  libraryId: libraryId,
                  limit: pageSize,
                  page: 0,
                ),
      );
      if (_isStale(generation, connection)) return;
      _nextPage = 1;
      _rawRead = page.rawCount;
      state = state.copyWith(
        libraries: libraries,
        selectedLibraryId: libraryId,
        books: _toSummaries(page.items),
        totalBooks: page.total,
        hasMore: _hasMore(page),
        isLoading: false,
        hasLoaded: true,
      );
    } on AudiobookshelfException catch (error) {
      _fail(generation, connection, error);
    }
  }

  /// The library to open: the one already chosen if it still exists, then the
  /// account's default, then the first. A user who picked a library keeps it
  /// across a refresh.
  String _pickLibrary(
    List<AudiobookLibrarySummary> libraries,
    AudiobookshelfSession session,
  ) {
    final String? current = state.selectedLibraryId;
    for (final AudiobookLibrarySummary library in libraries) {
      if (library.id == current) return library.id;
    }
    for (final AudiobookLibrarySummary library in libraries) {
      if (library.id == session.defaultLibraryId) return library.id;
    }
    return libraries.first.id;
  }

  /// Whether the server has pages left for the library being read.
  ///
  /// A page that sent nothing is the end, whatever the total says. Otherwise
  /// it is what the server has sent so far against what it says is there: a
  /// page whose records were all skipped still counts as read, so the books
  /// after it stay reachable.
  bool _hasMore(AudiobookshelfLibraryItemsPage page) =>
      page.rawCount > 0 && _rawRead < page.total;

  /// Starts a new generation of requests for the current sign-in: whatever
  /// was in flight for the previous one no longer owns the screen.
  ///
  /// The paging position is left alone. It describes the books on screen, so
  /// it only changes in the same step that replaces them; a request that is
  /// merely starting must not move it.
  int _begin(AudiobookshelfSettingsController connection) {
    _loadedFor = connection.currentSignIn;
    return ++_generation;
  }

  /// Drops everything tied to a session that is gone.
  void _forget() {
    _loadedFor = null;
    _resetPaging();
    _generation++;
  }

  /// The paging position of an empty list. Only called together with a
  /// state change that empties the books.
  void _resetPaging() {
    _nextPage = 1;
    _rawRead = 0;
  }

  void _fail(
    int generation,
    AudiobookshelfSettingsController connection,
    AudiobookshelfException error,
  ) {
    if (_isStale(generation, connection)) return;
    state = state.copyWith(
      isLoading: false,
      isLoadingMore: false,
      hasLoaded: true,
      errorMessage: error.message,
      errorKind: error.kind,
    );
  }

  /// Whether a response still belongs on screen: a newer generation (a
  /// refresh, another library, another account) or a sign-out or new sign-in
  /// that landed while it was in flight means it doesn't, so it is dropped
  /// rather than painted over whatever owns the screen now. Tokens renewed
  /// while it was out don't make it stale.
  bool _isStale(
    int generation,
    AudiobookshelfSettingsController connection,
  ) =>
      generation != _generation || connection.currentSignIn != _loadedFor;

  List<AudiobookSummary> _toSummaries(
    List<AudiobookshelfLibraryItemDto> items,
  ) {
    return <AudiobookSummary>[
      for (final AudiobookshelfLibraryItemDto item in items)
        AudiobookSummary(
          id: item.id,
          title: item.title,
          subtitle: item.subtitle,
          author: item.authorName,
          narrator: item.narratorName,
          series: item.seriesName,
          duration: item.duration,
        ),
    ];
  }
}

final audiobooksLibraryControllerProvider =
    NotifierProvider<AudiobooksLibraryController, AudiobooksLibraryState>(
  AudiobooksLibraryController.new,
);
