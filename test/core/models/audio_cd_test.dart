import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_cd.dart';

void main() {
  group('framesToDuration', () {
    test('is exact on whole seconds', () {
      expect(framesToDuration(0), Duration.zero);
      expect(framesToDuration(cdFramesPerSecond), const Duration(seconds: 1));
      expect(
        framesToDuration(cdFramesPerSecond * 60),
        const Duration(minutes: 1),
      );
      expect(
        framesToDuration(cdFramesPerSecond * 3600),
        const Duration(hours: 1),
      );
    });

    test('is exact on every multiple of three frames', () {
      // One frame is 40 000/3 µs, so only these land on a microsecond.
      for (int frames = 0; frames <= 300; frames += 3) {
        expect(
          framesToDuration(frames).inMicroseconds * 3,
          frames * 40000,
          reason: '$frames frames should be exact',
        );
      }
    });

    test('rounds the other two thirds to the nearest microsecond', () {
      // 1 frame = 13 333.33… µs, 2 frames = 26 666.66… µs.
      expect(framesToDuration(1), const Duration(microseconds: 13333));
      expect(framesToDuration(2), const Duration(microseconds: 26667));
    });

    test('never drifts across a long disc', () {
      // 74 minutes of frames: the rounding is applied once, on the way out,
      // so the answer is still the exact duration.
      const int frames = 74 * 60 * cdFramesPerSecond;
      expect(framesToDuration(frames), const Duration(minutes: 74));
    });
  });

  group('AudioCdTrack', () {
    test('derives its end and duration from its frames', () {
      const AudioCdTrack track = AudioCdTrack(
        number: 3,
        startFrame: 33586,
        frameCount: 19491,
      );
      expect(track.endFrame, 53077);
      expect(track.duration, framesToDuration(19491));
      expect(track.duration.inSeconds, 259); // 4:19
    });

    test('falls back to a two-digit track title when CD-Text is absent', () {
      expect(
        const AudioCdTrack(number: 1, startFrame: 150, frameCount: 100)
            .displayTitle,
        'Track 01',
      );
      expect(
        const AudioCdTrack(number: 9, startFrame: 150, frameCount: 100)
            .displayTitle,
        'Track 09',
      );
      expect(
        const AudioCdTrack(number: 12, startFrame: 150, frameCount: 100)
            .displayTitle,
        'Track 12',
      );
    });

    test('prefers the disc\'s own title when it has one', () {
      const AudioCdTrack track = AudioCdTrack(
        number: 1,
        startFrame: 150,
        frameCount: 100,
        title: 'Svefn-g-englar',
        artist: 'Sigur Rós',
      );
      expect(track.displayTitle, 'Svefn-g-englar');
      expect(track.artist, 'Sigur Rós');
    });

    test('is value-equal', () {
      const AudioCdTrack a =
          AudioCdTrack(number: 1, startFrame: 150, frameCount: 100);
      const AudioCdTrack b =
          AudioCdTrack(number: 1, startFrame: 150, frameCount: 100);
      const AudioCdTrack c =
          AudioCdTrack(number: 1, startFrame: 150, frameCount: 101);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('AudioCdDisc', () {
    AudioCdDisc discOf(List<int> lengths) => AudioCdDisc(
          driveId: '/dev/sr0',
          tracks: <AudioCdTrack>[
            for (int i = 0; i < lengths.length; i++)
              AudioCdTrack(
                number: i + 1,
                startFrame: 150 + i * 1000,
                frameCount: lengths[i],
              ),
          ],
        );

    test('totals the playable tracks, in frames', () {
      final AudioCdDisc disc = discOf(<int>[100, 200, 300]);
      expect(disc.totalFrames, 600);
      expect(disc.totalDuration, framesToDuration(600));
    });

    test('falls back to "Audio CD" when the disc names itself nothing', () {
      expect(discOf(<int>[100]).displayTitle, 'Audio CD');
      expect(
        AudioCdDisc(
          driveId: '/dev/sr0',
          title: 'Ágætis byrjun',
          tracks: const <AudioCdTrack>[
            AudioCdTrack(number: 1, startFrame: 150, frameCount: 100),
          ],
        ).displayTitle,
        'Ágætis byrjun',
      );
    });

    test('cannot be rewritten through the list it was built from', () {
      final List<AudioCdTrack> tracks = <AudioCdTrack>[
        const AudioCdTrack(number: 1, startFrame: 150, frameCount: 100),
      ];
      final AudioCdDisc disc = AudioCdDisc(driveId: '/dev/sr0', tracks: tracks);
      tracks.add(
        const AudioCdTrack(number: 2, startFrame: 250, frameCount: 100),
      );
      expect(disc.tracks, hasLength(1));
      expect(
        () => disc.tracks.add(
          const AudioCdTrack(number: 3, startFrame: 350, frameCount: 100),
        ),
        throwsUnsupportedError,
      );
    });

    test('is value-equal, drive and identity included', () {
      expect(discOf(<int>[100, 200]), discOf(<int>[100, 200]));
      expect(
        discOf(<int>[100, 200]).hashCode,
        discOf(<int>[100, 200]).hashCode,
      );
      expect(discOf(<int>[100, 200]), isNot(discOf(<int>[100, 201])));
      expect(
        AudioCdDisc(
          driveId: '/dev/sr0',
          discId: 'aaa',
          tracks: discOf(<int>[100]).tracks,
        ),
        isNot(
          AudioCdDisc(
            driveId: '/dev/sr1',
            discId: 'aaa',
            tracks: discOf(<int>[100]).tracks,
          ),
        ),
      );
    });
  });

  group('AudioCdInspection', () {
    test('carries a disc only on success', () {
      final AudioCdDisc disc = AudioCdDisc(
        driveId: '/dev/sr0',
        tracks: const <AudioCdTrack>[
          AudioCdTrack(number: 1, startFrame: 150, frameCount: 100),
        ],
      );
      expect(AudioCdInspection.success(disc).disc, disc);
      expect(AudioCdInspection.success(disc).isSuccess, isTrue);
      for (final AudioCdInspection failure in <AudioCdInspection>[
        const AudioCdInspection.noDisc(),
        const AudioCdInspection.notAudioCd(),
        const AudioCdInspection.discChanged(),
        const AudioCdInspection.unreadable(),
        const AudioCdInspection.driveUnavailable(),
        const AudioCdInspection.permissionDenied(),
        const AudioCdInspection.unsupported(),
      ]) {
        expect(failure.disc, isNull, reason: '${failure.status}');
        expect(failure.isSuccess, isFalse);
      }
    });

    test('keeps every failure distinct', () {
      expect(
        const AudioCdInspection.noDisc(),
        isNot(const AudioCdInspection.unreadable()),
      );
      expect(
        const AudioCdInspection.discChanged(),
        isNot(const AudioCdInspection.driveUnavailable()),
      );
      expect(
        const AudioCdInspection.noDisc(),
        const AudioCdInspection.noDisc(),
      );
    });
  });
}
