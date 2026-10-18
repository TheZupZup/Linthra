// A row carrying only half of a file stamp must read as unstamped.
//
// An incremental local scan skips re-parsing a file whose size and modified
// time both match the stamp stored beside its row. A row with only one of the
// two (written by hand, or left by a write that set one column and not the
// other) read back as a stamp with a zero for the missing half could match a
// real file by accident, and that file's changed tags would never be read
// again. The mapper has to treat it as no stamp at all, so the file is
// re-parsed.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/mappers/track_mapper.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';

TrackRow _row({int? size, int? modified}) => TrackRow(
      id: '/music/a.flac',
      sourceId: 'local',
      title: 'A',
      uri: '/music/a.flac',
      durationMs: 0,
      fileSizeBytes: size,
      fileModifiedAtMs: modified,
    );

void main() {
  group('fileStampFromRow', () {
    test('a row with both halves reads back as that stamp', () {
      expect(
        fileStampFromRow(_row(size: 4096, modified: 1700000000000)),
        const LocalFileStamp(sizeBytes: 4096, modifiedAtMs: 1700000000000),
      );
    });

    test('a row with only a size reads as unstamped', () {
      expect(fileStampFromRow(_row(size: 4096)), isNull);
    });

    test('a row with only a modified time reads as unstamped', () {
      expect(fileStampFromRow(_row(modified: 1700000000000)), isNull);
    });

    test('a row with neither reads as unstamped', () {
      expect(fileStampFromRow(_row()), isNull);
    });

    test('zeros are a stamp, not a missing one', () {
      // An empty file at the epoch is an odd file, but a real stamp: it is
      // only a missing half that means "parse this again".
      expect(
        fileStampFromRow(_row(size: 0, modified: 0)),
        const LocalFileStamp(sizeBytes: 0, modifiedAtMs: 0),
      );
    });

    test('stampedTrackFromRow keeps the track and drops a half stamp', () {
      final StampedTrack stamped = stampedTrackFromRow(_row(size: 4096));

      expect(stamped.track.uri, '/music/a.flac');
      expect(stamped.stamp, isNull);
    });
  });

  test('a half-stamped row stored in the catalog reads back unstamped',
      () async {
    final LinthraDatabase db =
        LinthraDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.tracks).insert(
          TracksCompanion.insert(
            id: '/music/size-only.flac',
            sourceId: 'local',
            title: 'Size only',
            uri: '/music/size-only.flac',
            fileSizeBytes: const Value(4096),
          ),
        );
    await db.into(db.tracks).insert(
          TracksCompanion.insert(
            id: '/music/mtime-only.flac',
            sourceId: 'local',
            title: 'Modified time only',
            uri: '/music/mtime-only.flac',
            fileModifiedAtMs: const Value(1700000000000),
          ),
        );

    final List<StampedTrack> read = await DriftMusicLibraryRepository(db)
        .getStampedTracksForSource('local');

    expect(read, hasLength(2));
    expect(read.map((StampedTrack t) => t.stamp), everyElement(isNull));
  });
}
