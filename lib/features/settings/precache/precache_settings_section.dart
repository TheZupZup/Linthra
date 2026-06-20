import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/repositories/download_preferences.dart';
import '../../downloads/download_providers.dart';

/// The smart pre-cache card on the Settings screen.
///
/// Exposes the two pre-cache choices — on/off and how many upcoming tracks to
/// warm — and explains the distinction the feature lives or dies on: smart
/// pre-cache is **automatic and evictable** (it may be removed automatically to
/// stay under the cache limit), whereas **Keep offline** (a manual download) is
/// **protected** and never removed automatically. The widget never caches or
/// evicts anything itself — it only writes the user's choices back through the
/// preference controllers; the `SmartPrecacheService` and cache policy do the
/// rest, honouring the cache limit and the "Allow mobile data" setting.
class PrecacheSettingsSection extends ConsumerWidget {
  const PrecacheSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    final AsyncValue<bool> enabled = ref.watch(smartPrecacheEnabledProvider);
    final bool isOn = enabled.valueOrNull ?? true;
    final int count =
        ref.watch(precacheCountProvider).valueOrNull ?? kDefaultPrecacheCount;

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
                Icon(Icons.auto_awesome_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Smart pre-cache', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Linthra quietly caches the next few tracks in your queue so they '
              'play instantly — even offline. Pre-cached tracks are automatic '
              'and may be removed automatically to stay under your cache limit.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'To keep a song for good, use "Keep offline" on a download — '
              'pinned tracks are protected and never removed automatically.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.bolt_outlined),
              title: const Text('Pre-cache upcoming tracks'),
              subtitle: const Text(
                  'Follows your mobile-data setting and cache limit'),
              value: isOn,
              onChanged: enabled.isLoading
                  ? null
                  : (bool value) => ref
                      .read(smartPrecacheEnabledProvider.notifier)
                      .setEnabled(value),
            ),
            const SizedBox(height: AppSpacing.xs),
            _SongsToPrecacheTile(
              count: count,
              enabled: isOn,
              onChange: () => _changeCount(context, ref, count),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeCount(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) async {
    final int? chosen = await showDialog<int>(
      context: context,
      builder: (_) => _PrecacheCountDialog(current: current),
    );
    if (chosen != null) {
      await ref.read(precacheCountProvider.notifier).setCount(chosen);
    }
  }
}

/// The "Songs to pre-cache" row: shows the current count and a Change button
/// that opens the picker. Greyed out (and inert) while smart pre-cache is off,
/// so it reads as "this tunes the feature above".
class _SongsToPrecacheTile extends StatelessWidget {
  const _SongsToPrecacheTile({
    required this.count,
    required this.enabled,
    required this.onChange,
  });

  final int count;
  final bool enabled;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Songs to pre-cache', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    count == 1 ? '1 upcoming track' : '$count upcoming tracks',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(
              onPressed: enabled ? onChange : null,
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Songs to pre-cache" picker: the named [kPrecacheCountOptions] presets
/// plus a custom value, bounded to [kMinPrecacheCount]–[kMaxPrecacheCount] so a
/// hand-typed number can never queue a flood of downloads. Mirrors the cache
/// size "Change limit" dialog so the two settings feel the same.
class _PrecacheCountDialog extends StatefulWidget {
  const _PrecacheCountDialog({required this.current});

  final int current;

  @override
  State<_PrecacheCountDialog> createState() => _PrecacheCountDialogState();
}

class _PrecacheCountDialogState extends State<_PrecacheCountDialog> {
  late bool _custom;
  late int _selectedPreset;
  late final TextEditingController _customController;

  @override
  void initState() {
    super.initState();
    _custom = !isPrecacheCountPreset(widget.current);
    _selectedPreset = isPrecacheCountPreset(widget.current)
        ? widget.current
        : kDefaultPrecacheCount;
    _customController = TextEditingController(text: '${widget.current}');
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  /// The count the dialog would save, or null when the custom field is empty or
  /// non-positive (so Save is disabled). An in-range custom number is kept; an
  /// over-range one is capped at [kMaxPrecacheCount].
  int? get _resolvedCount {
    if (!_custom) return _selectedPreset;
    final int? typed = int.tryParse(_customController.text.trim());
    if (typed == null || typed <= 0) return null;
    return sanitizePrecacheCount(typed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Songs to pre-cache'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final int preset in kPrecacheCountOptions)
              RadioListTile<int>(
                contentPadding: EdgeInsets.zero,
                title: Text('$preset'),
                value: preset,
                groupValue: _custom ? null : _selectedPreset,
                onChanged: (value) => setState(() {
                  _custom = false;
                  if (value != null) _selectedPreset = value;
                }),
              ),
            RadioListTile<bool>(
              contentPadding: EdgeInsets.zero,
              title: const Text('Custom'),
              value: true,
              groupValue: _custom,
              onChanged: (_) => setState(() => _custom = true),
            ),
            if (_custom)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.md),
                child: TextField(
                  controller: _customController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Songs',
                    helperText:
                        'Between $kMinPrecacheCount and $kMaxPrecacheCount',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _resolvedCount == null
              ? null
              : () => Navigator.of(context).pop(_resolvedCount),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
