// The incremental local scan (#411).
//
// These tests count *parser calls*, not results. Asserting that two scans
// produce the same tracks proves nothing about whether the second one re-read
// every file, which is the entire point: the catalog was already correct before
// this change, it was just expensive to arrive at.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';

import '../../../features/library/fake_audio_file_scanner.dart';

/// A tag reader that answers from a map and counts every call, so a test can
/// say "this scan opened no files" rather than "this scan produced the same
/// answer".
class _CountingMetadataReader implements LocalMetadataReader {
  final Map<String, LocalAudioMetadata> byPath = <String, LocalAudioMetadata>{};
  final List<String> reads = <String>[];

  int get readCount => reads.length;

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    reads.add(path);
    return byPath[path];
  }
}

/// A tag reader that can tell a failed read from a file with no tags, like the
/// filesystem reader, answering from [byPath] unless [failing] holds the path,
/// and never answering for a path in [hanging].
class _OutcomeMetadataReader
    implements LocalMetadataReader, LocalMetadataReadOutcomes {
  final Map<String, LocalAudioMetadata> byPath = <String, LocalAudioMetadata>{};
  final Set<String> failing = <String>{};
  final Set<String> hanging = <String>{};
  final List<String> reads = <String>[];

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async =>
      (await readWithOutcome(path)).metadata;

  @override
  Future<LocalMetadataRead> readWithOutcome(String path) async {
    reads.add(path);
    if (hanging.contains(path)) return Completer<LocalMetadataRead>().future;
    if (failing.contains(path)) return (metadata: null, failed: true);
    return (metadata: byPath[path], failed: false);
  }
}

/// Whether the selected folder answers: [answer] when it does, nothing at
/// all while [hangs].
class _Presence implements DirectoryReadability {
  _Presence({this.answer, this.hangs = false});

  final LocalRootFault? answer;
  final bool hangs;
  int asked = 0;

  @override
  Future<LocalRootFault?> inspect(String path) {
    asked++;
    if (hangs) return Completer<LocalRootFault?>().future;
    return Future<LocalRootFault?>.value(answer);
  }
}

/// An in-memory filesystem stat: a path maps to a stamp, and a path with no
/// entry stats as missing (which is how a deleted file behaves).
class _FakeStatReader implements LocalFileStatReader {
  _FakeStatReader(this.stamps);

  Map<String, LocalFileStamp> stamps;
  int statCount = 0;

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    statCount++;
    return stamps[path];
  }
}

LocalFileStamp _stamp(int size, int mtime) =>
    LocalFileStamp(sizeBytes: size, modifiedAtMs: mtime);

