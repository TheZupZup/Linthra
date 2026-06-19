import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/app_info.dart';

/// The "What's new" card on the About page: a short, static summary of what
/// changed in the current testing build, so closed-testing testers can see at a
/// glance what's worth a look without leaving the app.
///
/// The highlights are intentionally static and local — no remote changelog,
/// network call, or extra dependency. The version label is read from [AppInfo]
/// (the single in-app source of truth, kept in lockstep with `pubspec.yaml`), so
/// the card always names the build the tester is actually running. To prepare a
/// new testing release, edit [releaseNotes]; the version follows `pubspec.yaml`
/// on its own.
class WhatsNewSection extends StatelessWidget {
  const WhatsNewSection({super.key});

  /// Short, tester-facing highlights for the current testing release. Kept to a
  /// handful of concise bullets and updated when cutting a new build; exposed so
  /// the widget test can assert each line renders without duplicating the copy.
  static const List<String> releaseNotes = <String>[
    'Plex tracks can now be downloaded for offline playback.',
    'Cached tracks play from your device, and fall back to streaming if a '
        'file is missing or unreadable.',
    'Offline downloads are now written atomically, so an interrupted '
        "download can't leave a broken file.",
    'Reproducible per-ABI release builds for F-Droid.',
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
                  Icons.auto_awesome_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text("What's new", style: theme.textTheme.titleMedium),
                ),
                // Ties the highlights below to the build the tester is running.
                Text(
                  'Version ${AppInfo.version}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < releaseNotes.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: AppSpacing.sm),
              _NoteBullet(text: releaseNotes[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// A single highlight line: a small accent bullet and the note text, aligned to
/// the top so a wrapped line keeps the bullet at the first row.
class _NoteBullet extends StatelessWidget {
  const _NoteBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? body = theme.textTheme.bodyMedium;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('•', style: body?.copyWith(color: theme.colorScheme.primary)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: body)),
      ],
    );
  }
}
