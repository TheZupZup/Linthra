// One "added on" date that can't be read must not fail every catalog write.
//
// Every scan and sync writes the catalog through
// RecordingMusicLibraryRepository, which reads the "added on" dates to stamp
// new tracks. A date outside DateTime's range (a damaged or hand-edited entry,
// or one from another build) threw out of that read, so every local scan
// ended in "Couldn't scan that folder", every Subsonic or Plex sync in
// "Something went wrong saving your library", and Recently added stopped
// taking anything new, on every launch.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/shared_preferences_library_added_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _key = 'library_added_v1';

const Track _old = Track(
  id: '/music/Holocene.flac',
  title: 'Holocene',
  uri: '/music/Holocene.flac',
);

const Track _new = Track(
  id: '/music/Calgary.flac',
  title: 'Calgary',
  uri: '/music/Calgary.flac',
);

const Track _remote =
    Track(id: '48211', title: 'Re: Stacks', uri: 'subsonic:48211');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LinthraDatabase db;
  late RecordingMusicLibraryRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _key: '{"/music/Holocene.flac":1700000000000,'
          '"/music/Gone.flac":9000000000000000}',
    });
    db = LinthraDatabase.forTesting(NativeDatabase.memory());
    repository = RecordingMusicLibraryRepository(
      delegate: DriftMusicLibraryRepository(db),
      addedStore: const SharedPreferencesLibraryAddedStore(),
      now: () => DateTime.utc(2026, 10, 6),
    );
  });

  tearDown(() => db.close());

  test('the store reads the dates it can', () async {
    final Map<String, DateTime> loaded =
        await const SharedPreferencesLibraryAddedStore().load();

    expect(loaded.keys, <String>['/music/Holocene.flac']);
  });

  test('a local scan writes, and stamps its new track', () async {
    await repository.upsertStampedCatalog(
      sourceId: 'local',
      tracks: const <StampedTrack>[
        StampedTrack(track: _old),
        StampedTrack(track: _new),
      ],
    );

    final Map<String, DateTime> added =
        await const SharedPreferencesLibraryAddedStore().load();
    expect(added[_old.uri]?.millisecondsSinceEpoch, 1700000000000);
    expect(
      added[_new.uri]?.millisecondsSinceEpoch,
      DateTime.utc(2026, 10, 6).millisecondsSinceEpoch,
    );
  });

  test('a server sync writes its batch', () async {
    await repository.upsertTracks(
      sourceId: 'subsonic',
      tracks: const <Track>[_remote],
    );

    expect(
      (await repository.getAllTracks()).map((Track t) => t.uri),
      contains(_remote.uri),
    );
  });
}
