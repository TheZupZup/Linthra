import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_controller.dart';
import 'package:linthra/features/audiobooks/audiobooks_screen.dart';
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

AudiobookshelfLibraryItemDto _book(
  String id,
  String title, {
  String? author,
  String? narrator,
  String? series,
  Duration? duration,
}) {
  return AudiobookshelfLibraryItemDto(
    id: id,
    title: title,
    authorName: author,
    narratorName: narrator,
    seriesName: series,
    duration: duration,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeAudiobookshelfClient client,
  AudiobookshelfSession? savedSession = _session,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        audiobookshelfClientProvider.overrideWithValue(client),
        audiobookshelfSessionStoreProvider.overrideWithValue(
          InMemoryAudiobookshelfSessionStore(initialSession: savedSession),
        ),
      ],
      child: const MaterialApp(home: AudiobooksScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the books on the connected server', (tester) async {
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
    );
    client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
      _book(
        'item-1',
        'The Hobbit',
        author: 'J. R. R. Tolkien',
        narrator: 'Rob Inglis',
        series: 'Middle-earth',
        duration: const Duration(hours: 11, minutes: 5),
      ),
    ];

    await _pump(tester, client: client);

    expect(find.text('Audiobooks'), findsWidgets);
    expect(find.text('The Hobbit'), findsOneWidget);
    expect(
      find.text('J. R. R. Tolkien • Middle-earth • Read by Rob Inglis'),
      findsOneWidget,
    );
    expect(find.text('11h 5m'), findsOneWidget);
  });

  testWidgets('offers the connection when no server is signed in',
      (tester) async {
    await _pump(
      tester,
      client: FakeAudiobookshelfClient(),
      savedSession: null,
    );

    expect(find.text('No Audiobookshelf server'), findsOneWidget);
    expect(find.text('Set up the connection'), findsOneWidget);
  });

  testWidgets('says an empty library is empty, not broken', (tester) async {
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
    );

    await _pump(tester, client: client);

    expect(find.text('No audiobooks yet'), findsOneWidget);
  });

  testWidgets('a page of unreadable records keeps the rest reachable',
      (tester) async {
    // Every record on the first page was skipped by the parser (half-scanned
    // books), but the server says the library has more. Calling that "empty"
    // would strand the books on the next page.
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
    );
    client.pagesByLibrary['lib-books'] = <AudiobookshelfLibraryItemsPage>[
      const AudiobookshelfLibraryItemsPage(
        items: <AudiobookshelfLibraryItemDto>[],
        rawCount: 3,
        total: 5,
        page: 0,
      ),
    ];

    await _pump(tester, client: client);

    expect(find.text('No audiobooks yet'), findsNothing);
    expect(find.text('Load the next page'), findsOneWidget);
  });

  testWidgets('a failed listing offers a retry', (tester) async {
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      libraryItemsError: AudiobookshelfException.notReachable(),
    );
    client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
      _book('item-1', 'The Hobbit'),
    ];

    await _pump(tester, client: client);
    expect(find.text('Try again'), findsOneWidget);

    client.libraryItemsError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('The Hobbit'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('picking another library swaps the list', (tester) async {
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
    );
    client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
      _book('item-1', 'The Hobbit'),
    ];
    client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
      _book('kid-1', 'Matilda'),
    ];

    await _pump(tester, client: client);
    expect(find.text('The Hobbit'), findsOneWidget);

    await tester.tap(find.text('Kids'));
    await tester.pumpAndSettle();

    expect(find.text('Matilda'), findsOneWidget);
    expect(find.text('The Hobbit'), findsNothing);
  });

  testWidgets('offers the rest of a big library, then loads it',
      (tester) async {
    const int pageSize = AudiobooksLibraryController.pageSize;
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
    );
    client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
      for (int i = 0; i < pageSize + 1; i++) _book('item-$i', 'Book $i'),
    ];

    await _pump(tester, client: client);

    final Finder loadMore = find.textContaining('Load more');
    await tester.scrollUntilVisible(loadMore, 300);
    expect(
      find.text('Load more ($pageSize of ${pageSize + 1})'),
      findsOneWidget,
    );

    await tester.tap(loadMore);
    await tester.pumpAndSettle();

    expect(find.textContaining('Load more'), findsNothing);
    expect(client.itemRequests.last.page, 1);
  });

  testWidgets('a library that cannot be listed does not trap the browser in it',
      (tester) async {
    // The server answers for one library and fails for the other every time
    // (a 500 on that library's items, or a listing too slow to finish).
    final client = _OneLibraryFailsClient(
      failingLibraryId: 'lib-kids',
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
    );
    client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
      _book('item-1', 'The Hobbit'),
    ];

    await _pump(tester, client: client);
    expect(find.text('The Hobbit'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Kids'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    // Trying again asks for the same library, which fails the same way.
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);

    expect(
      find.widgetWithText(ChoiceChip, 'Audiobooks'),
      findsOneWidget,
      reason: 'the library that works must stay reachable, or the browser '
          'stays on the failing one until the app is restarted',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Audiobooks'));
    await tester.pumpAndSettle();
    expect(find.text('The Hobbit'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('never renders the access token', (tester) async {
    final client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
    );
    client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
      _book('item-1', 'The Hobbit'),
    ];

    await _pump(tester, client: client);

    for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains('tok-1')));
    }
  });

  group('formatBookDuration', () {
    test('reads the way a listener reads a running time', () {
      expect(formatBookDuration(null), isNull);
      expect(formatBookDuration(Duration.zero), isNull);
      expect(formatBookDuration(const Duration(seconds: 20)), '1m');
      expect(formatBookDuration(const Duration(minutes: 48)), '48m');
      expect(formatBookDuration(const Duration(hours: 3)), '3h');
      expect(
        formatBookDuration(const Duration(hours: 11, minutes: 42)),
        '11h 42m',
      );
    });
  });
}

/// A server whose one library always fails to list, as the real client
/// reports an HTTP 500 for it, while every other library answers.
class _OneLibraryFailsClient extends FakeAudiobookshelfClient {
  _OneLibraryFailsClient({
    required this.failingLibraryId,
    required super.libraries,
  });

  final String failingLibraryId;

  @override
  Future<AudiobookshelfLibraryItemsPage> fetchLibraryItems(
    AudiobookshelfSession session, {
    required String libraryId,
    required int limit,
    required int page,
  }) {
    if (libraryId == failingLibraryId) {
      itemRequests.add((libraryId: libraryId, limit: limit, page: page));
      return Future<AudiobookshelfLibraryItemsPage>.error(
        AudiobookshelfException.serverError(500),
      );
    }
    return super.fetchLibraryItems(
      session,
      libraryId: libraryId,
      limit: limit,
      page: page,
    );
  }
}
