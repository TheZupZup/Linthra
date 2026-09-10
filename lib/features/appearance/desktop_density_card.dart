import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/desktop_density.dart';
import '../../data/repositories/host_platform_provider.dart';
import 'desktop_density_controller.dart';

/// The Compact / Comfortable picker, shown in Settings → Appearance on desktop.
///
/// Renders nothing off desktop, the same way the Audio output card does: on a
/// phone the density is the platform's business (a thumb needs the touch
/// layout), so offering the control there would be offering a way to make the
/// app harder to use. Android therefore never sees this card *and* never reads
/// the preference — `LinthraApp` only applies it on a desktop host.
class DesktopDensityCard extends ConsumerWidget {
  const DesktopDensityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(hostPlatformProvider).isDesktop) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    final DesktopDensity selected = ref.watch(desktopDensityControllerProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.view_agenda_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Density',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              selected.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            // Same control as the theme-mode picker: one clear selected state
            // and the right semantics for screen readers for free.
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<DesktopDensity>(
                segments: <ButtonSegment<DesktopDensity>>[
                  for (final DesktopDensity density in DesktopDensity.values)
                    ButtonSegment<DesktopDensity>(
                      value: density,
                      label: Text(density.label),
                      icon: Icon(density.icon),
                      tooltip: density.label,
                    ),
                ],
                selected: <DesktopDensity>{selected},
                showSelectedIcon: false,
                onSelectionChanged: (Set<DesktopDensity> selection) {
                  ref
                      .read(desktopDensityControllerProvider.notifier)
                      .select(selection.first);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
