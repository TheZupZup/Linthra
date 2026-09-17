import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../local_root_problem.dart';

/// The recoverable state one unreadable local folder is shown in, wherever it
/// is shown: what went wrong, what did *not* go wrong, and the three ways out.
///
/// Deliberately one widget for both surfaces (the Settings ▸ Local music card
/// and the Library screen's empty state), because a folder that is away is the
/// same folder on both, and a user who reads "permission denied" in Settings
/// must not read "no music found" two taps away.
///
/// It renders text and buttons and nothing else: every callback belongs to the
/// caller, and a null callback simply hides its button. Removing, in
/// particular, is not something this offers on its own: the caller decides
/// whether removing a source is available here at all.
class LocalRootProblemPanel extends StatelessWidget {
  const LocalRootProblemPanel({
    required this.presentation,
    this.onRetry,
    this.onReselect,
    this.onRemove,
    this.dense = false,
    super.key,
  });

  final LocalRootProblemPresentation presentation;

  /// Ask the folder again. The fix for the case where nothing is wrong any
  /// more: the drive is back, the mount answered, the permission was restored.
  final VoidCallback? onRetry;

  /// Pick the folder again through the system chooser. Never a silent
  /// substitution: the user chooses the path, and nothing here can choose one
  /// for them.
  final VoidCallback? onReselect;

  /// Drop this folder from the library. Affects this folder only, and deletes
  /// nothing on disk. The button says so, because "Remove" next to a broken
  /// folder is exactly where a user fears otherwise.
  final VoidCallback? onRemove;

  /// Tightens the layout for the Settings row, where the folder's name is
  /// already on screen directly above.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final bool showReselect = onReselect != null && presentation.canReselect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              presentation.icon,
              size: dense ? 18 : 22,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                presentation.title,
                style: (dense
                        ? theme.textTheme.bodyMedium
                        : theme.textTheme.titleSmall)
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          presentation.explanation,
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          presentation.guidance,
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        if (onRetry != null || showReselect || onRemove != null) ...[
          const SizedBox(height: AppSpacing.xs),
          // Wrapped rather than a Row: three buttons do not fit side by side on
          // a narrow window or at a large text scale, and a folder that needs
          // fixing is the last place to hide the fix off the edge.
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              if (onRetry != null)
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry'),
                ),
              if (showReselect)
                OutlinedButton.icon(
                  onPressed: onReselect,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('Select folder again'),
                ),
              if (onRemove != null)
                TextButton.icon(
                  onPressed: onRemove,
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  label: const Text('Remove folder'),
                ),
            ],
          ),
          if (onRemove != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Removing a folder only takes it out of Linthra. Your files are '
              'never deleted.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ],
    );
  }
}
