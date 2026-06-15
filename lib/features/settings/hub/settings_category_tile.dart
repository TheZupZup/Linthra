import 'package:flutter/material.dart';

import '../../../app/dimens.dart';

/// One tappable category row on the Settings hub (e.g. "Connections",
/// "Cache & data").
///
/// It is presentation only: a tinted leading glyph, a title, a one-line
/// description, and a trailing chevron, wrapped in a Material 3 card that opens
/// [onTap]. Grouping the settings behind these rows is what turns the old long
/// technical form into a short, scannable hub — the actual settings live
/// unchanged on the page each row opens.
class SettingsCategoryTile extends StatelessWidget {
  const SettingsCategoryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  /// The category's glyph, shown in the tinted leading square.
  final IconData icon;

  /// The category's name (e.g. "Connections").
  final String title;

  /// A short line under the title naming what lives inside the category.
  final String subtitle;

  /// Opens the category's detail page.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: <Widget>[
              _CategoryIcon(icon: icon),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rounded, tinted glyph at the start of a category row. Mirrors the
/// leading icon the provider summary cards use, so the hub reads as part of the
/// same family of cards.
class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Icon(icon, color: theme.colorScheme.primary),
    );
  }
}
