import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dimens.dart';
import '../../../app/routes.dart';

/// The "Report a bug" card on the Settings screen — the entry point into the
/// [BugReportScreen] flow.
///
/// It only opens the report builder; nothing is generated or sent from here, so
/// tapping it is always safe.
class ReportBugSettingsSection extends StatelessWidget {
  const ReportBugSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Report a bug', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Linthra can build a safe diagnostic report to help fix bugs. It '
              'is generated on your device — review it before sharing, then '
              'copy it or open a prefilled GitHub issue.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: () => context.push(AppRoutes.reportBug),
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Report a bug'),
            ),
          ],
        ),
      ),
    );
  }
}
