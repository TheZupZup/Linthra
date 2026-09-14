import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/playback_state.dart';
import '../../../core/services/playback_controller.dart';
import '../../../shared/scroll/pointer_scroll_adjust.dart';
import '../player_providers.dart';

/// How far one scroll notch moves the level. Small enough to fine-tune, large
/// enough that a few notches cross the range — the step desktop mixers settle
/// on. (Arrow keys are the Slider's own 10% step, not this one.)
const double volumeStep = 0.05;

/// The desktop volume control: mute/unmute plus a slider, driven entirely
/// through the [PlaybackController].
///
/// It reads the level from [PlaybackState] rather than keeping its own, so the
/// UI can never drift from what is actually playing: a change made anywhere
/// else — the other copy of this widget, a shell's MPRIS slider, a restored
/// preference at startup — moves this slider too. The only local state is the
/// in-progress drag, so a state event mid-gesture doesn't fight the pointer.
///
/// Desktop only by placement, not by check: the phone layouts don't build it,
/// because a phone's volume is the system's and belongs to its hardware keys.
/// It sizes itself to sit in a row of icon buttons — the Now Playing action row
/// and the mini-player bar both host it that way — so callers add their own
/// spacing rather than working around padding baked in here.
class VolumeControls extends ConsumerStatefulWidget {
  const VolumeControls({super.key});

  @override
  ConsumerState<VolumeControls> createState() => _VolumeControlsState();
}

class _VolumeControlsState extends ConsumerState<VolumeControls> {
  /// The level being dragged right now, or null when the pointer is not down.
  double? _dragValue;

  PlaybackController get _controller => ref.read(playbackControllerProvider);

  void _onChanged(double value) {
    // Applied live rather than on release: a volume slider that only takes
    // effect when you let go gives no feedback while you are choosing a level.
    // (It is also what makes arrow-key adjustment work — the Slider's keyboard
    // actions call onChanged and never onChangeEnd.)
    setState(() => _dragValue = value);
    _controller.setVolume(value);
  }

  void _onChangeEnd(double value) {
    _controller.setVolume(value);
    setState(() => _dragValue = null);
  }

  /// Scroll wheel over the control: up is louder, down is quieter.
  ///
  /// One notch is one [volumeStep], however the notch arrived — a wheel click
  /// or the dozens of small deltas a trackpad sends for the same gesture,
  /// which [PointerScrollAdjust] has already counted into whole notches by the
  /// time this runs. Stepping per *event* instead is what used to take a
  /// two-finger flick from half volume to silence.
  void _onNotch(int notches) {
    // Read the level now rather than from the build that installed this
    // callback: a fast wheel spin delivers several events before a frame, and
    // each of them has to step off the one before.
    final PlaybackState state = _controller.state;
    final bool muted = state.muted;
    final bool louder = notches > 0;
    // Scrolling down while muted is already what it asks for. Ignoring it keeps
    // the level mute has to come back to, instead of quietly grinding it to
    // zero behind a muted icon.
    if (muted && !louder) return;
    // Muted, scrolling up: step off the silence rather than off the remembered
    // level, so one notch is one notch of what you can hear.
    final double current = muted ? 0.0 : state.volume;
    _controller.setVolume(current + notches * volumeStep);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlaybackController controller = ref.watch(playbackControllerProvider);
    final ({double volume, bool muted}) level = ref.watch(
      playbackStateProvider.select((AsyncValue<PlaybackState> async) {
        final PlaybackState state = async.valueOrNull ?? controller.state;
        return (volume: state.volume, muted: state.muted);
      }),
    );

    final double effective = level.muted ? 0.0 : level.volume;
    final double sliderValue = _dragValue ?? effective;
    final bool silent = effective <= 0.0;

    return PointerScrollAdjust(
      onNotch: _onNotch,
      // A wheel notch while the slider is being dragged must not scroll the
      // page the control sits on, wherever the pointer has wandered to.
      adjusting: _dragValue != null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            onPressed: () => controller.setMuted(!level.muted),
            icon: Icon(_iconFor(silent: silent, volume: effective)),
            // Selected while muted, so mute reads as the toggle it is rather
            // than as two buttons that swap places.
            isSelected: level.muted,
            iconSize: 22,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            tooltip: level.muted ? 'Unmute' : 'Mute',
          ),
          SizedBox(
            // Wide enough to aim at a level, narrow enough to share a row with
            // the controls it sits beside.
            width: 120,
            // Merged, not just wrapped: a `Semantics` label alone sits on its
            // own node above the slider's, so a screen reader landing on the
            // slider hears "70%" with nothing saying of what — next to a
            // position slider on the same screen, that is unusable. Merging
            // puts the name on the same node as the value and the
            // increase/decrease actions. (`Slider.label` is not this: it drives
            // the visual value indicator, and only for discrete sliders.)
            child: MergeSemantics(
              child: Semantics(
                label: 'Volume',
                child: Slider(
                  value: sliderValue,
                  onChanged: _onChanged,
                  onChangeEnd: _onChangeEnd,
                  semanticFormatterCallback: (double value) =>
                      '${(value * 100).round()}%',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The glyph for the current level: an explicit "off" while silent (muted or
  /// dragged to zero, which sound the same), and a quieter speaker below
  /// halfway so the icon carries the level as well as the state.
  static IconData _iconFor({required bool silent, required double volume}) {
    if (silent) return Icons.volume_off;
    if (volume < 0.5) return Icons.volume_down;
    return Icons.volume_up;
  }
}
