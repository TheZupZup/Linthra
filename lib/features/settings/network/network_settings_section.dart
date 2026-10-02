import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/repositories/download_preferences.dart';
import '../../../data/repositories/download_repository_provider.dart';

/// Loads and persists the user's metered-network profile.
class MobileDataProfileController extends AsyncNotifier<MobileDataProfile> {
  @override
  Future<MobileDataProfile> build() {
    return ref.read(downloadPreferencesProvider).mobileDataProfile();
  }

  Future<void> setProfile(MobileDataProfile profile) async {
    await ref.read(downloadPreferencesProvider).setMobileDataProfile(profile);
    state = AsyncData<MobileDataProfile>(profile);
    // Downloads queued because mobile data wasn't allowed may run now. Not
    // awaited: they download in the background, and their rows show it.
    unawaited(ref.read(downloadRepositoryProvider).retryHeldDownloads());
  }
}

final mobileDataProfileControllerProvider =
    AsyncNotifierProvider<MobileDataProfileController, MobileDataProfile>(
  MobileDataProfileController.new,
);

/// The "Wi-Fi & mobile data" card on the Settings screen.
///
/// The selected profile is shared with the Downloads screen. It controls
/// whether explicit downloads may use metered networks and whether automatic
/// smart pre-cache should stay active.
class NetworkSettingsSection extends StatelessWidget {
  const NetworkSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

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
                  Icons.network_cell_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('Wi-Fi & mobile data', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Choose how Linthra uses metered networks such as LTE, 5G, or a '
              'metered Wi-Fi hotspot. Offline and unknown connections remain '
              'protected.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            const MobileDataDownloadsTile(contentPadding: EdgeInsets.zero),
          ],
        ),
      ),
    );
  }
}

/// Opens the three mobile-data profiles. The historical class name is retained
/// because this tile is shared by Settings and the Downloads screen.
class MobileDataDownloadsTile extends ConsumerWidget {
  const MobileDataDownloadsTile({super.key, this.contentPadding});

  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MobileDataProfile> profile =
        ref.watch(mobileDataProfileControllerProvider);
    final MobileDataProfile selected =
        profile.valueOrNull ?? MobileDataProfile.wifiOnly;

    return ListTile(
      contentPadding: contentPadding,
      leading: Icon(selected.icon),
      title: const Text('Mobile data usage'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(selected.label),
          Text(selected.description),
        ],
      ),
      isThreeLine: true,
      trailing: profile.isLoading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: profile.isLoading ? null : () => _choose(context, ref, selected),
    );
  }

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    MobileDataProfile selected,
  ) async {
    final MobileDataProfile? choice = await showDialog<MobileDataProfile>(
      context: context,
      builder: (_) => _MobileDataProfileDialog(selected: selected),
    );
    if (choice == null || choice == selected) return;
    await ref
        .read(mobileDataProfileControllerProvider.notifier)
        .setProfile(choice);
  }
}

class _MobileDataProfileDialog extends StatelessWidget {
  const _MobileDataProfileDialog({required this.selected});

  final MobileDataProfile selected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mobile data usage'),
      content: SingleChildScrollView(
        child: RadioGroup<MobileDataProfile>(
          groupValue: selected,
          onChanged: (MobileDataProfile? value) {
            if (value != null) Navigator.of(context).pop(value);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final MobileDataProfile profile in MobileDataProfile.values)
                RadioListTile<MobileDataProfile>(
                  contentPadding: EdgeInsets.zero,
                  value: profile,
                  secondary: Icon(profile.icon),
                  title: Text(profile.label),
                  subtitle: Text(profile.description),
                ),
            ],
          ),
        ),
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

extension MobileDataProfilePresentation on MobileDataProfile {
  String get label {
    switch (this) {
      case MobileDataProfile.wifiOnly:
        return 'Wi-Fi only';
      case MobileDataProfile.saveData:
        return 'Save data';
      case MobileDataProfile.unlimited:
        return 'Unlimited plan';
    }
  }

  String get description {
    switch (this) {
      case MobileDataProfile.wifiOnly:
        return 'Downloads and smart pre-cache wait for an unmetered network.';
      case MobileDataProfile.saveData:
        return 'Manual downloads may use mobile data. Smart pre-cache is paused.';
      case MobileDataProfile.unlimited:
        return 'Downloads and smart pre-cache may use mobile data.';
    }
  }

  IconData get icon {
    switch (this) {
      case MobileDataProfile.wifiOnly:
        return Icons.wifi;
      case MobileDataProfile.saveData:
        return Icons.data_saver_on;
      case MobileDataProfile.unlimited:
        return Icons.all_inclusive;
    }
  }
}
