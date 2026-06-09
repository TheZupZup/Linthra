import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/cache_size.dart';
import '../../../core/services/offline_cache_manager.dart';
import '../../../data/repositories/download_repository_provider.dart';
import '../../downloads/download_providers.dart';

/// The offline-cache card on the Settings screen.
///
/// Shows how much app-managed space is in use against the user's limit, and
/// exposes the two controls: change the limit, and clear the cache. The widget
/// never deletes files or computes eviction itself — every action is forwarded
/// to the [OfflineCacheManager] / preferences, which own that policy.
class CacheSettingsSection extends ConsumerWidget {
  const CacheSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final int maxBytes =
        ref.watch(maxCacheBytesControllerProvider).valueOrNull ??
            CacheSize.defaultLimit;
    final CacheSnapshot snapshot =
        ref.watch(cacheSnapshotProvider).valueOrNull ?? CacheSnapshot.empty;

    final int used = snapshot.usedBytes;
    final int available = used >= maxBytes ? 0 : maxBytes - used;
    final double fraction =
        maxBytes <= 0 ? 0 : (used / maxBytes).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sd_storage_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Offline downloads & cache',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Offline downloads are songs you download to play offline. Cache '
              'is storage Linthra manages automatically to make playback faster '
              'and available offline. Both share this space and stay under your '
              'limit; when it fills, cached then least-recently-played tracks go '
              'first — your offline downloads and the track playing now are '
              'kept. (Local music lives on the device and is not stored here.)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${CacheSize.formatBytes(used)} of '
                  '${CacheSize.formatBytes(maxBytes)} used',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  '${CacheSize.formatBytes(available)} free',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _changeLimit(context, ref, maxBytes),
                    icon: const Icon(Icons.tune_outlined),
                    label: const Text('Change limit'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: snapshot.entries.isEmpty
                        ? null
                        : () => _clearCache(context, ref),
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Free up storage'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeLimit(
    BuildContext context,
    WidgetRef ref,
    int currentBytes,
  ) async {
    final int? chosen = await showDialog<int>(
      context: context,
      builder: (_) => _CacheLimitDialog(currentBytes: currentBytes),
    );
    if (chosen != null) {
      await ref.read(maxCacheBytesControllerProvider.notifier).setLimit(chosen);
    }
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final _ClearChoice? choice = await showDialog<_ClearChoice>(
      context: context,
      builder: (_) => const _ClearCacheDialog(),
    );
    if (choice == null) return;
    final manager = ref.read(offlineCacheManagerProvider);
    switch (choice) {
      case _ClearChoice.unpinned:
        await manager.clearUnpinned();
      case _ClearChoice.all:
        await manager.clearAll();
    }
  }
}

/// The "Change limit" dialog: the named presets plus a custom value in GB.
class _CacheLimitDialog extends StatefulWidget {
  const _CacheLimitDialog({required this.currentBytes});

  final int currentBytes;

  @override
  State<_CacheLimitDialog> createState() => _CacheLimitDialogState();
}

class _CacheLimitDialogState extends State<_CacheLimitDialog> {
  late bool _custom;
  late final TextEditingController _customController;
  late int _selectedPreset;

  @override
  void initState() {
    super.initState();
    _custom = !CacheSize.isPreset(widget.currentBytes);
    _selectedPreset = CacheSize.isPreset(widget.currentBytes)
        ? widget.currentBytes
        : CacheSize.defaultLimit;
    final double gb = widget.currentBytes / CacheSize.bytesPerGb;
    final String gbText = gb == gb.roundToDouble()
        ? gb.toStringAsFixed(0)
        : gb.toStringAsFixed(1);
    _customController = TextEditingController(text: gbText);
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  int? get _resolvedBytes {
    if (!_custom) return _selectedPreset;
    final double? gb = double.tryParse(_customController.text.trim());
    if (gb == null || gb <= 0) return null;
    return CacheSize.clamp(CacheSize.gigabytes(gb));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Maximum cache size'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final int preset in CacheSize.presets)
              RadioListTile<int>(
                contentPadding: EdgeInsets.zero,
                title: Text(CacheSize.formatBytes(preset)),
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
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Size',
                    suffixText: 'GB',
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
          onPressed: _resolvedBytes == null
              ? null
              : () => Navigator.of(context).pop(_resolvedBytes),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

enum _ClearChoice { unpinned, all }

/// The "Clear cache" dialog: free unpinned downloads, or everything.
class _ClearCacheDialog extends StatelessWidget {
  const _ClearCacheDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Free up storage'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear cache'),
            subtitle: const Text(
              'Free cached tracks. Keeps songs you downloaded for offline.',
            ),
            onTap: () => Navigator.of(context).pop(_ClearChoice.unpinned),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('Clear offline downloads'),
            subtitle: const Text(
              'Remove every downloaded and cached track.',
            ),
            onTap: () => Navigator.of(context).pop(_ClearChoice.all),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
