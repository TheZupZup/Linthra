import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import '../models/audio_stream_quality.dart';
import 'audio_quality_probe.dart';

/// The Linux [AudioQualityProbe]: reads what libmpv reports about the stream
/// it is decoding.
///
/// It only reads state media_kit already keeps. media_kit observes libmpv's
/// `track-list` and `audio-params` for every player it creates and mirrors them
/// into [Player.state], so reading a report is a field access in Dart: no
/// libmpv call, no command, nothing on the playback path. The live player is
/// reached the same way the output device service reaches it, through the
/// vendored plugin's `JustAudioMediaKit.livePlayers` registry.
///
/// What it reports, and where each value comes from:
///
///  * codec: the audio track's `codec` from `track-list`, the stream as
///    demuxed (a server-side transcode reads as the transcode);
///  * sample rate: `audio-params/samplerate`, what the decoder outputs, or the
///    track's `demux-samplerate` before the decoder has said;
///  * bitrate: the track's `demux-bitrate`, the container's average. libmpv's
///    packet-level `audio-bitrate` is left out: libmpv itself calls it a guess;
///  * bit depth: only from an uncompressed PCM codec id, which states it. The
///    decoder's sample format does not (FLAC above 16 bits decodes to `s32`
///    whatever the file's depth), so a FLAC's depth stays unknown.
class MediaKitAudioQualityProbe implements AudioQualityProbe {
  const MediaKitAudioQualityProbe();

  @override
  bool get isAvailable => true;

  @override
  AudioStreamQuality? current() {
    try {
      final List<Player> live = JustAudioMediaKit.livePlayers.values.toList();
      // Linthra plays through one player. Two means the engine is between
      // players, and there is no telling which one is the song.
      if (live.length != 1) return null;
      return fromPlayerState(live.single.state);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<void> changes() {
    final Map<String, List<StreamSubscription<Object?>>> attached =
        <String, List<StreamSubscription<Object?>>>{};
    StreamSubscription<void>? registry;
    late StreamController<void> controller;

    void notify(Object? _) {
      if (!controller.isClosed) controller.add(null);
    }

    // Same bookkeeping as the output device watch: attach to players as the
    // engine creates them, let go as it releases them.
    void sync() {
      final Map<String, Player> live = JustAudioMediaKit.livePlayers;
      for (final MapEntry<String, Player> entry in live.entries) {
        if (attached.containsKey(entry.key)) continue;
        final PlayerStream stream = entry.value.stream;
        attached[entry.key] = <StreamSubscription<Object?>>[
          stream.tracks.listen(notify, onError: (Object _) {}),
          stream.track.listen(notify, onError: (Object _) {}),
          stream.audioParams.listen(notify, onError: (Object _) {}),
        ];
      }
      for (final String id in attached.keys.toList()) {
        if (live.containsKey(id)) continue;
        for (final StreamSubscription<Object?> s in attached.remove(id)!) {
          unawaited(s.cancel());
        }
      }
      notify(null);
    }

    controller = StreamController<void>(
      onListen: () {
        registry = JustAudioMediaKit.livePlayersChanged.stream
            .listen((void _) => sync());
        sync();
      },
      onCancel: () async {
        await registry?.cancel();
        registry = null;
        for (final List<StreamSubscription<Object?>> subscriptions
            in attached.values.toList()) {
          for (final StreamSubscription<Object?> s in subscriptions) {
            await s.cancel();
          }
        }
        attached.clear();
      },
    );
    return controller.stream;
  }

  /// The report for one media_kit player [state], or `null` when it does not
  /// name exactly one audio track to describe.
  static AudioStreamQuality? fromPlayerState(PlayerState state) {
    final AudioTrack? track = _playingTrack(state);
    if (track == null) return null;
    final String? codec = _codecId(track.codec);
    final AudioStreamQuality quality = AudioStreamQuality(
      codec: codec,
      sampleRateHz: _positive(state.audioParams.sampleRate) ??
          _positive(track.samplerate),
      bitDepth: _pcmBitDepth(codec),
      bitrateKbps: _kbps(track.bitrate),
    );
    return quality.isEmpty ? null : quality;
  }

  /// The audio track being played: the selected one when media_kit knows the
  /// selection, otherwise the only one there is. A file with several audio
  /// tracks and no known selection names none.
  static AudioTrack? _playingTrack(PlayerState state) {
    final List<AudioTrack> tracks =
        state.tracks.audio.where(_isRealTrack).toList();
    final AudioTrack selected = state.track.audio;
    if (_isRealTrack(selected)) {
      for (final AudioTrack track in tracks) {
        if (track.id == selected.id) return track;
      }
      return null;
    }
    return tracks.length == 1 ? tracks.single : null;
  }

  /// media_kit lists `auto` and `no` as pseudo-tracks, and an external audio
  /// file as a `uri` track; none of them is the stream in the file.
  static bool _isRealTrack(AudioTrack track) =>
      !track.uri && track.id != 'auto' && track.id != 'no';

  static final RegExp _codecPattern = RegExp(r'^[a-z0-9_]{1,32}$');

  static String? _codecId(String? raw) {
    final String? id = raw?.trim().toLowerCase();
    if (id == null || !_codecPattern.hasMatch(id)) return null;
    return id;
  }

  static final RegExp _pcmInteger = RegExp(r'^pcm_[su](8|16|24|32)(le|be)?$');

  static int? _pcmBitDepth(String? codec) {
    if (codec == null) return null;
    final RegExpMatch? match = _pcmInteger.firstMatch(codec);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static int? _positive(int? value) =>
      (value != null && value > 0) ? value : null;

  static int? _kbps(int? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return null;
    final int kbps = (bitsPerSecond / 1000).round();
    return kbps > 0 ? kbps : null;
  }
}
