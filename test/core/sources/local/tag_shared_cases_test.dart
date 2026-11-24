// The tag files in test/fixtures/tags/ and what reading each one gives.
//
// The Rust core reads the same files (native/linthra_core/src/tags/) and is
// held to the same expectations in test/fixtures/tags/cases.txt, so the two
// readers cannot drift apart. Here the Dart reader that follows the spec,
// VorbisTagsInTheClear plus the reader's field mapping, replays them.
//
// The files are built by AudioTagFixtures. To change a case, edit [_cases]
// and rewrite the files and the expectations:
//
//     LINTHRA_WRITE_TAG_FIXTURES=1 flutter test test/core/sources/local/tag_shared_cases_test.dart
//
// then review the diff of cases.txt by hand: it is the reference for both
// readers.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/vorbis_tags_in_the_clear.dart';

import 'audio_tag_fixtures.dart';

const String _dir = 'test/fixtures/tags';
final Uint8List _cover = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
final Uint8List _back = Uint8List.fromList(<int>[9, 9]);

/// Every fixture file, in the order cases.txt lists them.
final Map<String, Uint8List Function()> _cases = <String, Uint8List Function()>{
  'flac_tagged.flac': () => AudioTagFixtures.flac(
        title: 'Hello',
        artist: 'Alice',
        albumArtist: 'Various Artists',
        album: 'Album',
        track: '3/12',
        coverImage: _cover,
      ),
  'flac_collaboration.flac': () => AudioTagFixtures.flac(
        title: 'Duet',
        artist: 'Alice',
        artists: <String>['Bob', '  '],
        track: '1',
      ),
  'flac_album_artist_underscore.flac': () =>
      AudioTagFixtures.flacWithRawComments(<String>[
        'TITLE=X',
        'ALBUM_ARTIST=Label',
        'ARTIST=  ',
      ]),
  'flac_vinyl_side.flac': () =>
      AudioTagFixtures.flac(title: 'Side A', track: 'A1'),
  'flac_odd_comments.flac': () => AudioTagFixtures.flacWithRawComments(<String>[
        'TITLE=Kept',
        'no equals sign',
        '=empty name',
        'tItLe=Second',
        'TRACKNUMBER=﻿ 7',
        'ALBUM=﻿ Spaced ﻿',
        'ARTIST=ß',
        'ßTITLE=not a title',
      ]),
  'flac_blank.flac': () => AudioTagFixtures.flacWithRawComments(<String>[
        'TITLE=   ',
        'TRACKNUMBER=0',
        'ALBUM=\u0085Nel\u0085',
        'ALBUMARTIST=\u0085',
      ]),
  'flac_track_overflow.flac': () => AudioTagFixtures.flacWithRawComments(
      <String>['TRACKNUMBER=99999999999999999999']),
  'flac_padding_cover.flac': () => AudioTagFixtures.flac(
      title: 'Padded', paddingBefore: 300, coverImage: _cover),
  'flac_no_length.flac': () =>
      AudioTagFixtures.flac(title: 'Unknown length', totalSamples: 0),
  'vorbis_tagged.ogg': () => AudioTagFixtures.oggVorbis(
        comments: <String>[
          'TITLE=Ogg',
          'ARTIST=A',
          'ALBUM=B',
          'TRACKNUMBER=05',
        ],
        coverImage: _cover,
      ),
  'vorbis_invalid_utf8.ogg': () => AudioTagFixtures.oggVorbis(
        comments: <String>['TITLE=Kept'],
        rawComments: <List<int>>[
          <int>[0x41, 0x3D, 0xFF, 0xFE],
        ],
      ),
  'vorbis_48k.ogg': () => AudioTagFixtures.oggVorbis(
        comments: <String>['TITLE=Half'],
        sampleRate: 48000,
        totalSamples: 48000 * 2 + 24000,
      ),
  'opus_tagged.opus': () => AudioTagFixtures.opus(
        comments: <String>['TITLE=Opus', 'ALBUMARTIST=AA'],
        coverImage: _back,
      ),
  'opus_long.opus': () => AudioTagFixtures.opus(
        comments: <String>['TITLE=Long'],
        preSkip: 3840,
        samples: 48000 * 61 + 7,
      ),
  'not_audio.mp3': () => AudioTagFixtures.mp3(title: 'X'),
  'empty.flac': () => Uint8List(0),
  'truncated.flac': () =>
      Uint8List.sublistView(AudioTagFixtures.flac(title: 'Cut'), 0, 20),
};

/// One line of cases.txt for [file]: what reading it gives, with `-` for an
/// absent field, or `NONE` when it isn't a file this reader handles.
String _line(String file, VorbisTagsInTheClear? read) {
  if (read == null) return '$file\tNONE';
  final LocalAudioMetadata tags =
      FilesystemLocalMetadataReader.vorbisMetadata(read.fields, read.duration);
  String field(Object? value) {
    final String text = value?.toString() ?? '-';
    if (text.contains('\t') || text.contains('\n')) {
      throw ArgumentError('a fixture value may not hold a tab or a newline');
    }
    return text;
  }

  final Uint8List? cover = read.cover;
  return <String>[
    file,
    field(tags.title),
    field(tags.artist),
    field(tags.albumArtist),
    field(tags.album),
    field(tags.trackNumber),
    field(tags.duration?.inMicroseconds),
    cover == null
        ? '-'
        : cover.map((int b) => b.toRadixString(16).padLeft(2, '0')).join(),
  ].join('\t');
}

const String _header = '''
# What reading each file in this folder gives. Replayed by
# test/core/sources/local/tag_shared_cases_test.dart (Dart) and
# native/linthra_core/src/tags/shared_cases_test.rs (Rust).
#
# TAB-separated: file, title, artist, album artist, album, track number,
# duration in microseconds, cover as hex. `-` is an absent field; a line of
# just `file<TAB>NONE` is a file the reader does not handle. Covers are read.
''';

void main() {
  final bool write = Platform.environment['LINTHRA_WRITE_TAG_FIXTURES'] == '1';

  test('the fixture files are what AudioTagFixtures builds', () async {
    final List<String> lines = <String>[];
    for (final MapEntry<String, Uint8List Function()> entry in _cases.entries) {
      final File file = File('$_dir/${entry.key}');
      final Uint8List bytes = entry.value();
      if (write) {
        file
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes, flush: true);
        lines.add(_line(
            entry.key, await VorbisTagsInTheClear.read(file, withCover: true)));
      } else {
        expect(file.readAsBytesSync(), bytes, reason: entry.key);
      }
    }
    if (write) {
      File('$_dir/cases.txt')
          .writeAsStringSync('$_header${lines.join('\n')}\n');
    }
  });

  test('the Dart reader gives what cases.txt says', () async {
    final List<String> expected = <String>[
      for (final String line in const LineSplitter()
          .convert(File('$_dir/cases.txt').readAsStringSync()))
        if (line.isNotEmpty && !line.startsWith('#')) line,
    ];
    expect(expected.length, _cases.length);
    for (final String line in expected) {
      final String file = line.split('\t').first;
      final VorbisTagsInTheClear? read =
          await VorbisTagsInTheClear.read(File('$_dir/$file'), withCover: true);
      expect(_line(file, read), line, reason: file);
    }
  });
}
