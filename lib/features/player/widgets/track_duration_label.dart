import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../shared/format/playback_time.dart';
import '../../../shared/layout/desktop_presentation.dart';

/// A track's length at the end of its row, on desktop.
///
/// A desktop track list is read like a table: what the song is, who it is by,
/// and how long it runs. Phones keep their calmer two-line rows, where the
/// title needs the width more than a number does.
///
/// Renders nothing for a track whose length is not known (a server that did
/// not report one), rather than a made-up 0:00.
class TrackDurationLabel extends StatelessWidget {
  const TrackDurationLabel({required this.duration, super.key});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (duration <= Duration.zero || !usesDesktopPresentation(context)) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.sm,
        end: AppSpacing.xs,
      ),
      child: Text(
        formatPlaybackTime(duration),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          // Same-width digits, so the lengths line up down the list.
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
