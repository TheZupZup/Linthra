import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/audio_output_device.dart';
import '../../../data/repositories/audio_output_device_service_provider.dart';
import 'audio_output_controller.dart';

/// The "Audio output" card on the Music & playback settings page.
///
/// Only shown where Linthra can actually route audio itself — Linux, through
/// libmpv. On Android the system owns output routing (the output picker,
/// Bluetooth, Android Auto), so the seam reports itself unsupported and this
/// widget renders nothing rather than offering a control that would fight the
/// platform.
///
/// The card never touches the audio engine directly: it reads and writes the
/// choice through [AudioOutputController], which applies it to the backend and
/// decides whether it is stable enough to remember.
class AudioOutputSettingsSection extends ConsumerStatefulWidget {
  const AudioOutputSettingsSection({super.key});

  @override
  ConsumerState<AudioOutputSettingsSection> createState() =>
      _AudioOutputSettingsSectionState();
}

class _AudioOutputSettingsSectionState
    extends ConsumerState<AudioOutputSettingsSection> {
  @override
  void initState() {
    super.initState();
    // Enumerating means asking libmpv, so it happens when the page is opened
    // rather than at launch. Deferred past the first frame so building this
    // widget never drives a provider mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AudioOutputSettingsState? current =
          ref.read(audioOutputControllerProvider).valueOrNull;
      if (current != null && current.hasEnumerated) return;
      ref.read(audioOutputControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(audioOutputDeviceServiceProvider).isSupported) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final AsyncValue<AudioOutputSettingsState> async =
        ref.watch(audioOutputControllerProvider);
    final AudioOutputSettingsState state =
        async.valueOrNull ?? const AudioOutputSettingsState();

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
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.speaker_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Audio output',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh outputs',
                  icon: const Icon(Icons.refresh),
                  onPressed: async.isLoading
                      ? null
                      : () => ref
                          .read(audioOutputControllerProvider.notifier)
                          .refresh(),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Choose which speakers, headset or DAC Linthra plays through. '
              '"System default" follows whatever your desktop is using.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.md),
            _OutputPicker(state: state, isBusy: async.isLoading),
            if (state.outputRecoveryFailed) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              // The one case where playback may not be coming out anywhere:
              // the chosen output went away and the system default was refused
              // too. Recoverable, and said so — never left silently muted.
              _Note(
                icon: Icons.volume_off_outlined,
                text: 'The audio output went away and Linthra could not fall '
                    'back to the system default, so playback may be silent. '
                    'Try again once your device is back.',
                color: theme.colorScheme.error,
                action: (
                  label: 'Try again',
                  onPressed: async.isLoading
                      ? null
                      : () => ref
                          .read(audioOutputControllerProvider.notifier)
                          .refresh(),
                ),
              ),
            ] else if (state.savedDeviceUnavailable) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              _Note(
                icon: Icons.info_outline,
                text: 'Your saved output is not available right now, so '
                    'playback is using the system default. It will be used '
                    'again as soon as it is back.',
                color: theme.colorScheme.tertiary,
              ),
            ],
            if (state.selectionFailed) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              _Note(
                icon: Icons.error_outline,
                text: 'That output could not be used, so playback stayed on '
                    '${state.selected.label}. Refresh the list and try again.',
                color: theme.colorScheme.error,
              ),
            ],
            if (!state.selected.isSystemDefault && !state.isRemembered) ...[
              const SizedBox(height: AppSpacing.sm),
              _Note(
                icon: Icons.history_toggle_off,
                text: 'This output is named by a handle that can change when '
                    'you plug something in, so it is used for this session '
                    'only.',
                color: muted,
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}

/// The device list itself: a dropdown once outputs are known, and an honest
/// line of text before that (or when the backend reported none).
class _OutputPicker extends ConsumerWidget {
  const _OutputPicker({required this.state, required this.isBusy});

  final AudioOutputSettingsState state;
  final bool isBusy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    if (state.devices.isEmpty) {
      return Text(
        state.hasEnumerated
            ? 'No outputs were reported by the audio backend. Playback uses '
                'the system default.'
            : 'Looking for audio outputs…',
        style: theme.textTheme.bodySmall?.copyWith(color: muted),
      );
    }

    // Guard the dropdown's contract: its value has to be one of its items, and
    // a device can disappear between a refresh and this rebuild.
    final bool selectedIsListed = state.devices.any(
      (AudioOutputDevice device) => device.id == state.selected.id,
    );
    final String value = selectedIsListed
        ? state.selected.id
        : AudioOutputDevice.systemDefaultId;

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Output device',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: value,
          onChanged: isBusy
              ? null
              : (String? id) {
                  if (id == null) return;
                  final AudioOutputDevice device = state.devices.firstWhere(
                    (AudioOutputDevice candidate) => candidate.id == id,
                    orElse: () => AudioOutputDevice.systemDefault,
                  );
                  ref
                      .read(audioOutputControllerProvider.notifier)
                      .select(device);
                },
          items: <DropdownMenuItem<String>>[
            for (final AudioOutputDevice device in state.devices)
              DropdownMenuItem<String>(
                value: device.id,
                child: Text(device.label, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    required this.color,
    this.action,
  });

  final IconData icon;
  final String text;
  final Color color;

  /// An optional way out of the state the note describes — the retry a failed
  /// recovery needs, so "playback may be silent" is never a dead end.
  final ({String label, VoidCallback? onPressed})? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ({String label, VoidCallback? onPressed})? action = this.action;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 16, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
              if (action != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: action.onPressed,
                    child: Text(action.label),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
