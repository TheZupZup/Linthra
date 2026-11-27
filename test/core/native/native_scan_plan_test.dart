import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/native_scan_plan.dart';

/// The records NativeScanPlan sends carry every field the incremental rules
/// look at: the stamps, the CUE sheet's size and mtime, and whether a cover
/// is gone from the cache. The rules themselves are tested in
/// native/linthra_core/src/scan/incremental.rs and through LocalMusicSource.
void main() {
  const LocalFileStamp now = LocalFileStamp(sizeBytes: 100, modifiedAtMs: 5);
  const LocalFileStamp old = LocalFileStamp(sizeBytes: 90, modifiedAtMs: 4);
  const LocalFileStamp sheet = LocalFileStamp(sizeBytes: 7, modifiedAtMs: 9);
  final Uri cover = Uri.parse('file:///cache/cover.jpg');

  StampedTrack row(
    LocalFileStamp? stamp, {
    Uri? artwork,
    LocalFileStamp? cue,
  }) =>
      StampedTrack(
        stamp: stamp,
        track: Track(
          id: '/m/a.flac',
          title: 'A',
          uri: '/m/a.flac',
          artworkUri: artwork,
          cueSheetSizeBytes: cue?.sizeBytes,
          cueSheetModifiedAtMs: cue?.modifiedAtMs,
        ),
      );

  bool reuse(
    LocalFileStamp? stamp,
    StampedTrack? indexed, {
    List<NativeScanCueEntry> cue = const <NativeScanCueEntry>[],
    Set<Uri> missing = const <Uri>{},
    bool readUnchanged = false,
  }) =>
      NativeScanPlan.reuse(
        stamp: stamp,
        indexed: indexed,
        cue: cue,
        missingArtwork: missing,
        readUnchanged: readUnchanged,
      );

  test('a plain file is reused only when nothing about it moved', () {
    expect(reuse(now, row(now)), isTrue);
    expect(reuse(now, row(old)), isFalse);
    expect(reuse(null, row(now)), isFalse);
    expect(reuse(now, null), isFalse);
    expect(reuse(now, row(now), readUnchanged: true), isFalse);
    expect(reuse(now, row(now, artwork: cover)), isTrue);
    expect(
      reuse(now, row(now, artwork: cover), missing: <Uri>{cover}),
      isFalse,
    );
  });

  test("CUE tracks carry their sheet's stamp both ways", () {
    final StampedTrack track = row(now, cue: sheet);
    expect(
      reuse(now, null, cue: <NativeScanCueEntry>[
        (sheet: sheet, indexed: track),
        (sheet: sheet, indexed: track),
      ]),
      isTrue,
    );
    // The sheet changed since the row was built.
    expect(
      reuse(now, null, cue: <NativeScanCueEntry>[
        (sheet: old, indexed: track),
      ]),
      isFalse,
    );
    // One track's row is missing.
    expect(
      reuse(now, null, cue: <NativeScanCueEntry>[
        (sheet: sheet, indexed: track),
        (sheet: sheet, indexed: null),
      ]),
      isFalse,
    );
  });

  test('settling reads every answer bit', () {
    expect(
      NativeScanPlan.settle(
        stamp: null,
        indexed: row(old),
        cue: const <NativeScanCueEntry>[],
        readUnchanged: false,
        hasTags: false,
        failed: true,
      ),
      (keep: true, stamp: false, vanished: true, reused: true),
    );
    expect(
      NativeScanPlan.settle(
        stamp: now,
        indexed: row(now),
        cue: const <NativeScanCueEntry>[],
        readUnchanged: false,
        hasTags: false,
        failed: true,
      ),
      (keep: true, stamp: true, vanished: false, reused: false),
    );
    expect(
      NativeScanPlan.settle(
        stamp: now,
        indexed: null,
        cue: const <NativeScanCueEntry>[],
        readUnchanged: false,
        hasTags: true,
        failed: false,
      ),
      (keep: false, stamp: true, vanished: false, reused: false),
    );
    expect(
      NativeScanPlan.settle(
        stamp: now,
        indexed: null,
        cue: <NativeScanCueEntry>[
          (sheet: sheet, indexed: row(now, cue: sheet))
        ],
        readUnchanged: true,
        hasTags: false,
        failed: true,
      ),
      (keep: true, stamp: false, vanished: false, reused: true),
    );
  });
}
