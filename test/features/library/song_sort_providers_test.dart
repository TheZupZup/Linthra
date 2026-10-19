import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/logical_track.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/features/library/song_sort_providers.dart';
import 'package:linthra/features/library/unified_library_providers.dart';

class _UnreadableAddedStore implements LibraryAddedStore {
  @override
  Future<Map<String, DateTime>> load() async =>
      throw const FormatException('corrupt');

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {}
}

LogicalTrack _song(List<(Track, String)> copies) =>
    LogicalTrack(<TrackSourceCandidate>[
      for (final (Track track, String sourceId) in copies)
        TrackSourceCandidate(track: track, sourceId: sourceId),
    ]);

Future<Map<String, DateTime>> _addedAt(
  List<LogicalTrack> songs,
  LibraryAddedStore store,
) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      libraryLogicalTracksProvider.overrideWithValue(songs),
      libraryAddedStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  // Auto-disposed: keep it listened to while it loads.
  final ProviderSubscription<Future<Map<String, DateTime>>> subscription =
      container.listen(librarySongAddedAtProvider.future, (_, __) {});
  return subscription.read();
}

void main() {
  const Track jellyfinCopy =
      Track(id: '101', title: 'Song', uri: 'jellyfin:101');
  const Track localCopy =
      Track(id: '/music/song.mp3', title: 'Song', uri: '/music/song.mp3');

  test('a song on two providers takes its earliest copy', () async {
    // Preferred on Jellyfin, which was signed into long after the local
    // folder already had the song.
    final Map<String, DateTime> addedAt = await _addedAt(
      <LogicalTrack>[
        _song(<(Track, String)>[
          (jellyfinCopy, 'jellyfin'),
          (localCopy, 'local')
        ]),
      ],
      InMemoryLibraryAddedStore(<String, DateTime>{
        'jellyfin:101': DateTime(2026, 9, 1),
        '/music/song.mp3': DateTime(2025, 2, 1),
      }),
    );

    // Under both copies, so it holds whichever one is shown.
    expect(addedAt, <String, DateTime>{
      'jellyfin:101': DateTime(2025, 2, 1),
      '/music/song.mp3': DateTime(2025, 2, 1),
    });
  });

  test('reads a time a pre-v2 build stored under the bare id', () async {
    final Map<String, DateTime> addedAt = await _addedAt(
      <LogicalTrack>[
        _song(<(Track, String)>[(jellyfinCopy, 'jellyfin')]),
      ],
      InMemoryLibraryAddedStore(<String, DateTime>{'101': DateTime(2024)}),
    );

    expect(addedAt, <String, DateTime>{'jellyfin:101': DateTime(2024)});
  });

  test('leaves out a song nobody stamped', () async {
    final Map<String, DateTime> addedAt = await _addedAt(
      <LogicalTrack>[
        _song(<(Track, String)>[(jellyfinCopy, 'jellyfin')]),
        _song(<(Track, String)>[(localCopy, 'local')]),
      ],
      InMemoryLibraryAddedStore(<String, DateTime>{
        '/music/song.mp3': DateTime(2026),
      }),
    );

    expect(addedAt, <String, DateTime>{'/music/song.mp3': DateTime(2026)});
  });

  test('an unreadable store reads as no times rather than failing', () async {
    final Map<String, DateTime> addedAt = await _addedAt(
      <LogicalTrack>[
        _song(<(Track, String)>[(localCopy, 'local')]),
      ],
      _UnreadableAddedStore(),
    );

    expect(addedAt, isEmpty);
  });
}
