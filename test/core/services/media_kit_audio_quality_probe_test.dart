import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_stream_quality.dart';
import 'package:linthra/core/services/media_kit_audio_quality_probe.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit's own pseudo-tracks, which every track list starts with.
const List<AudioTrack> _pseudo = <AudioTrack>[
  AudioTrack('auto', null, null),
  AudioTrack('no', null, null),
];

PlayerState _state({
  List<AudioTrack> audio = const <AudioTrack>[],
  AudioTrack selected = const AudioTrack('auto', null, null),
  AudioParams params = const AudioParams(),
  List<VideoTrack> video = const <VideoTrack>[],
}) {
  return PlayerState(
    tracks: Tracks(
      audio: <AudioTrack>[..._pseudo, ...audio],
      video: <VideoTrack>[
        const VideoTrack('auto', null, null),
        const VideoTrack('no', null, null),
        ...video,
      ],
    ),
    track: Track(audio: selected),
    audioParams: params,
  );
}

void main() {
  group('MediaKitAudioQualityProbe.fromPlayerState', () {
    test('reads the codec and the decoder sample rate', () {
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[
          AudioTrack('1', null, null, codec: 'flac', samplerate: 96000),
        ],
        params: const AudioParams(format: 's32', sampleRate: 96000),
      ));

      expect(
        quality,
        const AudioStreamQuality(codec: 'flac', sampleRateHz: 96000),
      );
      expect(quality!.isLossless, isTrue);
    });

    test('a FLAC that decodes to s32 has no bit depth', () {
      // 24-bit and 32-bit FLAC both decode to s32, so the sample format does
      // not say which the file is.
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[AudioTrack('1', null, null, codec: 'flac')],
        params: const AudioParams(format: 's32', sampleRate: 44100),
      ));
      expect(quality?.bitDepth, isNull);
    });

    test('takes the bit depth an uncompressed PCM codec states', () {
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[
          AudioTrack('1', null, null, codec: 'pcm_s24le', samplerate: 48000),
        ],
      ));
      expect(quality?.bitDepth, 24);
      expect(quality?.sampleRateHz, 48000);
    });

    test('floating-point and 64-bit PCM state their width too', () {
      int? depth(String codec) => MediaKitAudioQualityProbe.fromPlayerState(
            _state(
                audio: <AudioTrack>[AudioTrack('1', null, null, codec: codec)]),
          )?.bitDepth;
      expect(depth('pcm_f32le'), 32);
      expect(depth('pcm_f64be'), 64);
      expect(depth('pcm_s64le'), 64);
      expect(depth('pcm_u8'), 8);
      // Companded PCM is 8-bit on the wire but not linear, and a planar or
      // packed variant is not a plain sample width.
      expect(depth('pcm_alaw'), isNull);
      expect(depth('pcm_s16le_planar'), isNull);
    });

    test('takes the bitrate the container reports, in kbps', () {
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[
          AudioTrack('1', null, null, codec: 'mp3', bitrate: 320000),
        ],
        params: const AudioParams(sampleRate: 44100),
      ));
      expect(
        quality,
        const AudioStreamQuality(
          codec: 'mp3',
          sampleRateHz: 44100,
          bitrateKbps: 320,
        ),
      );
    });

    test('prefers what the decoder outputs over the demuxer', () {
      // HE-AAC is the real case: the container states the core rate and the
      // decoder outputs twice that.
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[
          AudioTrack('1', null, null, codec: 'aac', samplerate: 22050),
        ],
        params: const AudioParams(sampleRate: 44100),
      ));
      expect(quality?.sampleRateHz, 44100);
    });

    test('nothing loaded reports nothing', () {
      expect(MediaKitAudioQualityProbe.fromPlayerState(const PlayerState()),
          isNull);
      // A sample rate left over from an earlier file is not a report on its
      // own: media_kit keeps audio-params across files.
      expect(
        MediaKitAudioQualityProbe.fromPlayerState(
          _state(params: const AudioParams(sampleRate: 44100)),
        ),
        isNull,
      );
    });

    test('an album cover video track is not mistaken for the audio', () {
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[AudioTrack('1', null, null, codec: 'opus')],
        video: const <VideoTrack>[
          VideoTrack('1', null, null, codec: 'mjpeg', albumart: true),
        ],
      ));
      expect(quality, const AudioStreamQuality(codec: 'opus'));
    });

    test('several audio tracks and no known selection report nothing', () {
      expect(
        MediaKitAudioQualityProbe.fromPlayerState(_state(
          audio: const <AudioTrack>[
            AudioTrack('1', null, null, codec: 'flac'),
            AudioTrack('2', null, null, codec: 'aac'),
          ],
        )),
        isNull,
      );
    });

    test('several audio tracks report the selected one', () {
      expect(
        MediaKitAudioQualityProbe.fromPlayerState(_state(
          audio: const <AudioTrack>[
            AudioTrack('1', null, null, codec: 'flac'),
            AudioTrack('2', null, null, codec: 'aac'),
          ],
          selected: const AudioTrack('2', null, null),
        ))?.codec,
        'aac',
      );
    });

    test('an external audio file is not the stream in the file', () {
      expect(
        MediaKitAudioQualityProbe.fromPlayerState(_state(
          audio: const <AudioTrack>[
            AudioTrack('/music/x.flac', null, null, codec: 'flac', uri: true),
          ],
        )),
        isNull,
      );
    });

    test('zero and negative values stay unknown', () {
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[
          AudioTrack('1', null, null, codec: 'mp3', samplerate: 0, bitrate: -1),
        ],
        params: const AudioParams(sampleRate: 0),
      ));
      expect(quality, const AudioStreamQuality(codec: 'mp3'));
    });

    test('a codec id that is not a plain identifier is dropped', () {
      final AudioStreamQuality? quality =
          MediaKitAudioQualityProbe.fromPlayerState(_state(
        audio: const <AudioTrack>[
          AudioTrack('1', null, null, codec: 'flac (FLAC)', samplerate: 44100),
        ],
      ));
      expect(quality, const AudioStreamQuality(sampleRateHz: 44100));
    });

    test('a track with nothing usable reports nothing', () {
      expect(
        MediaKitAudioQualityProbe.fromPlayerState(_state(
          audio: const <AudioTrack>[AudioTrack('1', null, null)],
        )),
        isNull,
      );
    });
  });

  group('MediaKitAudioQualityProbe without a live player', () {
    test('reports nothing and creates no player', () {
      expect(const MediaKitAudioQualityProbe().current(), isNull);
    });

    test('a change watch can be opened and closed', () async {
      final List<void> events = <void>[];
      final StreamSubscription<void> subscription =
          const MediaKitAudioQualityProbe().changes().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      // One "look again" on attach, nothing else with no player around.
      expect(events, hasLength(1));
    });
  });
}
