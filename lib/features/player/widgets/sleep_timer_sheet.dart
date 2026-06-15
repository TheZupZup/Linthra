import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../sleep_timer_controller.dart';

/// Opens the Sleep Timer as a compact Material 3 bottom sheet.
///
/// It reads the live [SleepTimerState], so it shows the running countdown (and a
/// Cancel action) when a timer is active, or the delay presets when it isn't.
Future<void> showSleepTimerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const SleepTimerSheet(),
  );
}

/// Formats [remaining] as a calm `M:SS` countdown (or `H:MM:SS` past an hour),
/// clamping a negative value to zero so the display never shows `-0:01`.
String formatSleepRemaining(Duration remaining) {
  final int totalSeconds = remaining.isNegative ? 0 : remaining.inSeconds;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
}

/// The Sleep Timer panel.
///
/// Minimal by design: a header, then either the live countdown with a Cancel
/// button (timer running) or the delay presets plus a Custom option (idle).
/// Every action goes through the [SleepTimerController] — the single owner of
/// the countdown — so the panel never touches playback directly.
class SleepTimerSheet extends ConsumerWidget {
  const SleepTimerSheet({super.key});

  /// The quick-pick delays, in minutes.
  static const List<int> presetMinutes = <int>[5, 10, 15, 20];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final SleepTimerState timer = ref.watch(sleepTimerControllerProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.bedtime_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Sleep timer', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (timer.isActive)
              _ActiveTimer(remaining: timer.remaining!)
            else
              const _TimerOptions(),
          ],
        ),
      ),
    );
  }
}

/// The idle view: a short prompt and the delay presets (plus Custom).
class _TimerOptions extends ConsumerWidget {
  const _TimerOptions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Pause playback after',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final int minutes in SleepTimerSheet.presetMinutes)
              ActionChip(
                label: Text('$minutes min'),
                onPressed: () => ref
                    .read(sleepTimerControllerProvider.notifier)
                    .start(Duration(minutes: minutes)),
              ),
            ActionChip(
              avatar: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Custom'),
              onPressed: () => _pickCustom(context, ref),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickCustom(BuildContext context, WidgetRef ref) async {
    final int? minutes = await showCustomSleepMinutesDialog(context);
    if (minutes == null) return;
    ref
        .read(sleepTimerControllerProvider.notifier)
        .start(Duration(minutes: minutes));
  }
}

/// The running view: the live countdown and a single Cancel action.
class _ActiveTimer extends ConsumerWidget {
  const _ActiveTimer({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Pausing playback in',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          formatSleepRemaining(remaining),
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall?.copyWith(
            color: theme.colorScheme.primary,
            // Tabular figures so the seconds digit doesn't jitter the layout as
            // it counts down.
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton.tonalIcon(
          onPressed: () =>
              ref.read(sleepTimerControllerProvider.notifier).cancel(),
          icon: const Icon(Icons.close),
          label: const Text('Cancel timer'),
        ),
      ],
    );
  }
}

/// Prompts for a custom delay in whole minutes, returning it (or null if the
/// listener dismissed the dialog). Kept simple: a single validated number field.
Future<int?> showCustomSleepMinutesDialog(BuildContext context) {
  return showDialog<int>(
    context: context,
    builder: (_) => const _CustomMinutesDialog(),
  );
}

class _CustomMinutesDialog extends StatefulWidget {
  const _CustomMinutesDialog();

  @override
  State<_CustomMinutesDialog> createState() => _CustomMinutesDialogState();
}

class _CustomMinutesDialogState extends State<_CustomMinutesDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final int? minutes = int.tryParse(_controller.text.trim());
    if (minutes == null || minutes <= 0) {
      setState(() => _error = 'Enter a whole number of minutes.');
      return;
    }
    Navigator.of(context).pop(minutes);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom sleep timer'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: 'Minutes',
          suffixText: 'min',
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Start'),
        ),
      ],
    );
  }
}
