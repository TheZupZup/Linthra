import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/audio_stream_quality.dart';
import '../../core/models/playback_source.dart';
import '../../core/models/playback_state.dart';
import '../../core/services/audio_quality_probe.dart';
import '../../core/services/playback_controller.dart';
import '../../data/repositories/audio_quality_probe_provider.dart';
import '../settings/playback/show_audio_quality_controller.dart';
import 'cast/cast_providers.dart';
import 'player_providers.dart';

/// Whether Now Playing shows the audio quality line: the listener turned it on
/// and this platform's engine can report anything at all.
final audioQualityLineEnabledProvider = Provider.autoDispose<bool>((ref) {
  if (!ref.watch(audioQualityProbeProvider).isAvailable) return false;
  return ref.watch(showAudioQualityControllerProvider).valueOrNull ?? false;
});

/// The engine's report for the song on Now Playing, or `null` while there is
/// nothing trustworthy to show.
///
/// Auto-disposed, so it only runs while Now Playing is on screen, and with the
/// setting off it returns before watching anything else: no probe, no timer,
/// no subscription.
final nowPlayingAudioQualityProvider =
    NotifierProvider.autoDispose<NowPlayingAudioQuality, AudioStreamQuality?>(
  NowPlayingAudioQuality.new,
);

/// Pairs the engine's report with the copy that is actually playing.
///
/// The engine does not say which song its report is about, so this keys every
/// report to the track and resolved source the controller says it loaded. When
/// either changes (a skip, a fallback to another provider's copy, a switch
/// from the stream to the offline copy) the old report is dropped at once, and
/// a new one is read only after the new copy has been playing for
/// [settleDelay]: media_kit can still be mirroring the previous file's track
/// list for a moment after a skip, and a quiet line for half a second is
/// better than the last song's codec under this one's title. Loading,
/// reconnecting, a failure or a cast session clear it too.
class NowPlayingAudioQuality extends AutoDisposeNotifier<AudioStreamQuality?> {
  /// How long a newly loaded copy plays before the engine is asked about it.
  static const Duration settleDelay = Duration(milliseconds: 500);

  @override
  AudioStreamQuality? build() {
    if (!ref.watch(audioQualityLineEnabledProvider)) return null;
    // A receiver is playing, not this engine. Only a real handoff counts: a
    // receiver that is merely connected (the track is a local file it cannot
    // take) leaves the engine playing here.
    final bool casting = ref.watch(
          castStateProvider.select((s) => s.valueOrNull?.isCasting),
        ) ??
        ref.watch(castServiceProvider).state.isCasting;
    if (casting) return null;

    final PlaybackController controller = ref.watch(playbackControllerProvider);
    final _LoadedCopy? copy = ref.watch(
      playbackStateProvider.select(
        (AsyncValue<PlaybackState> s) =>
            _loadedCopy(s.valueOrNull ?? controller.state),
      ),
    );
    if (copy == null) return null;

    // Everything below belongs to this copy. A rebuild for the next one runs
    // the disposer first, so a timer or an engine event from this copy can
    // never write its report over the next song.
    final AudioQualityProbe probe = ref.watch(audioQualityProbeProvider);
    bool settled = false;
    void read() {
      if (settled) state = probe.current();
    }

    final StreamSubscription<void> changes =
        probe.changes().listen((void _) => read(), onError: (Object _) {});
    final Timer settle = Timer(settleDelay, () {
      settled = true;
      read();
    });
    ref.onDispose(() {
      settle.cancel();
      unawaited(changes.cancel());
    });
    return null;
  }
}

typedef _LoadedCopy = ({String uri, PlaybackSource source});

/// The copy the engine holds a decoded stream for, or `null` while it holds
/// none.
_LoadedCopy? _loadedCopy(PlaybackState state) {
  final String? uri = state.currentTrack?.uri;
  final PlaybackSource? source = state.source;
  if (uri == null || source == null) return null;
  final bool holdsStream = switch (state.status) {
    PlaybackStatus.playing ||
    PlaybackStatus.paused ||
    PlaybackStatus.buffering =>
      true,
    PlaybackStatus.idle ||
    PlaybackStatus.loading ||
    PlaybackStatus.reconnecting ||
    PlaybackStatus.completed ||
    PlaybackStatus.error =>
      false,
  };
  return holdsStream ? (uri: uri, source: source) : null;
}
