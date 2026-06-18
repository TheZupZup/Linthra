import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/app_info.dart';

/// The "What's new" card on the About page.
///
/// This is a small, static release-note surface for closed testers. It keeps the
/// current test build's highlights visible without adding network calls, remote
/// config, or release-file coupling.
class WhatsNewSection extends StatelessWidget {
  const WhatsNewSection({super.key});

  static const List<String> _notes = <String>[
    'Added support and bug report links for testers.',
    'Added a copyable app-info block for easier bug reports.',
    'Improved About and project information.',
    'Continued Google Play closed testing preparation.',
    'Stability and polish improvements.',
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.new_releases_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text("What's new", style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Linthra ${AppInfo.version}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final String note in _notes) _ReleaseNoteRow(note: note),
          ],
        ),
      ),
    );
  }
}

class _ReleaseNoteRow extends StatelessWidget {
  const _ReleaseNoteRow({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.check_circle_outline,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(note, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