void main() {
  group('a second scan of an unchanged library', () {
    late FakeAudioFileScanner files;
    late _CountingMetadataReader tags;
    late _FakeStatReader stats;

    setUp(() {
      files = FakeAudioFileScanner(
        filesByFolder: <String, List<String>>{
          '/music': <String>[
            '/music/a.flac',
            '/music/b.flac',
            '/music/c.flac',
          ],
        },
      );
      tags = _CountingMetadataReader();
      stats = _FakeStatReader(<String, LocalFileStamp>{
        '/music/a.flac': _stamp(100, 1000),
        '/music/b.flac': _stamp(200, 2000),
        '/music/c.flac': _stamp(300, 3000),
      });
    });

    LocalMusicSource source({
      Map<String, StampedTrack> alreadyIndexed = const <String, StampedTrack>{},
    }) {
      return LocalMusicSource(
        folderPath: '/music',
        scanner: files,
        metadataReader: tags,
        statReader: stats,
        alreadyIndexed: alreadyIndexed,
      );
    }

    /// Runs one scan and returns what a catalog write would store, so the next
    /// scan can be handed exactly what the previous one persisted.
    Future<Map<String, StampedTrack>> scanInto(
      Map<String, StampedTrack> indexed,
    ) async {
      final LocalScan scan = await source(alreadyIndexed: indexed).scanTracks();
      return <String, StampedTrack>{
        for (final Track track in scan.tracks)
          track.uri: StampedTrack(track: track, stamp: scan.stamps[track.uri]),
      };
    }

    test('parses nothing at all', () async {
      final Map<String, StampedTrack> first =
          await scanInto(const <String, StampedTrack>{});
      expect(tags.readCount, 3, reason: 'the first scan reads every file');

      tags.reads.clear();
      final LocalScan second = await source(alreadyIndexed: first).scanTracks();

      expect(tags.readCount, 0);
      expect(second.report.reusedTracks, 3);
      expect(second.report.parsedTracks, 0);
      expect(second.report.importedTracks, 3);
    });

    test('still produces the same catalog', () async {
      final Map<String, StampedTrack> first =
          await scanInto(const <String, StampedTrack>{});
      final LocalScan second = await source(alreadyIndexed: first).scanTracks();

      expect(
        second.tracks.map((Track t) => t.uri).toList()..sort(),
        <String>['/music/a.flac', '/music/b.flac', '/music/c.flac'],
      );
    });

    test('costs one stat per file, not one open', () async {
      final Map<String, StampedTrack> first =
          await scanInto(const <String, StampedTrack>{});
      stats.statCount = 0;

      await source(alreadyIndexed: first).scanTracks();

      expect(stats.statCount, 3);
      expect(tags.readCount, 3, reason: 'unchanged from the first scan');
    });
  });

  group('what a second scan does parse', () {
    late FakeAudioFileScanner files;
    late _CountingMetadataReader tags;
    late _FakeStatReader stats;
    late Map<String, StampedTrack> indexed;

    setUp(() async {
      files = FakeAudioFileScanner(
        filesByFolder: <String, List<String>>{
          '/music': <String>['/music/a.flac', '/music/b.flac'],
        },
      );
      tags = _CountingMetadataReader();
      stats = _FakeStatReader(<String, LocalFileStamp>{
        '/music/a.flac': _stamp(100, 1000),
        '/music/b.flac': _stamp(200, 2000),
      });
      final LocalScan first = await LocalMusicSource(
        folderPath: '/music',
        scanner: files,
        metadataReader: tags,
        statReader: stats,
      ).scanTracks();
      indexed = <String, StampedTrack>{
        for (final Track track in first.tracks)
          track.uri: StampedTrack(track: track, stamp: first.stamps[track.uri]),
      };
      tags.reads.clear();
    });

    Future<LocalScan> rescan({bool full = false}) {
      return LocalMusicSource(
        folderPath: '/music',
        scanner: files,
        metadataReader: tags,
        statReader: stats,
        alreadyIndexed: full ? const <String, StampedTrack>{} : indexed,
      ).scanTracks();
    }

    test('a file whose mtime moved', () async {
      stats.stamps['/music/b.flac'] = _stamp(200, 9999);

      final LocalScan scan = await rescan();

      expect(tags.reads, <String>['/music/b.flac']);
      expect(scan.report.reusedTracks, 1);
      expect(scan.report.parsedTracks, 1);
    });

    test('a file whose size changed but whose mtime did not', () async {
      // A rewrite that happened to land in the same second, or a tool that
      // preserved the timestamp. Size alone is enough to re-parse.
      stats.stamps['/music/a.flac'] = _stamp(101, 1000);

      await rescan();

      expect(tags.reads, <String>['/music/a.flac']);
    });

    test('a newly added file, and only it', () async {
      files = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>['/music/a.flac', '/music/b.flac', '/music/new.flac'],
      });
      stats.stamps['/music/new.flac'] = _stamp(400, 4000);

      final LocalScan scan = await rescan();

      expect(tags.reads, <String>['/music/new.flac']);
      expect(scan.tracks, hasLength(3));
      expect(scan.report.reusedTracks, 2);
    });

    test('a file that can no longer be stat-ed', () async {
      // A file the walk listed but the stat could not answer for: a race with a
      // delete, a permission change, a mount that went away mid-scan. Unknown
      // means parse it, never means reuse it.
      stats.stamps.remove('/music/b.flac');

      final LocalScan scan = await rescan();

      expect(tags.reads, <String>['/music/b.flac']);
      expect(scan.stamps.containsKey('/music/b.flac'), isFalse);
    });

    test('a file whose cover the artwork cache no longer holds', () async {
      // The file did not change, but the cache its row's cover lives in was
      // reclaimed. Reusing the row would keep pointing at a cover that is
      // gone, for good; reading the file again is what brings it back.
      final Uri gone = Uri.file('/cache/local_artwork/gone.img');
      final StampedTrack a = indexed['/music/a.flac']!;
      indexed['/music/a.flac'] = StampedTrack(
        track: a.track.copyWith(artworkUri: gone),
        stamp: a.stamp,
      );

      final LocalScan scan = await LocalMusicSource(
        folderPath: '/music',
        scanner: files,
        metadataReader: tags,
        statReader: stats,
        alreadyIndexed: indexed,
        missingArtwork: <Uri>{gone},
      ).scanTracks();

      expect(tags.reads, <String>['/music/a.flac']);
      expect(scan.report.reusedTracks, 1);
    });

    test('a deleted file simply stops appearing', () async {
      files = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>['/music/a.flac'],
      });

      final LocalScan scan = await rescan();

      expect(scan.tracks.map((Track t) => t.uri), <String>['/music/a.flac']);
      expect(tags.readCount, 0, reason: 'the surviving file was unchanged');
    });

    test('a full rescan re-parses everything', () async {
      final LocalScan scan = await rescan(full: true);

      expect(tags.readCount, 2);
      expect(scan.report.reusedTracks, 0);
      expect(scan.report.parsedTracks, 2);
    });

    test('a full rescan still records fresh stamps', () async {
      // Otherwise recovery would cost a full parse on the *next* scan too.
      final LocalScan scan = await rescan(full: true);

      expect(scan.stamps['/music/a.flac'], _stamp(100, 1000));
      expect(scan.stamps['/music/b.flac'], _stamp(200, 2000));
    });
  });

  // #743: a new or changed file whose read failed this time (a share stalling
  // past the parse limit, an I/O error) was stored as a filename-only row with
  // its real stamp, so every later scan reused that row and the tags never came
  // back.
  group('a read that failed this time (#743)', () {
    late FakeAudioFileScanner files;
    late _OutcomeMetadataReader tags;
    late _FakeStatReader stats;
    const LocalAudioMetadata xTags = LocalAudioMetadata(
      title: 'Real Title',
      artist: 'Real Artist',
      album: 'Real Album',
    );

    setUp(() {
      files = FakeAudioFileScanner(
        filesByFolder: <String, List<String>>{
          '/music': <String>['/music/a.flac', '/music/x.flac'],
        },
      );
      tags = _OutcomeMetadataReader()
        ..byPath['/music/a.flac'] = const LocalAudioMetadata(title: 'A')
        ..byPath['/music/x.flac'] = xTags;
      stats = _FakeStatReader(<String, LocalFileStamp>{
        '/music/a.flac': _stamp(100, 1000),
        '/music/x.flac': _stamp(200, 2000),
      });
    });

    Future<(LocalScan, Map<String, StampedTrack>)> scan(
      Map<String, StampedTrack> indexed, {
      bool readUnchanged = false,
    }) async {
      tags.reads.clear();
      final LocalScan result = await LocalMusicSource(
        folderPath: '/music',
        scanner: files,
        metadataReader: tags,
        statReader: stats,
        alreadyIndexed: indexed,
        readUnchanged: readUnchanged,
      ).scanTracks();
      return (
        result,
        <String, StampedTrack>{
          for (final Track track in result.tracks)
            track.uri:
                StampedTrack(track: track, stamp: result.stamps[track.uri]),
        },
      );
    }

    Track trackAt(LocalScan scan, String uri) =>
        scan.tracks.singleWhere((Track t) => t.uri == uri);

    test('a new file whose read failed is read again by the next scan',
        () async {
      tags.failing.add('/music/x.flac');
      final (LocalScan first, Map<String, StampedTrack> stored) =
          await scan(const <String, StampedTrack>{});
      expect(trackAt(first, '/music/x.flac').title, isNot('Real Title'),
          reason: 'built from the file name this time');
      expect(first.stamps.containsKey('/music/x.flac'), isFalse,
          reason: 'a stamp would have the next scan reuse that row');
      expect(first.stamps['/music/a.flac'], _stamp(100, 1000));

      // The share answers again.
      tags.failing.clear();
      final (LocalScan second, _) = await scan(stored);

      expect(tags.reads, <String>['/music/x.flac'],
          reason: 'only the file that failed is read again');
      final Track x = trackAt(second, '/music/x.flac');
      expect(x.title, 'Real Title');
      expect(x.artistName, 'Real Artist');
      expect(second.stamps['/music/x.flac'], _stamp(200, 2000));
    });

    test('a changed file whose read failed is read again too', () async {
      final (_, Map<String, StampedTrack> stored) =
          await scan(const <String, StampedTrack>{});
      // Re-tagged on disk, then the read stalls.
      stats.stamps['/music/x.flac'] = _stamp(210, 3000);
      tags.failing.add('/music/x.flac');
      final (LocalScan failed, Map<String, StampedTrack> afterFailure) =
          await scan(stored);
      expect(failed.stamps.containsKey('/music/x.flac'), isFalse);

      tags.failing.clear();
      final (LocalScan retried, _) = await scan(afterFailure);

      expect(tags.reads, <String>['/music/x.flac']);
      expect(trackAt(retried, '/music/x.flac').title, 'Real Title');
      expect(retried.stamps['/music/x.flac'], _stamp(210, 3000));
    });

    test('a file that never reads is tried once more, then left alone',
        () async {
      // One the parser loops on, say: the time limit stops it every time.
      tags.failing.add('/music/x.flac');
      final (_, Map<String, StampedTrack> first) =
          await scan(const <String, StampedTrack>{});
      final (LocalScan second, Map<String, StampedTrack> stored) =
          await scan(first);
      expect(tags.reads, <String>['/music/x.flac']);
      expect(second.stamps['/music/x.flac'], _stamp(200, 2000),
          reason: 'the second failure in a row keeps its stamp');

      await scan(stored);

      expect(tags.reads, isEmpty, reason: 'no read on every scan from here');
    });

    test('a file read fine with no tags is settled at once', () async {
      tags.byPath.remove('/music/x.flac');
      final (LocalScan first, Map<String, StampedTrack> stored) =
          await scan(const <String, StampedTrack>{});
      expect(first.stamps['/music/x.flac'], _stamp(200, 2000));

      await scan(stored);

      expect(tags.reads, isEmpty);
    });

    // #783: a change to how tags are read reads unchanged files once more.
    test(
        'an unchanged file whose re-read for new tag reading failed keeps '
        'its row, and is read again by the next scan', () async {
      final (_, Map<String, StampedTrack> indexed) =
          await scan(const <String, StampedTrack>{});
      tags.failing.add('/music/x.flac');
      final (LocalScan reread, Map<String, StampedTrack> stored) =
          await scan(indexed, readUnchanged: true);
      expect(tags.reads, <String>['/music/a.flac', '/music/x.flac']);
      expect(trackAt(reread, '/music/x.flac').title, 'Real Title');
      expect(reread.stamps.containsKey('/music/x.flac'), isFalse,
          reason: "with its stamp, it keeps the old reader's tags for good");
      expect(reread.stamps['/music/a.flac'], _stamp(100, 1000));

      // The share answers again, and the new reader finds more in it.
      tags.failing.clear();
      tags.byPath['/music/x.flac'] = const LocalAudioMetadata(
        title: 'Fixed Title',
        artist: 'Real Artist',
      );
      final (LocalScan retried, _) = await scan(stored);

      expect(tags.reads, <String>['/music/x.flac']);
      expect(trackAt(retried, '/music/x.flac').title, 'Fixed Title');
      expect(retried.stamps['/music/x.flac'], _stamp(200, 2000));
    });

    test(
        'one whose read fails again keeps that row, not one built from its '
        'file name, and is left alone', () async {
      final (_, Map<String, StampedTrack> indexed) =
          await scan(const <String, StampedTrack>{});
      tags.failing.add('/music/x.flac');
      final (_, Map<String, StampedTrack> reread) =
          await scan(indexed, readUnchanged: true);

      final (LocalScan second, Map<String, StampedTrack> stored) =
          await scan(reread);
      expect(tags.reads, <String>['/music/x.flac']);
      final Track x = trackAt(second, '/music/x.flac');
      expect(x.title, 'Real Title');
      expect(x.artistName, 'Real Artist');
      expect(second.stamps['/music/x.flac'], _stamp(200, 2000),
          reason: 'the second failure in a row keeps its stamp');

      await scan(stored);

      expect(tags.reads, isEmpty, reason: 'no read on every scan from here');
    });
  });

  group('storage that stops answering mid-scan (#778)', () {
    const Duration stall = Duration(milliseconds: 50);
    late FakeAudioFileScanner files;
    late _OutcomeMetadataReader tags;
    late _FakeStatReader stats;

    setUp(() {
      files = FakeAudioFileScanner(
        filesByFolder: <String, List<String>>{
          '/nas': <String>['/nas/a.flac', '/nas/b.flac', '/nas/c.flac'],
        },
      );
      tags = _OutcomeMetadataReader()
        ..byPath['/nas/a.flac'] = const LocalAudioMetadata(title: 'A')
        ..byPath['/nas/b.flac'] = const LocalAudioMetadata(title: 'B')
        ..byPath['/nas/c.flac'] = const LocalAudioMetadata(title: 'C');
      stats = _FakeStatReader(<String, LocalFileStamp>{
        '/nas/a.flac': _stamp(100, 1000),
        '/nas/b.flac': _stamp(200, 2000),
        '/nas/c.flac': _stamp(300, 3000),
      });
    });

    Future<LocalScan> scan(DirectoryReadability presence) => LocalMusicSource(
          folderPath: '/nas',
          scanner: files,
          metadataReader: tags,
          statReader: stats,
          presence: presence,
          stallLimit: stall,
        ).scanTracks();

    test(
        'a read that never comes back failed, and the scan goes on while '
        'the folder answers', () async {
      tags.hanging.add('/nas/b.flac');
      final _Presence presence = _Presence();

      final LocalScan result = await scan(presence);

      expect(
        result.tracks.map((Track t) => t.title),
        <String>['A', 'b', 'C'],
        reason: 'b is named after its file, as any failed read is',
      );
      expect(result.stamps.containsKey('/nas/b.flac'), isFalse,
          reason: 'with no stamp, the next scan reads it again');
      expect(presence.asked, 1);
    });

    test(
        'a read that never comes back, in a folder that stopped answering, '
        'gives the folder up there', () async {
      tags.hanging.add('/nas/a.flac');
      final _Presence presence = _Presence(answer: LocalRootFault.unavailable);

      await expectLater(
        scan(presence),
        throwsA(
          isA<FolderScanException>().having(
            (FolderScanException error) => error.code,
            'code',
            LocalRootFault.unavailable.code,
          ),
        ),
      );
      expect(tags.reads, <String>['/nas/a.flac'],
          reason: 'every file left would have stalled the same way');
    });

    test('a folder that never answers the check is given up the same way',
        () async {
      tags.hanging.add('/nas/a.flac');

      await expectLater(
        scan(_Presence(hangs: true)),
        throwsA(
          isA<FolderScanException>().having(
            (FolderScanException error) => error.code,
            'code',
            LocalRootFault.unavailable.code,
          ),
        ),
      );
    });
  });

  group('platforms and sources with no stamps', () {
    test('no stat reader means every file is parsed, as before', () async {
      final tags = _CountingMetadataReader();
      final source = LocalMusicSource(
        folderPath: '/music',
        scanner: FakeAudioFileScanner(
          filesByFolder: <String, List<String>>{
            '/music': <String>['/music/a.flac'],
          },
        ),
        metadataReader: tags,
        // statReader defaults to the unsupported one (Android, and any caller
        // that has not opted in).
      );

      final LocalScan first = await source.scanTracks();
      final LocalScan second = await source.scanTracks();

      expect(tags.readCount, 2);
      expect(first.stamps, isEmpty);
      expect(second.report.reusedTracks, 0);
    });
  });

  group('LocalFileStamp', () {
    test('an unknown previous stamp always means parse', () {
      expect(_stamp(1, 1).differsFrom(null), isTrue);
    });

    test('identical size and mtime means skip', () {
      expect(_stamp(100, 1000).differsFrom(_stamp(100, 1000)), isFalse);
    });

    test('either half moving means parse', () {
      expect(_stamp(100, 1000).differsFrom(_stamp(101, 1000)), isTrue);
      expect(_stamp(100, 1000).differsFrom(_stamp(100, 1001)), isTrue);
    });
  });
}
