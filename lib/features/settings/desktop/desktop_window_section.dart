import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/desktop_close_behavior.dart';
import 'close_behavior_controller.dart';
import 'desktop_window_providers.dart';

/// The "Desktop window" card on the Music & playback settings page.
///
/// Desktop-only (the screen decides that), because it configures something
/// Android does not have: what closing the window does. Background playback is
/// an opt-in, and the card says plainly what it does and when it ends, so
/// nobody has to guess why Linthra is still in their media controls.
class DesktopWindowSettingsSection extends ConsumerWidget {
  const DesktopWindowSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final AsyncValue<DesktopCloseBehavior> behavior =
        ref.watch(desktopCloseBehaviorControllerProvider);
    final DesktopCloseBehavior selected =
        behavior.valueOrNull ?? DesktopCloseBehavior.defaultBehavior;

    void choose(DesktopCloseBehavior? value) {
      // Ignore taps until the stored choice has loaded, so a fast tap cannot
      // be overwritten by the value still on its way in from storage.
      if (value == null || behavior.isLoading) return;
      ref
          .read(desktopCloseBehaviorControllerProvider.notifier)
          .setBehavior(value);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.desktop_windows_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('Desktop window', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Choose what closing the window does. Keeping playback running '
              'hides the window and leaves your desktop media controls '
              'working, but only while something is playing: with nothing to '
              'play, closing the window still quits.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            RadioGroup<DesktopCloseBehavior>(
              groupValue: selected,
              onChanged: choose,
              child: Column(
                children: [
                  for (final DesktopCloseBehavior option
                      in DesktopCloseBehavior.values)
                    RadioListTile<DesktopCloseBehavior>(
                      contentPadding: EdgeInsets.zero,
                      value: option,
                      title: Text(option.label),
                      subtitle: Text(option.description),
                    ),
                ],
              ),
            ),
            const Divider(height: AppSpacing.lg),
            const QuitLinthraTile(),
          ],
        ),
      ),
    );
  }
}

/// The way out that is always available, whatever the close behaviour is set
/// to: it releases audio, the desktop media controls and the database, then
/// ends the process.
///
/// It earns its place in background mode, where a closed window is no longer
/// the way to quit. A desktop shell's media controls offer the same Quit over
/// MPRIS, for when there is no window on screen at all.
class QuitLinthraTile extends ConsumerWidget {
  const QuitLinthraTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.power_settings_new_outlined),
      title: const Text('Quit Linthra now'),
      subtitle: const Text(
        'Stops playback and closes the app, background playback included.',
      ),
      onTap: () => ref.read(desktopWindowLifecycleServiceProvider).quit(),
    );
  }
}
