import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/repositories/audiobookshelf_session_store.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_controller.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_state.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';

import '../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  userName: 'alice',
  defaultLibraryId: 'lib-books',
);

const _bookLibrary = AudiobookshelfLibraryDto(
  id: 'lib-books',
  name: 'Audiobooks',
  mediaType: 'book',
);

const _otherBookLibrary = AudiobookshelfLibraryDto(
  id: 'lib-kids',
  name: 'Kids',
  mediaType: 'book',
);

const _podcastLibrary = AudiobookshelfLibraryDto(
  id: 'lib-pods',
  name: 'Podcasts',
  mediaType: 'podcast',
);

AudiobookshelfLibraryItemDto _book(String id, String title) =>
    AudiobookshelfLibraryItemDto(
      id: id,
      title: title,
      authorName: 'An Author',
      duration: const Duration(hours: 9, minutes: 12),
    );

List<AudiobookshelfLibraryItemDto> _books(int count) =>
    <AudiobookshelfLibraryItemDto>[
      for (int i = 0; i < count; i++) _book('item-$i', 'Book $i'),
    ];

ProviderContainer _container({
  required FakeAudiobookshelfClient client,
  AudiobookshelfSessionStore? store,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      audiobookshelfClientProvider.overrideWithValue(client),
      audiobookshelfSessionStoreProvider.overrideWithValue(
        store ?? InMemoryAudiobookshelfSessionStore(initialSession: _session),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A container whose Audiobookshelf connection is signed out.
ProviderContainer _signedOutContainer(FakeAudiobookshelfClient client) =>
    _container(
      client: client,
      store: InMemoryAudiobookshelfSessionStore(),
    );

/// The ids on screen, for checking a list holds every book once and in order.
List<String> _ids(ProviderContainer container) => <String>[
      for (final AudiobookSummary book
          in container.read(audiobooksLibraryControllerProvider).books)
        book.id,
    ];

/// The ids of the first [count] books [_books] makes, in order.
List<String> _expectedIds(int count) =>
    <String>[for (int i = 0; i < count; i++) 'item-$i'];

void main() {
  group('load', () {
    test('offers the connection when no server is signed in', () async {
      final client = FakeAudiobookshelfClient();
      final container = _signedOutContainer(client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isFalse);
      expect(state.books, isEmpty);
      // Nothing was asked of the server without a session.
      expect(client.itemRequests, isEmpty);
    });

    test('lists the first page of the default library', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[
          _otherBookLibrary,
          _bookLibrary,
        ],
      );
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        _book('item-1', 'The Hobbit'),
      ];
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.hasLoaded, isTrue);
      expect(state.isLoading, isFalse);
      // The account's default library wins over "the first one listed".
      expect(state.selectedLibraryId, 'lib-books');
      expect(state.books.single.title, 'The Hobbit');
      expect(state.books.single.author, 'An Author');
      expect(
          state.books.single.duration, const Duration(hours: 9, minutes: 12));
      expect(state.hasMore, isFalse);
      expect(
        client.itemRequests.single,
        (
          libraryId: 'lib-books',
          limit: AudiobooksLibraryController.pageSize,
          page: 0,
        ),
      );
    });

    test('leaves podcast libraries out of the audiobook browser', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_podcastLibrary, _bookLibrary],
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(
        state.libraries.map((AudiobookLibrarySummary l) => l.id),
        <String>['lib-books'],
      );
    });

    test('keeps a library that reports no media type', () async {
      // An older or unusual server that doesn't send mediaType must not leave
      // the browser looking empty.
      final client = FakeAudiobookshelfClient(
        libraries: const <AudiobookshelfLibraryDto>[
          AudiobookshelfLibraryDto(id: 'lib-x', name: 'Books'),
        ],
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      expect(
        container.read(audiobooksLibraryControllerProvider).selectedLibraryId,
        'lib-x',
      );
    });

    test('says so when the account has no book library', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_podcastLibrary],
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.hasLoaded, isTrue);
      expect(state.libraries, isEmpty);
      expect(state.errorMessage, isNull);
      expect(client.itemRequests, isEmpty);
    });

    test('surfaces a failed listing without dropping the connection', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
        libraryItemsError: AudiobookshelfException.serverError(502),
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, contains('HTTP 502'));
      expect(state.errorKind, AudiobookshelfErrorKind.serverError);
    });

    test('a second load keeps what is there, a refresh re-fetches', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(2);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.load();
      expect(client.itemRequests, hasLength(1));

      await controller.refresh();
      expect(client.itemRequests, hasLength(2));
      expect(
        container.read(audiobooksLibraryControllerProvider).books,
        hasLength(2),
      );
    });

    test('a retry after a failure re-fetches without asking for a refresh',
        () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
        libraryItemsError: AudiobookshelfException.serverError(500),
      );
      client.itemsByLibrary['lib-books'] = _books(1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).errorMessage,
        isNotNull,
      );

      client.libraryItemsError = null;
      await controller.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.errorMessage, isNull);
      expect(state.books, hasLength(1));
    });
  });

  group('a different account', () {
    test('never shows the previous account its books or library names',
        () async {
      final client = FakeAudiobookshelfClient(
        serverStatus: const AudiobookshelfServerStatus(
          serverVersion: '2.17.0',
          isInitialized: true,
        ),
        authResult: const AudiobookshelfAuthResult(
          userId: 'user-2',
          accessToken: 'tok-2',
          userName: 'bob',
          defaultLibraryId: 'lib-bob',
        ),
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        _book('item-1', 'Alice only'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);
      final AudiobookshelfSettingsController connection =
          container.read(audiobookshelfSettingsControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).books.single.title,
        'Alice only',
      );

      // Sign out, then sign in as somebody else on the same device.
      await connection.clear();
      client.libraries = const <AudiobookshelfLibraryDto>[
        AudiobookshelfLibraryDto(
          id: 'lib-bob',
          name: "Bob's books",
          mediaType: 'book',
        ),
      ];
      client.itemsByLibrary['lib-bob'] = <AudiobookshelfLibraryItemDto>[
        _book('item-9', 'Bob only'),
      ];
      await connection.signIn(
        url: 'https://audiobooks.example.com',
        username: 'bob',
        password: 'hunter2',
      );

      // No force: the screen just being reopened must still re-fetch.
      await controller.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books.single.title, 'Bob only');
      expect(state.selectedLibraryId, 'lib-bob');
      expect(
        state.libraries.map((AudiobookLibrarySummary l) => l.name),
        <String>["Bob's books"],
      );
    });

    test('a sign-out empties the browser', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await container
          .read(audiobookshelfSettingsControllerProvider.notifier)
          .clear();
      await controller.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isFalse);
      expect(state.books, isEmpty);
      expect(state.libraries, isEmpty);
    });
  });

  group('selectLibrary', () {
    test('switches library and replaces the list', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(3);
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.selectLibrary('lib-kids');

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.selectedLibraryId, 'lib-kids');
      expect(state.books.single.title, 'Matilda');
      expect(state.totalBooks, 1);
    });

    test('picking the library already open asks the server for nothing',
        () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.selectLibrary('lib-books');

      expect(client.itemRequests, hasLength(1));
    });

    test('a refresh keeps the library the user picked', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.selectLibrary('lib-kids');
      await controller.refresh();

      expect(
        container.read(audiobooksLibraryControllerProvider).selectedLibraryId,
        'lib-kids',
      );
    });
  });

  group('loadMore', () {
    test('appends the next page and then stops offering one', () async {
      const int pageSize = AudiobooksLibraryController.pageSize;
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(pageSize + 5);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).books,
        hasLength(pageSize),
      );
      expect(
        container.read(audiobooksLibraryControllerProvider).hasMore,
        isTrue,
      );

      await controller.loadMore();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books, hasLength(pageSize + 5));
      expect(state.hasMore, isFalse);
      expect(state.isLoadingMore, isFalse);
      expect(client.itemRequests.last.page, 1);

      // Nothing left to ask for.
      await controller.loadMore();
      expect(client.itemRequests, hasLength(2));
    });

    test('a page nothing could be read from does not end the library',
        () async {
      // The middle page's records were all skipped by the parser. Ending the
      // paging there would strand every book after it.
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.pagesByLibrary['lib-books'] = <AudiobookshelfLibraryItemsPage>[
        AudiobookshelfLibraryItemsPage(
          items: <AudiobookshelfLibraryItemDto>[_book('item-1', 'First')],
          rawCount: 1,
          total: 3,
          page: 0,
        ),
        const AudiobookshelfLibraryItemsPage(
          items: <AudiobookshelfLibraryItemDto>[],
          rawCount: 1,
          total: 3,
          page: 1,
        ),
        AudiobookshelfLibraryItemsPage(
          items: <AudiobookshelfLibraryItemDto>[_book('item-3', 'Last')],
          rawCount: 1,
          total: 3,
          page: 2,
        ),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).hasMore,
        isTrue,
      );

      await controller.loadMore();
      // Nothing was added, but the library is not over.
      expect(
        container.read(audiobooksLibraryControllerProvider).books.single.title,
        'First',
      );
      expect(
        container.read(audiobooksLibraryControllerProvider).hasMore,
        isTrue,
      );

      await controller.loadMore();
      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(
        state.books.map((AudiobookSummary b) => b.title),
        <String>['First', 'Last'],
      );
      expect(state.hasMore, isFalse);
    });

    test('switching library mid-page leaves no spinner behind', () async {
      const int pageSize = AudiobooksLibraryController.pageSize;
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(pageSize + 5);
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();

      // The next page of the first library is still in flight when the user
      // picks another one.
      final Future<void> pending = controller.loadMore();
      final Future<void> switched = controller.selectLibrary('lib-kids');
      await Future.wait(<Future<void>>[pending, switched]);

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.selectedLibraryId, 'lib-kids');
      expect(state.books.single.title, 'Matilda');
      // The abandoned page must not leave the footer spinning, which would
      // also block every later page.
      expect(state.isLoadingMore, isFalse);
    });

    test('a failed page keeps the books already on screen', () async {
      const int pageSize = AudiobooksLibraryController.pageSize;
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(pageSize + 1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      client.libraryItemsError = AudiobookshelfException.notReachable();
      await controller.loadMore();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books, hasLength(pageSize));
      expect(state.isLoadingMore, isFalse);
      expect(state.errorMessage, isNotNull);
      // Still offered: the page can be retried.
      expect(state.hasMore, isTrue);
    });
  });

  group('a refresh that fails', () {
    // 250 books, two pages on screen: the shape from #792.
    const int pageSize = AudiobooksLibraryController.pageSize;
    const int bookCount = 2 * pageSize + 50;

    Future<(FakeAudiobookshelfClient, ProviderContainer)> twoPagesShown({
      List<AudiobookshelfLibraryDto>? libraries,
    }) async {
      final client = FakeAudiobookshelfClient(
        libraries: libraries ?? <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(bookCount);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);
      await controller.load();
      await controller.loadMore();
      expect(_ids(container), _expectedIds(2 * pageSize));
      return (client, container);
    }

    Future<void> loadToTheEnd(ProviderContainer container) async {
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);
      // Bounded, so a paging bug shows up as a failed expectation rather
      // than a test that never ends.
      for (int i = 0;
          i < 10 && container.read(audiobooksLibraryControllerProvider).hasMore;
          i++) {
        await controller.loadMore();
      }
    }

    test('when the library list does not come, Load more still continues',
        () async {
      final (FakeAudiobookshelfClient client, ProviderContainer container) =
          await twoPagesShown();
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      client.librariesError = AudiobookshelfException.notReachable();
      await controller.refresh();

      AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.errorKind, AudiobookshelfErrorKind.notReachable);
      expect(state.isLoading, isFalse);
      expect(_ids(container), _expectedIds(2 * pageSize));
      expect(state.hasMore, isTrue);

      // The server is back.
      client.librariesError = null;
      await loadToTheEnd(container);

      state = container.read(audiobooksLibraryControllerProvider);
      expect(_ids(container), _expectedIds(bookCount));
      expect(state.hasMore, isFalse);
      expect(state.errorMessage, isNull);
      // Page 2 was asked for once, straight after the two on screen.
      expect(
        client.itemRequests.map((r) => r.page),
        <int>[0, 1, 2],
      );
    });

    test('when the first page does not come, the old list and paging stay',
        () async {
      final (FakeAudiobookshelfClient client, ProviderContainer container) =
          await twoPagesShown();
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      // The library list answers, with a library that wasn't there before,
      // but the first page of books doesn't.
      client.libraries = <AudiobookshelfLibraryDto>[
        _bookLibrary,
        _otherBookLibrary,
      ];
      client.libraryItemsError = AudiobookshelfException.serverError(502);
      await controller.refresh();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.errorKind, AudiobookshelfErrorKind.serverError);
      expect(_ids(container), _expectedIds(2 * pageSize));
      expect(state.totalBooks, bookCount);
      expect(state.hasMore, isTrue);
      // The new library list is shown with the books it opens on, not
      // before them.
      expect(
        state.libraries.map((AudiobookLibrarySummary l) => l.id),
        <String>['lib-books'],
      );
      expect(state.selectedLibraryId, 'lib-books');

      client.libraryItemsError = null;
      await loadToTheEnd(container);

      expect(_ids(container), _expectedIds(bookCount));
      expect(
        container.read(audiobooksLibraryControllerProvider).hasMore,
        isFalse,
      );
    });

    test('several failures in a row never move the paging', () async {
      final (FakeAudiobookshelfClient client, ProviderContainer container) =
          await twoPagesShown();
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      client.librariesError = AudiobookshelfException.notReachable();
      await controller.refresh();
      await controller.refresh();
      client.librariesError = null;
      client.libraryItemsError = AudiobookshelfException.serverError(503);
      await controller.refresh();
      // Reopening the screen after an error runs the same reload.
      await controller.load();
      client.libraryItemsError = null;

      await loadToTheEnd(container);

      expect(_ids(container), _expectedIds(bookCount));
      expect(
        container.read(audiobooksLibraryControllerProvider).hasMore,
        isFalse,
      );
    });

    test('a refresh that works starts the paging over from its own page',
        () async {
      final (FakeAudiobookshelfClient client, ProviderContainer container) =
          await twoPagesShown();
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      client.librariesError = AudiobookshelfException.notReachable();
      await controller.refresh();
      client.librariesError = null;
      await controller.refresh();

      expect(_ids(container), _expectedIds(pageSize));
      await loadToTheEnd(container);
      expect(_ids(container), _expectedIds(bookCount));
    });

    test('a page that lands after a failed refresh started is dropped',
        () async {
      final (FakeAudiobookshelfClient client, ProviderContainer container) =
          await twoPagesShown();
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      // Page 2 is still on its way when the user pulls to refresh, and the
      // refresh fails before the page arrives.
      final Completer<void> held = Completer<void>();
      client.itemsGate = held;
      final Future<void> pending = controller.loadMore();
      client.librariesError = AudiobookshelfException.notReachable();
      await controller.refresh();
      client.itemsGate = null;
      held.complete();
      await pending;

      // The late page belonged to a list the refresh abandoned.
      AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(_ids(container), _expectedIds(2 * pageSize));
      expect(state.isLoadingMore, isFalse);
      expect(state.hasMore, isTrue);

      client.librariesError = null;
      await loadToTheEnd(container);
      state = container.read(audiobooksLibraryControllerProvider);
      expect(_ids(container), _expectedIds(bookCount));
      expect(state.hasMore, isFalse);
    });

    test('a refresh overtaken by another library never lands', () async {
      final (FakeAudiobookshelfClient client, ProviderContainer container) =
          await twoPagesShown(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      // The refresh's library list is held; the user picks another library
      // in the meantime.
      final Completer<void> held = Completer<void>();
      client.librariesGate = held;
      final Future<void> refreshing = controller.refresh();
      await controller.selectLibrary('lib-kids');
      client.librariesGate = null;
      held.complete();
      await refreshing;

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.selectedLibraryId, 'lib-kids');
      expect(_ids(container), <String>['kid-1']);
      expect(state.isLoading, isFalse);
      expect(state.hasMore, isFalse);
    });

    test('a refresh overtaken by a sign-out and another account never lands',
        () async {
      final client = FakeAudiobookshelfClient(
        serverStatus: const AudiobookshelfServerStatus(
          serverVersion: '2.17.0',
          isInitialized: true,
        ),
        authResult: const AudiobookshelfAuthResult(
          userId: 'user-2',
          accessToken: 'tok-2',
          userName: 'bob',
          defaultLibraryId: 'lib-bob',
        ),
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(bookCount);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);
      final AudiobookshelfSettingsController connection =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await controller.load();

      // Alice's refresh is held on its first page.
      final Completer<void> held = Completer<void>();
      client.itemsGate = held;
      final Future<void> refreshing = controller.refresh();
      await pumpEventQueue();
      expect(client.itemRequests, hasLength(2));

      await connection.clear();
      client.libraries = const <AudiobookshelfLibraryDto>[
        AudiobookshelfLibraryDto(
          id: 'lib-bob',
          name: "Bob's books",
          mediaType: 'book',
        ),
      ];
      client.itemsByLibrary['lib-bob'] = <AudiobookshelfLibraryItemDto>[
        _book('bob-1', 'Bob only'),
      ];
      await connection.signIn(
        url: 'https://audiobooks.example.com',
        username: 'bob',
        password: 'hunter2',
      );
      client.itemsGate = null;
      final Future<void> bobLoad = controller.load();
      held.complete();
      await Future.wait(<Future<void>>[refreshing, bobLoad]);

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(_ids(container), <String>['bob-1']);
      expect(state.selectedLibraryId, 'lib-bob');
      expect(state.hasMore, isFalse);
      expect(state.isLoading, isFalse);
    });
  });
}
