import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_failure.dart';
import '../../../core/models/track.dart';
import '../../../core/services/playback_controller.dart';
import '../../settings/playback/auto_skip_controller.dart';
import '../player_providers.dart';
import 'playback_error_notice.dart';

/// Explains automatic skipping the first time a track can't be recovered, and
/// asks whether Linthra may do it from now on.
///
/// Shown only while the listener hasn't chosen (the preference is unset), and
/// only for a failure the next song could get past, so it appears once and
/// never nags: either answer is saved, and from then on the ordinary
/// [PlaybackErrorNotice] (or, if they allowed it, the countdown) takes this
/// strip. Nothing is pre-selected and nothing happens until they choose.
///
/// Both answers go through [autoSkipControllerProvider], the same preference
/// the Settings switch writes, and the controller enforces it. This panel is
/// the phone and desktop app's only: Android Auto never shows it and simply
/// follows whatever was saved.
class AutoSkipIntroPanel extends ConsumerStatefulWidget {
  const AutoSkipIntroPanel({required this.failure, super.key});

  /// The failure that stopped playback, in its safe classified wording.
  final PlaybackFailure failure;

  /// Finds the panel in tests.
  static const ValueKey<String> panelKey =
      ValueKey<String>('auto-skip-intro-panel');

  /// Finds the "Allow automatic skip" button in tests.
  static const ValueKey<String> allowKey =
      ValueKey<String>('auto-skip-intro-allow');

  /// Finds the "Not now" button in tests.
  static const ValueKey<String> notNowKey =
      ValueKey<String>('auto-skip-intro-not-now');

  /// Finds the "Details" button in tests.
  static const ValueKey<String> detailsKey =
      ValueKey<String>('auto-skip-intro-details');

  @override
  ConsumerState<AutoSkipIntroPanel> createState() => _AutoSkipIntroPanelState();
}

class _AutoSkipIntroPanelState extends ConsumerState<AutoSkipIntroPanel> {
  bool _showDetails = false;

  /// Set while an answer is being saved, so a double tap can't save twice or
  /// skip twice.
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final PlaybackFailure failure = widget.failure;

    return Semantics(
      container: true,
      // Playback stopped without the listener touching anything, so a screen
      // reader should hear why when it happens.
      liveRegion: true,
      child: Container(
        key: AutoSkipIntroPanel.panelKey,
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  PlaybackErrorNotice.iconFor(failure.kind),
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    "Sorry, Linthra couldn't play this song",
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(failure.message, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Linthra can automatically move to the next song when a track '
              "can't be played after its recovery attempts, so your music "
              "doesn't stop.",
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (_showDetails) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'What happened: ${failure.shortLabel}.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Before moving on, Linthra shows the reason and counts down '
                'for a few seconds, so you can stay on the track instead. '
                "Retry, another source and Skip stay available whenever it "
                "stops. You can change this any time in Settings, under "
                'Playback.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            // Wraps rather than scrolls, so at a large text scale every choice
            // stays on screen.
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton(
                  key: AutoSkipIntroPanel.allowKey,
                  onPressed: _busy ? null : _allow,
                  child: const Text('Allow automatic skip'),
                ),
                TextButton(
                  key: AutoSkipIntroPanel.notNowKey,
                  onPressed: _busy ? null : _notNow,
                  child: const Text('Not now'),
                ),
                TextButton(
                  key: AutoSkipIntroPanel.detailsKey,
                  onPressed: () => setState(() => _showDetails = !_showDetails),
                  child: Text(_showDetails ? 'Hide details' : 'Details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Saves the choice and gets the music going again past the failed track,
  /// which is what the listener just asked for.
  ///
  /// The move is to where an automatic skip would go (wrapping under
  /// repeat-all), past the track this panel was shown for. It waits for the
  /// choice to be saved, so a save that fails moves nothing, and the
  /// controller takes its snapshot of playback in this same tap, so anything
  /// the listener does while the save runs (a Retry, a pause, a skip, with
  /// the panel already gone) wins over the late move.
  Future<void> _allow() async {
    if (_busy) return;
    final PlaybackController playback = ref.read(playbackControllerProvider);
    final AutoSkipController choice =
        ref.read(autoSkipControllerProvider.notifier);
    final Track? failed = playback.state.currentTrack;
    setState(() => _busy = true);
    try {
      final Future<void> saving = choice.setEnabled(true);
      if (failed == null) {
        await saving;
      } else {
        await playback.skipPastFailedTrack(failed, after: saving);
      }
    } catch (_) {
      // Saving failed, so the panel is still up and must not be left with its
      // buttons disabled. On success they stay disabled until it goes, so a
      // second tap can't skip twice.
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
  }

  /// Saves the choice. The failed track stays, and the ordinary error panel
  /// with Retry / another source / Skip takes this one's place.
  Future<void> _notNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(autoSkipControllerProvider.notifier).setEnabled(false);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
  }
}
