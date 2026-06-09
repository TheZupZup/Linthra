import 'package:flutter/material.dart';

import '../../app/dimens.dart';

/// A small, quiet group heading used to organise the Settings screen into
/// labelled sections (e.g. "Music sources", "Storage & offline").
///
/// It carries no behaviour — it only gives a run of setting cards a clear,
/// scannable title so related options read as a group and unrelated ones (like
/// music sources vs. storage) stop blurring together.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
