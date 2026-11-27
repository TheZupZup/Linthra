import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/cue_sheet.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

/// Replays test/fixtures/local_track_cases.txt: how tricky file names and a
/// few hundred random files, documents and CUE tracks were named, recorded
/// from the Dart mapper the Rust one replaced. A change here renames a
/// library on the next scan, splits an album, or files a song under the
/// wrong artist.
void main() {
  final List<String> lines =
      File('test/fixtures/local_track_cases.txt').readAsLinesSync();

  test('files, documents and CUE tracks map to the recorded tracks', () {
    expect(lines, hasLength(greaterThan(200)));
    int cues = 0;
    for (int i = 0; i < lines.length; i++) {
      final Map<String, Object?> c =
          jsonDecode(lines[i]) as Map<String, Object?>;
      final String path = c['path']! as String;
      final String? root = c['root'] as String?;
      final LocalAudioMetadata? metadata = _metadata(c['tags']);
      final String reason = lines[i];

      expect(
        _describe(LocalTrackMapper.fromPath(
          path,
          scanRoot: root,
          metadata: metadata,
        )),
        c['file'],
        reason: reason,
      );
      expect(
        _describe(LocalTrackMapper.fromSafDocument(SafAudioDocument(
          uri: 'content://doc/$i',
          name: path.split('/').last,
          metadata: metadata,
        ))),
        c['document'],
        reason: reason,
      );
      final Object? cue = c['cue'];
      if (cue == null) continue;
      cues++;
      expect(
        _describe(LocalTrackMapper.fromCueTrack(
          _cue(cue, path),
          cuePath: '/music/sheet.cue',
          metadata: metadata,
          scanRoot: root ?? '',
          cueSheetSizeBytes: 10,
          cueSheetModifiedAtMs: 20,
        )),
        c['cueTrack'],
        reason: reason,
      );
    }
    expect(cues, greaterThan(100));
  });

  test('an unpaired surrogate reads as U+FFFD', () {
    expect(
      LocalTrackMapper.fromPath(
        '/m/A/01 - a.flac',
        scanRoot: '/m',
        metadata: const LocalAudioMetadata(title: 'x\uD800'),
      ).title,
      'x�',
    );
    expect(
      LocalTrackMapper.fromPath('/m/A/01 - \uDC00.flac', scanRoot: '/m').title,
      '�',
    );
  });
}

LocalAudioMetadata? _metadata(Object? json) {
  if (json == null) return null;
  final List<Object?> t = json as List<Object?>;
  final int? durationUs = t[7] as int?;
  final String? artwork = t[8] as String?;
  return LocalAudioMetadata(
    title: t[0] as String?,
    artist: t[1] as String?,
    album: t[2] as String?,
    albumArtist: t[3] as String?,
    albumId: t[4] as String?,
    trackNumber: t[5] as int?,
    discNumber: t[6] as int?,
    duration: durationUs == null ? null : Duration(microseconds: durationUs),
    artworkUri: artwork == null ? null : Uri.parse(artwork),
  );
}

CueSheetTrack _cue(Object json, String audioPath) {
  final List<Object?> c = json as List<Object?>;
  final int? endUs = c[2] as int?;
  return CueSheetTrack(
    number: c[0]! as int,
    audioPath: audioPath,
    start: Duration(microseconds: c[1]! as int),
    end: endUs == null ? null : Duration(microseconds: endUs),
    title: c[3] as String?,
    performer: c[4] as String?,
    album: c[5] as String?,
    albumPerformer: c[6] as String?,
  );
}

List<Object?> _describe(Track t) => <Object?>[
      t.id,
      t.uri,
      t.title,
      t.artistName,
      t.albumName,
      t.albumId,
      t.albumArtistName,
      t.trackNumber,
      t.duration.inMicroseconds,
      t.cueStart?.inMicroseconds,
      t.cueEnd?.inMicroseconds,
      t.cueSheetSizeBytes,
      t.cueSheetModifiedAtMs,
      t.discNumber,
      t.artworkUri?.toString(),
    ];
