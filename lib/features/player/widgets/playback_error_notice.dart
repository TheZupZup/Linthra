import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_failure.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/services/playback_controller.dart';
import '../../../core/services/playback_source_label.dart';
import '../player_providers.dart';

/// The in-place panel shown when the current track can't play: what went wrong,
/// in plain words, and the recoveries that are actually available for it.
///
/// Deliberately *not* a dialog. A failed track is a small problem (the queue,
/// the library, search and settings all still work), so it takes the strip the
/// source badge normally occupies rather than taking over the screen. Nothing
/// here decides what is recoverable: the actions come from
/// [PlaybackFailure] as the controller built it, which is why a single-source
/// song never offers "another source" and the last track in a queue never offers
/// Skip.
///
/// Every action runs through the shared [PlaybackController] (the same one
/// transport buttons use), so recovery behaves identically on Android and Linux
/// and cannot drift into a second, parallel playback path.
class PlaybackErrorNotice extends ConsumerStatefulWidget {
  const PlaybackErrorNotice({required this.failure, super.key});

  /// Why playback stopped, and which recoveries are valid.
  final PlaybackFailure failure;

  /// Finds the panel in tests.
  static const ValueKey<String> noticeKey =
      ValueKey<String>('playback-error-notice');

  /// Finds one action button in tests.
  static ValueKey<String> keyForAction(PlaybackRecoveryAction action) =>
      ValueKey<String>('playback-error-action-${action.name}');

  @override
  ConsumerState<PlaybackErrorNotice> createState() =>
      _PlaybackErrorNoticeState();
}

class _PlaybackErrorNoticeState extends ConsumerState<PlaybackErrorNotice> {
  /// The action currently running, or null when the panel is idle.
  ///
  /// It is what keeps a recovery to exactly one attempt per tap: while it is
  /// set the buttons are gone, so an impatient second tap on Skip cannot advance
  /// the queue twice, and two recoveries can never race each other.
  PlaybackRecoveryAction? _running;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color onError = theme.colorScheme.onErrorContainer;
    final PlaybackRecoveryAction? running = _running;

    return Semantics(
      container: true,
      // Playback fails without the listener touching anything, so a screen
      // reader should hear about it when it happens rather than on the next
      // focus change.
      liveRegion: true,
      child: Container(
        key: PlaybackErrorNotice.noticeKey,
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(_iconFor(widget.failure.kind), size: 20, color: onError),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    widget.failure.message,
                    style: theme.textTheme.bodyMedium?.copyWith(color: onError),
                  ),
                ),
              ],
            ),
            if (running != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              _BusyRow(label: _busyLabelFor(running), color: onError),
            ] else if (widget.failure.hasActions) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              // Wraps rather than scrolls: at a large text scale three buttons
              // do not fit one line on a phone, and a recovery the listener
              // cannot see is no recovery at all.
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  for (final PlaybackRecoveryAction action
                      in widget.failure.actions)
                    TextButton.icon(
                      key: PlaybackErrorNotice.keyForAction(action),
                      onPressed: () => _run(action),
                      icon: Icon(_actionIconFor(action), size: 18),
                      label: Text(_actionLabelFor(action)),
                      style: TextButton.styleFrom(foregroundColor: onError),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Runs one recovery through the shared controller and reports what came of
  /// it.
  Future<void> _run(PlaybackRecoveryAction action) async {
    if (_running != null) return;
    setState(() => _running = action);

    final PlaybackController controller = ref.read(playbackControllerProvider);
    final String? failedUri = controller.state.currentTrack?.uri;
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);

    switch (action) {
      case PlaybackRecoveryAction.retry:
        await controller.retryCurrentTrack();
      case PlaybackRecoveryAction.tryAnotherSource:
        await controller.tryAnotherSource();
      case PlaybackRecoveryAction.skip:
        await controller.skipToNext();
    }

    // This panel is usually gone by now: playback leaves the error state the
    // moment an attempt starts, which takes the panel with it. So the outcome is
    // reported through the messenger captured above rather than through this
    // widget, and the reset below only matters when the panel is still up (a
    // recovery that changed nothing).
    if (mounted) setState(() => _running = null);

    // A retry that worked, or a skip, is obvious: the music plays and the panel
    // is gone. A source switch is the quiet one: same song, same place in the
    // queue, only a different provider behind it. So say so.
    if (action != PlaybackRecoveryAction.tryAnotherSource) return;
    final PlaybackState after = controller.state;
    final bool switched = after.status != PlaybackStatus.error &&
        after.currentTrack?.uri != failedUri;
    if (!switched) return;
    if (messenger == null || !messenger.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Playing from ${PlaybackSourceLabel.of(
            trackUri: after.currentTrack?.uri,
            source: after.source,
          )}.',
        ),
      ),
    );
  }

  static IconData _iconFor(PlaybackFailureKind kind) => switch (kind) {
        PlaybackFailureKind.temporarySource => Icons.cloud_off,
        PlaybackFailureKind.localFileUnavailable => Icons.folder_off,
        PlaybackFailureKind.sourceSignInRequired => Icons.lock_outline,
        PlaybackFailureKind.unplayableMedia => Icons.music_off,
      };

  static IconData _actionIconFor(PlaybackRecoveryAction action) =>
      switch (action) {
        PlaybackRecoveryAction.retry => Icons.refresh,
        PlaybackRecoveryAction.tryAnotherSource => Icons.swap_horiz,
        PlaybackRecoveryAction.skip => Icons.skip_next,
      };

  static String _actionLabelFor(PlaybackRecoveryAction action) =>
      switch (action) {
        PlaybackRecoveryAction.retry => 'Retry',
        PlaybackRecoveryAction.tryAnotherSource => 'Try another source',
        PlaybackRecoveryAction.skip => 'Skip',
      };

  static String _busyLabelFor(PlaybackRecoveryAction action) =>
      switch (action) {
        PlaybackRecoveryAction.retry => 'Trying again…',
        PlaybackRecoveryAction.tryAnotherSource => 'Trying another source…',
        PlaybackRecoveryAction.skip => 'Skipping…',
      };
}

/// What the panel shows while a recovery is in flight, so a tap is visibly
/// doing something even when resolving a fresh stream takes a moment.
class _BusyRow extends StatelessWidget {
  const _BusyRow({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(color: color),
        ),
      ],
    );
  }
}
