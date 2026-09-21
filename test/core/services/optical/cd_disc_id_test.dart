import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/optical/cd_disc_id.dart';
import 'package:linthra/core/services/optical/cd_text_reading.dart';
import 'package:linthra/core/services/optical/cdrom_toc_source.dart';

import 'cd_toc_fixtures.dart';

void main() {
  group('musicBrainzDiscId', () {
    // These are not values Linthra produced and then wrote down. They were
    // computed independently from the published algorithm — SHA-1 over the
    // 804-character offset string, base64 with `+/=` replaced by `._-` — for
    // the same tables of contents the fixtures describe. If the implementation
    // drifts, these stop matching.
    const String sevenTrackId = 'BPnh1KU.hea1C.KMYWLGZkHJr0w-';
    const String cdExtraId = 'tDrTYy4YhXEZj7LhpqMlQ9nWCLw-';
    const String singleTrackId = 'S1R8m7NkNZAi9vPRtZeFFFutF28-';
    const String mixedModeId = 'RRp6TV6jHlT827YErEvefHF0Jwg-';

    test('matches the standard value for a plain audio CD', () {
      expect(musicBrainzDiscId(sevenTrackAudioCd()), sevenTrackId);
    });

    test('matches the standard value for a one-track disc', () {
      expect(musicBrainzDiscId(singleTrackCd()), singleTrackId);
    });

    test('matches the standard value for a mixed-mode disc', () {
      expect(musicBrainzDiscId(mixedModeCd()), mixedModeId);
    });

    test('uses the audio session\'s lead-out on a CD-Extra', () {
      // The data track's start minus the XA interval stands in for the
      // lead-out, so a CD-Extra does not hash as if its data session were
      // music.
      expect(musicBrainzDiscId(sevenTrackCdExtra()), cdExtraId);
      expect(musicBrainzDiscId(sevenTrackCdExtra()),
          isNot(musicBrainzDiscId(sevenTrackAudioCd())));
    });

    test('is 28 URL-safe characters', () {
      final String id = musicBrainzDiscId(sevenTrackAudioCd())!;
      expect(id, hasLength(28));
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id), isTrue);
      expect(id.contains('+'), isFalse);
      expect(id.contains('/'), isFalse);
      expect(id.contains('='), isFalse);
    });

    test('is stable however the drive happened to report the TOC', () {
      // Same disc, entries reported in a different order: the identifier is a
      // property of the disc, not of the read.
      final String shuffled = musicBrainzDiscId(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(7, 99024),
            tocTrack(1, 0),
            tocTrack(5, 65631),
            tocTrack(3, 33436),
            tocTrack(2, 13959),
            tocTrack(6, 77742),
            tocTrack(4, 52927),
          ],
          firstTrack: 1,
          lastTrack: 7,
          leadOutLba: 114424,
        ),
      )!;
      expect(shuffled, sevenTrackId);
    });

    test('changes when the disc does', () {
      final String original = musicBrainzDiscId(sevenTrackAudioCd())!;
      // One track a single frame longer is a different disc.
      final String shifted = musicBrainzDiscId(
        tocOf(
          tracks: <RawCdTocTrack>[
            tocTrack(1, 0),
            tocTrack(2, 13960),
            tocTrack(3, 33436),
            tocTrack(4, 52927),
            tocTrack(5, 65631),
            tocTrack(6, 77742),
            tocTrack(7, 99024),
          ],
          leadOutLba: 114424,
        ),
      )!;
      expect(shifted, isNot(original));
    });

    test('does not depend on what the disc calls itself', () {
      // The identifier is computed from the TOC alone: no device node, and no
      // CD-Text either, so two pressings that differ only in their titles are
      // the same disc.
      expect(
        musicBrainzDiscId(
          sevenTrackAudioCd(
            cdText: cdTextResponse(
              cdTextBlockOf(<List<Uint8List>>[
                cdTextPacksFor(
                  type: cdTextTitlePackType,
                  texts: const <String>['A Title'],
                ),
              ]),
            ),
          ),
        ),
        sevenTrackId,
      );
    });

    test('is absent for a table of contents that is not a disc', () {
      expect(
        musicBrainzDiscId(
          tocOf(tracks: <RawCdTocTrack>[tocTrack(1, 5000)], leadOutLba: 100),
        ),
        isNull,
      );
      expect(
        musicBrainzDiscId(
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

    test('is absent for a disc with no audio at all', () {
      expect(
        musicBrainzDiscId(
          tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0, data: true)],
            leadOutLba: 60000,
          ),
        ),
        isNull,
      );
    });

    test(
        'is absent when the audio session\'s lead-out lands before the last '
        'track', () {
      // A data track too close behind the last audio track: the TOC
      // contradicts itself, and inventing an identity for it would be worse
      // than having none.
      expect(
        musicBrainzDiscId(
          tocOf(
            tracks: <RawCdTocTrack>[
              tocTrack(1, 0),
              tocTrack(2, 100000),
              tocTrack(3, 101000, data: true),
            ],
            leadOutLba: 150000,
          ),
        ),
        isNull,
      );
    });
  });
}
