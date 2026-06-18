import 'package:flutter/material.dart';

import '../../../app/dimens.dart';

/// The "Tester checklist" card on the About page: a short, static list of the
/// things a Google Play closed tester can try in a couple of minutes, plus a
/// reminder of the feedback that helps most.
///
/// It is informational only. There is no completion state to tick off, nothing
/// is stored, no analytics are recorded, and nothing is sent — the card just
/// points testers at what to look at. The items are intentionally static and
/// local, so there is no network call or extra dependency. To change what
/// testers are pointed at for a build, edit [items]; the card renders whatever
/// is in the list, and the widget test asserts each line shows without
/// duplicating the copy.
class TesterChecklistSection extends StatelessWidget {
  const TesterChecklistSection({super.key});

  /// Short, tester-facing things to try, in the order they read on the card.
  /// Kept concise and easy to update when the testing focus changes; exposed so
  /// the widget test can assert each item renders.
  static const List<String> items = <String>[
    'Open the local music library.',
    'Try the playback controls.',
    'Try search.',
    'Try a self-hosted source if you use Jellyfin, Navidrome, or Subsonic.',
    'Try offline and cache behavior if available.',
    'Report any crash, playback issue, layout bug, or confusing flow.',
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
                  Icons.checklist_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Tester checklist',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'A few quick things to try. Nothing here is saved or sent.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < items.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: AppSpacing.sm),
              _CheckItem(text: items[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// A single checklist line: a check icon and the item text, aligned to the top
/// so a wrapped line keeps the icon on the first row.
class _CheckItem extends StatelessWidget {
  const _CheckItem({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? body = theme.textTheme.bodyMedium;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          Icons.check_circle_outline,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: body)),
      ],
    );
  }
}
