import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_cd.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/optical/cd_disc_id.dart';
import 'package:linthra/core/services/optical/cd_text_reading.dart';
import 'package:linthra/core/services/optical/cd_toc_reading.dart';
import 'package:linthra/core/services/optical/cdrom_toc_source.dart';

import 'cd_toc_fixtures.dart';

/// The Rust CD decoding has to give exactly what the Dart rules give: the
/// same tracks, the same disc id, and the same CD-Text, refused in the same
/// cases. A drift names a disc after the wrong release or a track after the
/// wrong song.
///
/// Runs through the real Rust library hook/build.dart builds for the test
/// host, and is skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead).
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  group('native optical decoding', skip: skip, () {
    test('matches Dart on the fixture discs', () {
      for (final RawCdToc toc in <RawCdToc>[
        sevenTrackAudioCd(),
        sevenTrackCdExtra(),
        mixedModeCd(),
        singleTrackCd(),
      ]) {
        _expectSameToc(toc);
      }
    });

    test('matches Dart on random tables of contents', () {
      final Random random = Random(3);
      int identified = 0;
      for (int i = 0; i < 5000; i++) {
        final RawCdToc toc = _randomToc(random);
        _expectSameToc(toc);
        if (musicBrainzDiscIdInDart(toc) != null) identified++;
      }
      // Enough valid discs that the ids are really compared.
      expect(identified, greaterThan(500));
    });

    test('matches Dart on random CD-Text', () {
      final Random random = Random(5);
      int decoded = 0;
      for (int i = 0; i < 5000; i++) {
        final Uint8List response = _randomCdText(random);
        final CdTextMetadata dart = cdTextFromInDart(response);
        expect(cdTextFrom(response), dart, reason: '$response');
        if (!dart.isEmpty) decoded++;
      }
      expect(decoded, greaterThan(500));
      expect(cdTextFrom(null), cdTextFromInDart(null));
    });
  });
}

void _expectSameToc(RawCdToc toc) {
  final List<RawCdTocTrack>? dartEntries = normalizedTocEntriesInDart(toc);
  expect(normalizedTocEntries(toc), dartEntries, reason: '$toc');
  expect(musicBrainzDiscId(toc), musicBrainzDiscIdInDart(toc), reason: '$toc');
  if (dartEntries != null) {
    expect(
      _describe(playableAudioTracks(dartEntries, toc.leadOutLba)),
      _describe(playableAudioTracksInDart(dartEntries, toc.leadOutLba)),
      reason: '$toc',
    );
  }
}

List<String> _describe(List<AudioCdTrack> tracks) => <String>[
      for (final AudioCdTrack t in tracks)
        '${t.number} ${t.startFrame} ${t.frameCount}',
    ];

/// Mostly plausible discs (so many get an id), with the faults the decoder
/// refuses mixed in: gaps, duplicates, backwards starts, negative positions,
/// a lead-out too early, data tracks anywhere.
RawCdToc _randomToc(Random random) {
  final int first = random.nextInt(10) == 0 ? random.nextInt(3) : 1;
  final int count = 1 + random.nextInt(12);
  int lba = random.nextInt(4) == 0 ? 0 : random.nextInt(300);
  final List<RawCdTocTrack> tracks = <RawCdTocTrack>[];
  for (int k = 0; k < count; k++) {
    final int number =
        random.nextInt(25) == 0 ? first + random.nextInt(count + 1) : first + k;
    tracks.add(tocTrack(
      number,
      random.nextInt(40) == 0 ? -random.nextInt(100) : lba,
      data: random.nextInt(6) == 0,
    ));
    lba += random.nextInt(20) == 0 ? -500 : 1000 + random.nextInt(30000);
  }
  if (random.nextInt(10) == 0) tracks.shuffle(random);
  return RawCdToc(
    firstTrack: first,
    lastTrack: random.nextInt(15) == 0 ? first + count : first + count - 1,
    leadOutLba: random.nextInt(15) == 0 ? lba - 20000 : lba + 12000,
    tracks: tracks,
  );
}

/// Valid title and performer packs most of the time, then broken in one of
/// the ways the decoder refuses: a bad CRC, a skipped or repeated sequence
/// number, a wrong item byte, another block, double-byte text, a charset it
/// does not read, a truncated length.
Uint8List _randomCdText(Random random) {
  const List<String> words = <String>[
    'Album',
    'Café del Mar',
    '\t',
    '',
    '  padded  ',
    'Señor\u00A0X',
    '\u00A0edge\u0085',
    '\u0085',
    ' \u000Bvt ',
    'Ünïcödé',
    'A very long title that spans packs',
  ];
  final int tracks = random.nextInt(5);
  final List<String> titles = <String>[
    for (int t = 0; t <= tracks; t++) words[random.nextInt(words.length)],
  ];
  final List<String> performers = <String>[
    for (int t = 0; t <= tracks; t++) words[random.nextInt(words.length)],
  ];
  final bool withCrc = random.nextBool();
  final List<List<Uint8List>> groups = <List<Uint8List>>[
    cdTextPacksFor(type: cdTextTitlePackType, texts: titles, withCrc: withCrc),
    cdTextPacksFor(
      type: cdTextPerformerPackType,
      texts: performers,
      withCrc: withCrc,
    ),
    if (random.nextBool())
      cdTextBlockSizePacks(
        charset: <int>[0x00, 0x01, 0x80][random.nextInt(3)],
        lastTrack: tracks.clamp(1, 99),
      ),
  ];
  List<Uint8List> packs =
      withCrc ? cdTextBlockWithCrcOf(groups) : cdTextBlockOf(groups);
  packs = <Uint8List>[for (final Uint8List p in packs) Uint8List.fromList(p)];
  if (packs.isNotEmpty && random.nextInt(4) == 0) {
    final Uint8List pack = packs[random.nextInt(packs.length)];
    switch (random.nextInt(6)) {
      case 0:
        pack[17] ^= 0x01; // a CRC that no longer matches (or a new one)
      case 1:
        pack[2] = (pack[2] + 1) & 0xff; // a sequence gap or repeat
      case 2:
        pack[1] = (pack[1] + 1) & 0xff; // the wrong item
      case 3:
        pack[3] |= 0x10; // another block
      case 4:
        pack[3] |= 0x80; // double-byte text
      default:
        pack[3] = (pack[3] & 0xf0) | random.nextInt(16); // character position
    }
  }
  final Uint8List response = cdTextResponse(
    packs,
    declaredLength: random.nextInt(8) == 0 ? random.nextInt(400) : null,
  );
  return random.nextInt(10) == 0
      ? Uint8List.sublistView(response, 0, random.nextInt(response.length + 1))
      : response;
}
