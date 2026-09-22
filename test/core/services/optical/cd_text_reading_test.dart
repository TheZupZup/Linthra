import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/optical/cd_text_reading.dart';

import 'cd_toc_fixtures.dart';

void main() {
  group('no CD-Text', () {
    test('an absent response is empty, not an error', () {
      expect(cdTextFrom(null), CdTextMetadata.empty);
      expect(cdTextFrom(null).isEmpty, isTrue);
    });

    test('a header-only response is empty', () {
      expect(cdTextFrom(cdTextResponse(const <Uint8List>[])),
          CdTextMetadata.empty);
      expect(cdTextFrom(Uint8List.fromList(const <int>[0, 2, 0, 0])),
          CdTextMetadata.empty);
    });

    test('a response too short to hold a header is empty', () {
      expect(cdTextFrom(Uint8List.fromList(const <int>[0, 2])),
          CdTextMetadata.empty);
    });
  });

  group('CD-Text present', () {
    Uint8List discAndTracks({bool withCrc = false}) {
      final List<List<Uint8List>> groups = <List<Uint8List>>[
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>[
            'Ágætis byrjun',
            'Svefn-g-englar',
            'Starálfur',
            'Flugufrelsarinn',
          ],
        ),
        cdTextPacksFor(
          type: cdTextPerformerPackType,
          texts: const <String>[
            'Sigur Rós',
            'Sigur Rós',
            'Sigur Rós',
            'Sigur Rós',
          ],
        ),
      ];
      return cdTextResponse(
        withCrc ? cdTextBlockWithCrcOf(groups) : cdTextBlockOf(groups),
      );
    }

    test('reads the disc title and performer', () {
      final CdTextMetadata text = cdTextFrom(discAndTracks());
      expect(text.discTitle, 'Ágætis byrjun');
      expect(text.discPerformer, 'Sigur Rós');
      expect(text.isEmpty, isFalse);
    });

    test('reads every track title and performer, by track number', () {
      final CdTextMetadata text = cdTextFrom(discAndTracks());
      expect(text.trackTitles, <int, String>{
        1: 'Svefn-g-englar',
        2: 'Starálfur',
        3: 'Flugufrelsarinn',
      });
      expect(text.trackPerformers, <int, String>{
        1: 'Sigur Rós',
        2: 'Sigur Rós',
        3: 'Sigur Rós',
      });
    });

    test('keeps the disc out of the track maps', () {
      final CdTextMetadata text = cdTextFrom(discAndTracks());
      expect(text.trackTitles.containsKey(0), isFalse);
      expect(text.trackPerformers.containsKey(0), isFalse);
    });

    test('non-ASCII Latin text survives intact', () {
      // ISO-8859-1 is the default character code, and it is what the accented
      // characters above are encoded in.
      final CdTextMetadata text = cdTextFrom(discAndTracks());
      expect(text.discTitle, contains('Á'));
      expect(text.discPerformer, endsWith('Rós'));
      expect(text.trackTitles[2], 'Starálfur');
    });

    test('a title spanning several packs is rejoined', () {
      // Far longer than the twelve bytes one pack carries.
      const String long =
          'A Song Whose Title Runs Well Past One Pack Of Twelve Bytes';
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextPacksFor(
            type: cdTextTitlePackType,
            texts: const <String>['Disc', long],
          ),
        ),
      );
      expect(text.discTitle, 'Disc');
      expect(text.trackTitles[1], long);
    });

    test('a correct CRC is accepted', () {
      final CdTextMetadata text = cdTextFrom(discAndTracks(withCrc: true));
      expect(text.discTitle, 'Ágætis byrjun');
      expect(text.trackTitles[1], 'Svefn-g-englar');
    });

    test('an explicit ASCII character code is honoured', () {
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextBlockOf(<List<Uint8List>>[
            cdTextBlockSizePacks(charset: 0x01, lastTrack: 1),
            cdTextPacksFor(
              type: cdTextTitlePackType,
              texts: const <String>['Plain', 'Ascii'],
            ),
          ]),
        ),
      );
      expect(text.discTitle, 'Plain');
      expect(text.trackTitles[1], 'Ascii');
    });

    test('the TAB repeat marker repeats the previous performer', () {
      // How a single-artist album avoids spending a pack per track.
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextPacksFor(
            type: cdTextPerformerPackType,
            texts: const <String>['Beth Gibbons', '\t', '\t', '\t'],
          ),
        ),
      );
      expect(text.discPerformer, 'Beth Gibbons');
      expect(text.trackPerformers, <int, String>{
        1: 'Beth Gibbons',
        2: 'Beth Gibbons',
        3: 'Beth Gibbons',
      });
    });
  });

  group('partial CD-Text', () {
    test('titles without performers are a partial answer, not a failure', () {
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextPacksFor(
            type: cdTextTitlePackType,
            texts: const <String>['Disc', 'One', 'Two'],
          ),
        ),
      );
      expect(text.discTitle, 'Disc');
      expect(text.trackTitles, <int, String>{1: 'One', 2: 'Two'});
      expect(text.discPerformer, isNull);
      expect(text.trackPerformers, isEmpty);
    });

    test('a track the disc left blank simply has no title', () {
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextPacksFor(
            type: cdTextTitlePackType,
            texts: const <String>['Disc', 'One', '', 'Three'],
          ),
        ),
      );
      expect(text.trackTitles, <int, String>{1: 'One', 3: 'Three'});
      expect(text.trackTitles.containsKey(2), isFalse);
    });

    test('tracks named without a disc title keep their numbers', () {
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextPacksFor(
            type: cdTextTitlePackType,
            texts: const <String>['One', 'Two'],
            startItem: 1,
          ),
        ),
      );
      expect(text.discTitle, isNull);
      expect(text.trackTitles, <int, String>{1: 'One', 2: 'Two'});
    });

    test('an unterminated trailing string is dropped', () {
      // Half a title is not a title.
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(<Uint8List>[
          cdTextPack(
            type: cdTextTitlePackType,
            item: 0,
            sequence: 0,
            // Exactly twelve bytes, so nothing zero-pads the tail: the
            // second string is never terminated.
            payload: 'Disc\u0000Truncat'.codeUnits,
          ),
        ]),
      );
      expect(text.discTitle, 'Disc');
      expect(text.trackTitles, isEmpty);
    });
  });

  group('malformed CD-Text falls back rather than guessing', () {
    test('a byte count that is not a whole number of packs is rejected', () {
      final Uint8List good = cdTextResponse(
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>['Disc', 'One'],
        ),
      );
      final Uint8List ragged = Uint8List.fromList(
        <int>[...good, 0x80, 0x01, 0x02],
      );
      // The header still claims the original length, so the extra bytes are
      // ignored; lengthening the claim makes the payload ragged.
      ragged[0] = ((ragged.length - 2) >> 8) & 0xff;
      ragged[1] = (ragged.length - 2) & 0xff;
      expect(cdTextFrom(ragged), CdTextMetadata.empty);
    });

    test('a wrong CRC is rejected', () {
      final List<Uint8List> packs = cdTextBlockWithCrcOf(<List<Uint8List>>[
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>['Disc', 'One', 'Two', 'Three', 'Four'],
        ),
      ]);
      expect(packs.length, greaterThan(1));
      packs[1][17] ^= 0xff;
      expect(cdTextFrom(cdTextResponse(packs)), CdTextMetadata.empty);
    });

    test('a gap in the sequence numbers is rejected', () {
      // A missing pack silently joins the end of one title to the start of
      // another, which is worse than no CD-Text at all.
      final List<Uint8List> packs = cdTextBlockOf(<List<Uint8List>>[
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>['Disc', 'One', 'Two', 'Three', 'Five', 'Six'],
        ),
      ]);
      expect(packs.length, greaterThan(2));
      packs.removeAt(1);
      expect(cdTextFrom(cdTextResponse(packs)), CdTextMetadata.empty);
    });

    test('a pack whose item byte contradicts the stream is refused', () {
      // The pack header and the NUL count each say which item the pack starts
      // inside. When they disagree, believing the count would put a real
      // title on the wrong track — worse than showing `Track 02`.
      final List<Uint8List> packs = cdTextBlockOf(<List<Uint8List>>[
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>['Disc', 'One', 'Two', 'Three', 'Four'],
        ),
      ]);
      expect(packs.length, greaterThan(1));
      // Claim the second pack starts inside a different item than it does.
      packs[1][1] = (packs[1][1] + 7) & 0x7f;
      expect(cdTextFrom(cdTextResponse(packs)), CdTextMetadata.empty);
    });

    test('a contradiction in one pack type costs the disc both', () {
      // All or nothing: a half-decoded answer is exactly the plausible-but-
      // wrong metadata this decoder exists to refuse.
      final List<Uint8List> packs = cdTextBlockOf(<List<Uint8List>>[
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>['Disc', 'One', 'Two', 'Three', 'Four'],
        ),
        cdTextPacksFor(
          type: cdTextPerformerPackType,
          texts: const <String>['Someone', 'Someone', 'Someone'],
        ),
      ]);
      final int firstPerformer = packs.indexWhere(
        (Uint8List pack) => pack[0] == cdTextPerformerPackType,
      );
      expect(firstPerformer, greaterThan(0));
      packs[1][1] = (packs[1][1] + 7) & 0x7f;

      final CdTextMetadata text = cdTextFrom(cdTextResponse(packs));
      expect(text, CdTextMetadata.empty);
      expect(text.discPerformer, isNull);
    });

    test('double-byte text is refused rather than rendered as mojibake', () {
      expect(
        cdTextFrom(
          cdTextResponse(<Uint8List>[
            cdTextPack(
              type: cdTextTitlePackType,
              item: 0,
              sequence: 0,
              payload: const <int>[0x82, 0xa0, 0x82, 0xa2, 0x00, 0x00],
              doubleByte: true,
            ),
          ]),
        ),
        CdTextMetadata.empty,
      );
    });

    test('an MS-JIS character code is refused', () {
      expect(
        cdTextFrom(
          cdTextResponse(
            cdTextBlockOf(<List<Uint8List>>[
              cdTextBlockSizePacks(charset: 0x80),
              cdTextPacksFor(
                type: cdTextTitlePackType,
                texts: const <String>['Disc'],
              ),
            ]),
          ),
        ),
        CdTextMetadata.empty,
      );
    });

    test('high bytes in a block that declared ASCII are dropped', () {
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(
          cdTextBlockOf(<List<Uint8List>>[
            cdTextBlockSizePacks(charset: 0x01),
            <Uint8List>[
              cdTextPack(
                type: cdTextTitlePackType,
                item: 0,
                sequence: 0,
                payload: const <int>[0xc3, 0xa9, 0x00, 0x00],
              ),
            ],
          ]),
        ),
      );
      expect(text.discTitle, isNull);
    });

    test('an absurd pack count is refused', () {
      expect(
        cdTextFrom(Uint8List.fromList(<int>[0xff, 0xff, 0, 0])),
        CdTextMetadata.empty,
      );
    });
  });

  group('only the primary language block is read', () {
    test('a second block does not leak into the first', () {
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(<Uint8List>[
          ...cdTextBlockOf(<List<Uint8List>>[
            cdTextPacksFor(
              type: cdTextTitlePackType,
              texts: const <String>['English Disc', 'English One'],
            ),
          ]),
          ...cdTextBlockOf(<List<Uint8List>>[
            cdTextPacksFor(
              type: cdTextTitlePackType,
              texts: const <String>['Deutsche CD', 'Deutsch Eins'],
              block: 1,
            ),
          ]),
        ]),
      );
      expect(text.discTitle, 'English Disc');
      expect(text.trackTitles[1], 'English One');
    });

    test('a corrupt second block does not cost the first its titles', () {
      final List<Uint8List> other = cdTextPacksFor(
        type: cdTextTitlePackType,
        texts: const <String>['Deutsche CD'],
        block: 1,
        withCrc: true,
      );
      other[0][17] ^= 0xff;
      final CdTextMetadata text = cdTextFrom(
        cdTextResponse(<Uint8List>[
          ...cdTextPacksFor(
            type: cdTextTitlePackType,
            texts: const <String>['English Disc'],
            withCrc: true,
          ),
          ...other,
        ]),
      );
      expect(text.discTitle, 'English Disc');
    });
  });

  group('cdTextPackCrc', () {
    test('matches a value computed from the published algorithm', () {
      // CRC-16/CCITT over the first sixteen bytes, inverted. Computed
      // independently for this pack.
      final Uint8List pack = Uint8List.fromList(<int>[
        0x80, 0x00, 0x00, 0x00, //
        ...'Linthra Live'.codeUnits,
        0x00, 0x00,
      ]);
      expect(cdTextPackCrc(pack), 0x3249);
    });
  });

  group('CdTextMetadata', () {
    test('is value-equal', () {
      const CdTextMetadata a = CdTextMetadata(
        discTitle: 'Disc',
        trackTitles: <int, String>{1: 'One'},
      );
      const CdTextMetadata b = CdTextMetadata(
        discTitle: 'Disc',
        trackTitles: <int, String>{1: 'One'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(CdTextMetadata.empty));
    });

    test('hashes the same however its maps were built', () {
      // `mapEquals` ignores insertion order, so the hash has to as well —
      // otherwise two equal values land in different buckets and a HashSet
      // holds both of them.
      const CdTextMetadata forwards = CdTextMetadata(
        trackTitles: <int, String>{1: 'One', 2: 'Two', 3: 'Three'},
        trackPerformers: <int, String>{1: 'A', 2: 'B'},
      );
      const CdTextMetadata backwards = CdTextMetadata(
        trackTitles: <int, String>{3: 'Three', 2: 'Two', 1: 'One'},
        trackPerformers: <int, String>{2: 'B', 1: 'A'},
      );

      expect(forwards, backwards);
      expect(forwards.hashCode, backwards.hashCode);
      expect(<CdTextMetadata>{forwards, backwards}, hasLength(1));
    });
  });
}
