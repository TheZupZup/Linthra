import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_failure.dart';
import '../../../core/services/playback_controller.dart';
import '../player_providers.dart';
import 'playback_error_notice.dart';

/// The panel shown while Linthra counts down to skipping a track it could not
/// recover: why, how long until it moves on, and a way to stay.
///
/// It only ever renders the countdown the controller published
/// ([PendingAutoSkip]). The skip itself is the controller's: this widget has
/// no timer that acts, only one that repaints the seconds, so it can't skip
/// early, late or twice, and it disappears the moment the controller calls the
/// skip off (a Next, a pause, a new queue, a Retry).
///
/// Takes the same strip as [PlaybackErrorNotice], so the transport, the queue
/// and the rest of the app stay usable, and nothing has to be dismissed.
class AutoSkipNotice extends ConsumerStatefulWidget {
  const AutoSkipNotice({required this.autoSkip, this.now, super.key});

  final PendingAutoSkip autoSkip;

  /// The clock the seconds are read from. Tests pass a fixed one.
  final DateTime Function()? now;

  /// Finds the panel in tests.
  static const ValueKey<String> noticeKey =
      ValueKey<String>('auto-skip-notice');

  /// Finds the "Stay on this track" button in tests.
  static const ValueKey<String> stayKey = ValueKey<String>('auto-skip-stay');

  @override
  ConsumerState<AutoSkipNotice> createState() => _AutoSkipNoticeState();
}

class _AutoSkipNoticeState extends ConsumerState<AutoSkipNotice> {
  /// Repaints the seconds. It never acts on the countdown.
  Timer? _repaint;

  /// Set once "Stay on this track" has been pressed, so a second tap can't
  /// send a second command.
  bool _acted = false;

  @override
  void initState() {
    super.initState();
    _repaint = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(AutoSkipNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new countdown (the next track failed too) takes new commands.
    if (oldWidget.autoSkip != widget.autoSkip) _acted = false;
  }

  @override
  void dispose() {
    _repaint?.cancel();
    super.dispose();
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color onColor = theme.colorScheme.onSecondaryContainer;
    final PendingAutoSkip autoSkip = widget.autoSkip;
    final int seconds = autoSkip.secondsLeft(_now());
    final String countdown = seconds > 0
        ? 'Skipping to the next song in $seconds '
            '${seconds == 1 ? 'second' : 'seconds'}.'
        : 'Skipping to the next song…';
    final double progress = autoSkip.countdown.inMilliseconds <= 0
        ? 1
        : 1 -
            autoSkip.skipsAt
                    .difference(_now())
                    .inMilliseconds
                    .clamp(0, autoSkip.countdown.inMilliseconds) /
                autoSkip.countdown.inMilliseconds;

    return Container(
      key: AutoSkipNotice.noticeKey,
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Announced once, when the countdown starts: a live region whose
          // text changed every second would talk over everything else.
          Semantics(
            container: true,
            liveRegion: true,
            label: "Couldn't play this song. ${autoSkip.failure.message} "
                'Linthra will skip to the next song shortly.',
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    PlaybackErrorNotice.iconFor(autoSkip.failure.kind),
                    size: 20,
                    color: onColor,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          autoSkip.failure.message,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: onColor),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          countdown,
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: onColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          ExcludeSemantics(
            child: LinearProgressIndicator(
              value: progress,
              color: onColor,
              backgroundColor: onColor.withValues(alpha: 0.2),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          // Skipping sooner is the transport's Next; this strip only offers
          // what the transport can't: staying on the failed track.
          TextButton.icon(
            key: AutoSkipNotice.stayKey,
            onPressed: _acted ? null : _stay,
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Stay on this track'),
            style: TextButton.styleFrom(foregroundColor: onColor),
          ),
        ],
      ),
    );
  }

  /// Calls the countdown off. The controller then shows the failure with its
  /// usual recoveries in this strip's place.
  Future<void> _stay() async {
    if (_acted) return;
    setState(() => _acted = true);
    final PlaybackController controller = ref.read(playbackControllerProvider);
    await controller.cancelAutomaticSkip();
  }
}
