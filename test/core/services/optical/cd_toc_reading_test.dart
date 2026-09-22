import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_cd.dart';
import 'package:linthra/core/services/optical/cd_text_reading.dart';
import 'package:linthra/core/services/optical/cd_toc_reading.dart';
import 'package:linthra/core/services/optical/cdrom_toc_source.dart';

import 'cd_toc_fixtures.dart';

void main() {
  group('a standard audio CD', () {
    test('lists every track in disc order, with exact boundaries', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr0')!;

      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[1, 2, 3, 4, 5, 6, 7],
      );
      // Absolute positions: the LBA plus the 150-frame lead-in.
      expect(
        disc.tracks.map((AudioCdTrack track) => track.startFrame),
        <int>[150, 14109, 33586, 53077, 65781, 77892, 99174],
      );
      // Each track runs to the start of the next one …
      expect(
        disc.tracks.map((AudioCdTrack track) => track.frameCount),
        <int>[13959, 19477, 19491, 12704, 12111, 21282, 15400],
      );
      // … and every track ends exactly where the next one begins.
      for (int i = 1; i < disc.tracks.length; i++) {
        expect(disc.tracks[i - 1].endFrame, disc.tracks[i].startFrame);
      }
    });

    test('ends the last track at the lead-out', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr0')!;
      expect(disc.tracks.last.endFrame, 114424 + cdLeadInFrames);
    });

    test('totals to the playing time of the disc', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr0')!;
      expect(disc.totalFrames, 114424);
      // 114 424 frames at 75 a second is 25:25.653…
      expect(disc.totalDuration.inSeconds, 1525);
      expect(disc.totalDuration, framesToDuration(114424));
    });

    test('carries the drive it was read from', () {
      expect(
        audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr1')!.driveId,
        '/dev/sr1',
      );
    });
  });

  group('frame arithmetic', () {
    test('keeps 75 frames to the second exactly on a boundary', () {
      // A track one frame short of three minutes, and one frame over.
      const int threeMinutes = 3 * 60 * cdFramesPerSecond;
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, threeMinutes - 1),
            tocTrack(3, threeMinutes - 1 + threeMinutes),
          ],
          leadOutLba: threeMinutes - 1 + threeMinutes + threeMinutes + 1,
        ),
        driveId: '/dev/sr0',
      )!;

      expect(disc.tracks[0].frameCount, threeMinutes - 1);
      expect(disc.tracks[1].frameCount, threeMinutes);
      expect(disc.tracks[2].frameCount, threeMinutes + 1);

      expect(disc.tracks[1].duration, const Duration(minutes: 3));
      // One frame either side of three minutes is 1/75 s, not a rounding.
      expect(
        disc.tracks[0].duration,
        const Duration(minutes: 3) - framesToDuration(1),
      );
      expect(
        disc.tracks[2].duration,
        const Duration(minutes: 3) + framesToDuration(1),
      );
    });

    test('a track of exactly one frame is still a track', () {
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(2, 1)],
          leadOutLba: 100,
        ),
        driveId: '/dev/sr0',
      )!;
      expect(disc.tracks.first.frameCount, 1);
      expect(disc.tracks.first.duration.inMicroseconds, 13333);
    });
  });

  group('a one-track audio CD', () {
    test('runs from the first track to the lead-out', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(singleTrackCd(), driveId: '/dev/sr0')!;
      expect(disc.tracks, hasLength(1));
      expect(disc.tracks.single.number, 1);
      expect(disc.tracks.single.startFrame, cdLeadInFrames);
      expect(disc.tracks.single.frameCount, 20000);
      expect(disc.totalFrames, 20000);
    });
  });

  group('a multi-track audio CD with unusual numbering', () {
    test('keeps the disc\'s own track numbers', () {
      // Some discs (and many rips of them) start at a number other than 1.
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(4, 0),
            tocTrack(5, 1000),
            tocTrack(6, 2500),
          ],
          leadOutLba: 4000,
        ),
        driveId: '/dev/sr0',
      )!;
      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[4, 5, 6],
      );
      expect(
        disc.tracks.map((AudioCdTrack track) => track.frameCount),
        <int>[1000, 1500, 1500],
      );
    });

    test('sorts entries the drive reported out of order', () {
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(3, 2000),
            tocTrack(1, 0),
            tocTrack(2, 1000),
          ],
          firstTrack: 1,
          lastTrack: 3,
          leadOutLba: 3000,
        ),
        driveId: '/dev/sr0',
      )!;
      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[1, 2, 3],
      );
    });

    test('handles a full 99-track disc', () {
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            for (int number = 1; number <= 99; number++)
              tocTrack(number, (number - 1) * 4500),
          ],
          leadOutLba: 99 * 4500,
        ),
        driveId: '/dev/sr0',
      )!;
      expect(disc.tracks, hasLength(99));
      expect(disc.tracks.last.number, 99);
      expect(
        disc.tracks.every((AudioCdTrack track) => track.frameCount == 4500),
        isTrue,
      );
    });
  });

  group('mixed-mode discs', () {
    test('leaves a leading data track out of the playable tracks', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(mixedModeCd(), driveId: '/dev/sr0')!;
      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[2, 3, 4],
      );
      // The first audio track still starts where the data track ends: one
      // session, no gap.
      expect(disc.tracks.first.startFrame, 30000 + cdLeadInFrames);
      expect(
        disc.tracks.map((AudioCdTrack track) => track.frameCount),
        <int>[30000, 30000, 30000],
      );
      expect(disc.totalFrames, 90000);
    });

    test('stops the last audio track before a CD-Extra data session', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(sevenTrackCdExtra(), driveId: '/dev/sr0')!;

      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[1, 2, 3, 4, 5, 6, 7],
      );
      // Track 7 ends 11 400 frames before the data track starts, not at it:
      // the second session's run-out, lead-in and pre-gap are not music.
      expect(disc.tracks.last.frameCount, 126000 - cdXaInterval - 99024);
      expect(disc.tracks.last.endFrame, 126000 - cdXaInterval + cdLeadInFrames);
    });

    test('a CD-Extra is shorter than the naive reading of its TOC', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(sevenTrackCdExtra(), driveId: '/dev/sr0')!;
      final AudioCdDisc pureAudio =
          audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr0')!;
      // The naive reading would have made track 7 run to 126 000 — two and a
      // half minutes of silence longer than it is.
      expect(
        disc.tracks.last.frameCount,
        126000 - 99024 - cdXaInterval,
      );
      expect(disc.tracks.last.frameCount, 126000 - 99024 - 11400);
      expect(disc.tracks.last.frameCount, lessThan(126000 - 99024));
      expect(pureAudio.tracks.last.frameCount, 114424 - 99024);
    });

    test('a data track in the middle is dropped without shifting the rest', () {
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, 1000, data: true),
            tocTrack(3, 3000),
          ],
          leadOutLba: 5000,
        ),
        driveId: '/dev/sr0',
      )!;
      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[1, 3],
      );
      // Track 1 still ends where the data track starts: no session boundary,
      // so no XA interval.
      expect(disc.tracks.first.frameCount, 1000);
      expect(disc.tracks.last.frameCount, 2000);
    });

    test('a disc of nothing but data has no playable tracks', () {
      expect(
        audioCdDiscFrom(
          tocOf(
            tracks: <RawCdTocTrack>[
              tocTrack(1, 0, data: true),
              tocTrack(2, 30000, data: true),
            ],
            leadOutLba: 60000,
          ),
          driveId: '/dev/sr0',
        ),
        isNull,
      );
    });
  });

  group('malformed tables of contents', () {
    test('a lead-out sitting between two tracks is rejected', () {
      // The lead-out is the physical end of the disc, so a TOC that puts it
      // in the middle of its own track list describes a disc that cannot
      // exist. Checking it only against the *first* track would let this
      // through, and track 1 would then resolve to a 200-frame length on a
      // disc that ends at 100.
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(2, 200)],
            leadOutLba: 100,
          ),
        ),
        isNull,
      );
      expect(
        audioCdDiscFrom(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(2, 200)],
            leadOutLba: 100,
          ),
          driveId: '/dev/sr0',
        ),
        isNull,
      );
    });

    test('a lead-out exactly at the last track leaves it no length', () {
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(2, 1000)],
            leadOutLba: 1000,
          ),
        ),
        isNull,
      );
    });

    test('no track can ever resolve past the lead-out', () {
      // The property the check above exists to guarantee, asserted over a
      // handful of deliberately broken tables of contents rather than one.
      for (final RawCdToc toc in <RawCdToc>[
        tocOf(
          tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(2, 5000)],
          leadOutLba: 2500,
        ),
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, 1000),
            tocTrack(3, 90000),
          ],
          leadOutLba: 50000,
        ),
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, 30000, data: true),
          ],
          leadOutLba: 10000,
        ),
      ]) {
        final AudioCdDisc? disc = audioCdDiscFrom(toc, driveId: '/dev/sr0');
        if (disc == null) continue;
        for (final AudioCdTrack track in disc.tracks) {
          expect(
            track.endFrame,
            lessThanOrEqualTo(toc.leadOutLba + cdLeadInFrames),
            reason: 'track ${track.number} of $toc ends past the lead-out',
          );
        }
      }
    });

    test('a lead-out at or before the first track is not a disc', () {
      expect(
        normalizedTocEntries(
          tocOf(tracks: <RawCdTocTrack>[tocTrack(1, 5000)], leadOutLba: 5000),
        ),
        isNull,
      );
      expect(
        normalizedTocEntries(
          tocOf(tracks: <RawCdTocTrack>[tocTrack(1, 5000)], leadOutLba: 100),
        ),
        isNull,
      );
    });

    test('an inverted or out-of-range header is rejected', () {
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0)],
            firstTrack: 5,
            lastTrack: 2,
            leadOutLba: 1000,
          ),
        ),
        isNull,
      );
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0)],
            firstTrack: 0,
            lastTrack: 1,
            leadOutLba: 1000,
          ),
        ),
        isNull,
      );
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0)],
            firstTrack: 1,
            lastTrack: 100,
            leadOutLba: 1000,
          ),
        ),
        isNull,
      );
    });

    test('positions that go backwards are rejected rather than sorted', () {
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[
              tocTrack(1, 5000),
              tocTrack(2, 1000),
            ],
            leadOutLba: 9000,
          ),
        ),
        isNull,
      );
    });

    test('a repeated or out-of-range track number is rejected', () {
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(1, 1000)],
            firstTrack: 1,
            lastTrack: 2,
            leadOutLba: 2000,
          ),
        ),
        isNull,
      );
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(9, 1000)],
            firstTrack: 1,
            lastTrack: 2,
            leadOutLba: 2000,
          ),
        ),
        isNull,
      );
    });

    test('a track the header claims but no entry supplies is rejected', () {
      // Header covers 1-3, entries supply only 1 and 3. Accepting it would
      // make track 1 swallow track 2's running time on its way to track 3.
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(3, 20000)],
            firstTrack: 1,
            lastTrack: 3,
            leadOutLba: 30000,
          ),
        ),
        isNull,
      );
      expect(
        audioCdDiscFrom(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0), tocTrack(3, 20000)],
            firstTrack: 1,
            lastTrack: 3,
            leadOutLba: 30000,
          ),
          driveId: '/dev/sr0',
        ),
        isNull,
      );
    });

    test('a complete range is still accepted', () {
      // The check is "no gaps", not "starts at 1": a disc whose header runs
      // 4-6 and supplies 4, 5 and 6 is complete.
      expect(
        normalizedTocEntries(
          tocOf(
            tracks: <RawCdTocTrack>[
              tocTrack(4, 0),
              tocTrack(5, 1000),
              tocTrack(6, 2000),
            ],
            leadOutLba: 3000,
          ),
        ),
        hasLength(3),
      );
    });

    test('a negative position is rejected', () {
      expect(
        normalizedTocEntries(
          RawCdToc(
            firstTrack: 1,
            lastTrack: 1,
            leadOutLba: 1000,
            tracks: <RawCdTocTrack>[
              const RawCdTocTrack(number: 1, startLba: -1, control: 0),
            ],
          ),
        ),
        isNull,
      );
    });

    test('an empty table of contents is not a disc', () {
      expect(
        normalizedTocEntries(
          RawCdToc(
            firstTrack: 1,
            lastTrack: 1,
            leadOutLba: 1000,
            tracks: const <RawCdTocTrack>[],
          ),
        ),
        isNull,
      );
    });

    test('a zero-length track is dropped, not queued', () {
      // Two entries at the same position: a shape "copy-protected" discs use.
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, 1000),
            tocTrack(3, 1000),
          ],
          leadOutLba: 3000,
        ),
        driveId: '/dev/sr0',
      )!;
      expect(
        disc.tracks.map((AudioCdTrack track) => track.number),
        <int>[1, 3],
      );
      expect(
        disc.tracks.every((AudioCdTrack track) => track.frameCount > 0),
        isTrue,
      );
    });
  });

  group('metadata on the disc', () {
    Uint8List textOf(List<String> titles, List<String> performers) =>
        cdTextResponse(
          cdTextBlockOf(<List<Uint8List>>[
            cdTextPacksFor(type: cdTextTitlePackType, texts: titles),
            cdTextPacksFor(type: cdTextPerformerPackType, texts: performers),
          ]),
        );

    test('CD-Text names the disc and its tracks', () {
      final AudioCdDisc disc = audioCdDiscFrom(
        singleTrackCd(
          cdText: textOf(
            const <String>['Dummy', 'Roadhouse Blues'],
            const <String>['The Doors', 'The Doors'],
          ),
        ),
        driveId: '/dev/sr0',
      )!;

      expect(disc.title, 'Dummy');
      expect(disc.artist, 'The Doors');
      expect(disc.displayTitle, 'Dummy');
      expect(disc.tracks.single.title, 'Roadhouse Blues');
      expect(disc.tracks.single.artist, 'The Doors');
      expect(disc.tracks.single.displayTitle, 'Roadhouse Blues');
    });

    test('a disc with no CD-Text falls back, track by track', () {
      final AudioCdDisc disc =
          audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr0')!;

      expect(disc.title, isNull);
      expect(disc.artist, isNull);
      expect(disc.displayTitle, 'Audio CD');
      expect(
        disc.tracks.map((AudioCdTrack track) => track.title),
        everyElement(isNull),
      );
      expect(
        disc.tracks.map((AudioCdTrack track) => track.displayTitle),
        <String>[
          'Track 01',
          'Track 02',
          'Track 03',
          'Track 04',
          'Track 05',
          'Track 06',
          'Track 07',
        ],
      );
    });

    test('partial CD-Text names only what the disc named', () {
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, 10000),
            tocTrack(3, 20000),
          ],
          leadOutLba: 30000,
          cdText: cdTextResponse(
            cdTextBlockOf(<List<Uint8List>>[
              cdTextPacksFor(
                type: cdTextTitlePackType,
                texts: const <String>['Disc', 'Named', '', 'Also Named'],
              ),
            ]),
          ),
        ),
        driveId: '/dev/sr0',
      )!;

      expect(disc.tracks[0].displayTitle, 'Named');
      // The disc left track 2 blank; nothing is invented for it.
      expect(disc.tracks[1].title, isNull);
      expect(disc.tracks[1].displayTitle, 'Track 02');
      expect(disc.tracks[2].displayTitle, 'Also Named');
      expect(disc.artist, isNull);
    });

    test('malformed CD-Text falls back rather than half-naming the disc', () {
      final List<Uint8List> packs = cdTextBlockWithCrcOf(<List<Uint8List>>[
        cdTextPacksFor(
          type: cdTextTitlePackType,
          texts: const <String>['Disc', 'One', 'Two', 'Three', 'Four'],
        ),
      ]);
      packs[1][17] ^= 0xff;

      final AudioCdDisc disc = audioCdDiscFrom(
        singleTrackCd(cdText: cdTextResponse(packs)),
        driveId: '/dev/sr0',
      )!;

      expect(disc.title, isNull);
      expect(disc.displayTitle, 'Audio CD');
      expect(disc.tracks.single.displayTitle, 'Track 01');
    });

    test('CD-Text follows the disc\'s own track numbers', () {
      // Track 1 is data and is not playable, so the CD-Text for it belongs to
      // nothing — and track 2\'s title must not slide onto track 1\'s row.
      final AudioCdDisc disc = audioCdDiscFrom(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0, data: true),
            tocTrack(2, 30000),
            tocTrack(3, 60000),
          ],
          leadOutLba: 90000,
          cdText: cdTextResponse(
            cdTextBlockOf(<List<Uint8List>>[
              cdTextPacksFor(
                type: cdTextTitlePackType,
                texts: const <String>['Game', 'Data', 'Theme', 'Credits'],
              ),
            ]),
          ),
        ),
        driveId: '/dev/sr0',
      )!;

      expect(disc.title, 'Game');
      expect(
          disc.tracks.map((AudioCdTrack track) => track.number), <int>[2, 3]);
      expect(disc.tracks[0].title, 'Theme');
      expect(disc.tracks[1].title, 'Credits');
    });

    test('the disc identity is unaffected by its CD-Text', () {
      // Two pressings that differ only in whether they carry titles are the
      // same disc geometrically, and hash the same.
      expect(
        audioCdDiscFrom(sevenTrackAudioCd(), driveId: '/dev/sr0')!.discId,
        audioCdDiscFrom(
          sevenTrackAudioCd(
            cdText: textOf(const <String>['Named'], const <String>['Someone']),
          ),
          driveId: '/dev/sr1',
        )!
            .discId,
      );
    });
  });
}
