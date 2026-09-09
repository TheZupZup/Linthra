import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import 'wavy_seek_bar.dart';

/// How the seekable progress bar is drawn.
enum PlaybackProgressStyle {
  /// Linthra's own [WavySeekBar]: a soft serpentine line with a round marker.
  wave,

  /// The plain Material [Slider]. Kept as a first-class, tested path so a single
  /// constant reverts the look if the wave ever proves problematic on a device.
  slider,
}

/// The style [PlaybackProgressBar] uses unless a call site overrides it. Change
/// this one value to move the whole app back to the Material slider.
const PlaybackProgressStyle defaultPlaybackProgressStyle =
    PlaybackProgressStyle.wave;

/// Seekable progress bar showing the current position and total duration.
///
/// Robust to an unknown duration (common at the very start of a stream or for a
/// live source): when [duration] is zero the bar sits stable and disabled and
/// the total reads `--:--`, so the UI never breaks or jumps. While the user
/// drags, the marker and the elapsed label follow the finger; the actual
/// [onSeek] fires once on release, so playback isn't spammed mid-drag.
///
/// Release then *holds* that target until playback reports it. [position] comes
/// from a stream deliberately coalesced to ~250 ms for battery, so it keeps
/// reporting the pre-seek position for a moment after the seek is issued;
/// showing it again the instant the finger lifts snaps the marker back to where
/// the drag started and only then jumps forward. The bar stays optimistic
/// across that gap instead — bounded by [seekAckTimeout], so a seek that never
/// lands can't pin the marker somewhere playback isn't.
///
/// The drag preview lives here rather than in either renderer, so both the wave
/// and the slider stay interchangeable and the time labels follow the finger the
/// same way in both.
class PlaybackProgressBar extends StatefulWidget {
  const PlaybackProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.playing = false,
    this.style = defaultPlaybackProgressStyle,
    this.density = WavySeekBarDensity.standard,
    this.showTimeLabels = true,
    super.key,
  });

  final Duration position;
  final Duration duration;

  /// Called with the target position when a seek completes. The bar still
  /// renders progress when this is null, just without seeking.
  final ValueChanged<Duration>? onSeek;

  /// Whether playback is actively playing. Only the wave's slow drift uses this;
  /// a paused bar holds still and schedules no frames.
  final bool playing;

  /// Which renderer to use. Defaults to [defaultPlaybackProgressStyle].
  final PlaybackProgressStyle style;

  /// How much room the bar takes. Both renderers honour it: the mini-player
  /// gives its 64dp bar a compact one and needs that to hold whichever
  /// renderer [defaultPlaybackProgressStyle] currently selects.
  final WavySeekBarDensity density;

  /// Whether the elapsed/total caption is drawn under the bar. The now-playing
  /// *bar* turns it off: it has no room for it, and the full player one tap
  /// away shows both times.
  final bool showTimeLabels;

  /// How close [position] has to land to a released seek target before the bar
  /// hands the display back to it.
  ///
  /// The position stream is coalesced to ~250 ms, so the first tick that
  /// reflects a seek can already sit a flush — plus whatever the engine rounds
  /// to — past the target. This is that budget with headroom, and still far
  /// below a difference the eye would read as a jump.
  static const Duration seekAckTolerance = Duration(milliseconds: 750);

  /// The longest an unacknowledged seek target is held. A seek can simply fail
  /// (a dead source, a position the engine refuses), and the bar must fall back
  /// to the truth rather than lie indefinitely.
  static const Duration seekAckTimeout = Duration(seconds: 3);

  @override
  State<PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<PlaybackProgressBar> {
  /// The in-progress drag position in milliseconds, or null when not dragging.
  double? _dragMs;

  /// The position the last completed gesture seeked to, in milliseconds, shown
  /// in place of [PlaybackProgressBar.position] until playback acknowledges it.
  /// Null once acknowledged, superseded, or timed out.
  double? _pendingSeekMs;

  /// Fires if that acknowledgement never comes — the bound on the optimism.
  Timer? _pendingSeekExpiry;

  @override
  void didUpdateWidget(PlaybackProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different duration means a different source is loaded, and a target
    // measured against the previous track is meaningless against this one.
    if (widget.duration != oldWidget.duration) {
      _clearPendingSeek();
      return;
    }
    if (widget.position != oldWidget.position) _settlePendingSeek();
  }

  @override
  void dispose() {
    _pendingSeekExpiry?.cancel();
    super.dispose();
  }

  /// Hands the display back to the authoritative position once it has reached
  /// the pending target.
  ///
  /// No `setState`: this only runs from [didUpdateWidget], where the rebuild
  /// that delivered the new position is already under way.
  void _settlePendingSeek() {
    final double? target = _pendingSeekMs;
    if (target == null) return;
    final double delta = (widget.position.inMilliseconds - target).abs();
    if (delta > PlaybackProgressBar.seekAckTolerance.inMilliseconds) return;
    _clearPendingSeek();
  }

  void _clearPendingSeek() {
    _pendingSeekMs = null;
    _pendingSeekExpiry?.cancel();
    _pendingSeekExpiry = null;
  }

  void _onChanged(double value) {
    setState(() {
      // A fresh gesture supersedes the previous target outright: the finger is
      // the most current intent there is.
      _clearPendingSeek();
      _dragMs = value;
    });
  }

  void _onChangeEnd(double value) {
    widget.onSeek?.call(Duration(milliseconds: value.round()));
    _pendingSeekExpiry?.cancel();
    _pendingSeekExpiry = Timer(
      PlaybackProgressBar.seekAckTimeout,
      () {
        if (!mounted) return;
        setState(_clearPendingSeek);
      },
    );
    setState(() {
      _dragMs = null;
      _pendingSeekMs = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int totalMs = widget.duration.inMilliseconds;
    final bool hasDuration = totalMs > 0;
    final bool canSeek = hasDuration && widget.onSeek != null;

    final int posMs = hasDuration
        ? widget.position.inMilliseconds.clamp(0, totalMs).toInt()
        : 0;
    // The finger first, then a seek playback hasn't caught up with, then the
    // truth. Each is only ever the *most current* thing known about where
    // playback is meant to be.
    final double barValue = _dragMs ??
        _pendingSeekMs?.clamp(0, totalMs.toDouble()) ??
        posMs.toDouble();

    // Both renderers answer to the density: a call site that has only a few
    // pixels (the mini player) must not sprout a full-size control if
    // [defaultPlaybackProgressStyle] is ever flipped back to the slider.
    final bool compact = widget.density == WavySeekBarDensity.compact;

    final muted = theme.colorScheme.onSurfaceVariant;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: muted,
      letterSpacing: 0.4,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      children: [
        switch (widget.style) {
          PlaybackProgressStyle.wave => WavySeekBar(
              value: barValue,
              max: hasDuration ? totalMs.toDouble() : 0.0,
              onChanged: canSeek ? _onChanged : null,
              onChangeEnd: canSeek ? _onChangeEnd : null,
              semanticFormatter: _formatMs,
              playing: widget.playing,
              density: widget.density,
            ),
          PlaybackProgressStyle.slider => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: compact ? 2 : 4,
                // The slider's height is its overlay's, so shrinking that is
                // what keeps the fallback inside a bar sized for the wave.
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: compact ? 6 : 12,
                ),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: compact ? 3 : 6,
                ),
                inactiveTrackColor:
                    theme.colorScheme.onSurface.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: barValue,
                max: hasDuration ? totalMs.toDouble() : 1.0,
                onChanged: canSeek ? _onChanged : null,
                onChangeEnd: canSeek ? _onChangeEnd : null,
                // The wave path names itself (see [WavySeekBar]); without this
                // the Material fallback would announce a bare percentage with
                // nothing saying what it measures. `label` is semantics-only
                // here: the value indicator it can also drive is shown
                // `onlyForDiscrete`, and this slider is continuous.
                label: _positionLabel,
                semanticFormatterCallback: (double value) =>
                    _semanticValue(value, hasDuration ? totalMs : 0),
              ),
            ),
        },
        // Snug under the track and aligned to its ends, so the times read as a
        // caption for the bar rather than a separate, floating row.
        if (widget.showTimeLabels)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatMs(barValue), style: labelStyle),
                Text(
                  hasDuration ? _format(widget.duration) : '--:--',
                  style: labelStyle,
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// The name both renderers announce, so the bar reads the same whichever
  /// style is in use.
  static const String _positionLabel = 'Playback position';

  /// The spoken position, in the same `elapsed of total` shape [WavySeekBar]
  /// uses. An unknown duration says so rather than implying a length.
  static String _semanticValue(double milliseconds, int totalMs) {
    if (totalMs <= 0) return 'Unknown';
    return '${_formatMs(milliseconds)} of ${_formatMs(totalMs.toDouble())}';
  }

  static String _formatMs(double milliseconds) =>
      _format(Duration(milliseconds: milliseconds.round()));

  /// `m:ss`, widening to `h:mm:ss` past an hour.
  static String _format(Duration d) {
    final int totalSeconds = d.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final String mm = minutes.toString().padLeft(2, '0');
      return '$hours:$mm:$ss';
    }
    return '$minutes:$ss';
  }
}
