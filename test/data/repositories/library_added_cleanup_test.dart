// A track removed from the catalog takes its "added on" time with it, so it
// counts as new if it ever comes back. When the store refuses that cleanup,
// the time must still go, at the next write that does save, and must never
// be taken for the time of the track coming back.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';

class _Added extends InMemoryLibraryAddedStore {
  _Added() : super(<String, DateTime>{});
  bool refuse = false;

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {
    if (refuse) {
      throw const LocalStoreWriteException(LocalStoreArea.libraryAdded);
    }
    return super.save(addedAt);
  }
}

const Track _back = Track(id: '1', uri: 'subsonic:1', title: 'Back');
const Track _stays = Track(id: '2', uri: 'subsonic:2', title: 'Stays');

void main() {
  late _Added added;
  late DateTime now;
  late RecordingMusicLibraryRepository repo;

  Future<void> write(List<Track> tracks) => repo.upsertCatalog(
        sourceId: 'subsonic',
        tracks: tracks,
        albums: const [],
        artists: const [],
      );

  setUp(() async {
    added = _Added();
    now = DateTime.utc(2021);
    repo = RecordingMusicLibraryRepository(
      delegate: InMemoryMusicLibraryRepository(),
      addedStore: added,
      now: () => now,
    );
    await write(const <Track>[_back, _stays]);

    added.refuse = true;
    await repo.removeTracks(const <String>['subsonic:1']);
    added.refuse = false;
    now = DateTime.utc(2026);
  });

  test('a track that comes back after a refused cleanup counts as new',
      () async {
    await write(const <Track>[_back, _stays]);

    expect((await added.load())['subsonic:1'], DateTime.utc(2026));
    expect((await added.load())['subsonic:2'], DateTime.utc(2021));
  });

  test('once back, it keeps the time it came back at', () async {
    await write(const <Track>[_back, _stays]);
    now = DateTime.utc(2027);
    await write(const <Track>[_back, _stays]);

    expect((await added.load())['subsonic:1'], DateTime.utc(2026));
  });

  test('a cleanup refused again is still done later', () async {
    added.refuse = true;
    await write(const <Track>[_stays]);
    added.refuse = false;
    await write(const <Track>[_back, _stays]);

    expect((await added.load())['subsonic:1'], DateTime.utc(2026));
  });

  test('the time a refused cleanup left goes with the next write that saves',
      () async {
    await write(const <Track>[_stays]);

    expect(await added.load(), <String, DateTime>{
      'subsonic:2': DateTime.utc(2021),
    });
  });
}
