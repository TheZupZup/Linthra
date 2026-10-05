import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/repositories/download_preferences.dart';
import '../../../data/repositories/download_repository_provider.dart';
import 'metered_network_wording.dart';

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

/// The "Wi-Fi & mobile data" card on the Settings screen ("Metered
/// connections" on a desktop, see [MeteredNetworkWording]).
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
    final MeteredNetworkWording wording = MeteredNetworkWording.of(context);

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
                Icon(wording.sectionIcon, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text(wording.sectionTitle, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              wording.sectionIntro,
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
    final MeteredNetworkWording wording = MeteredNetworkWording.of(context);

    return ListTile(
      contentPadding: contentPadding,
      leading: Icon(selected.icon),
      title: Text(wording.settingTitle),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(wording.label(selected)),
          Text(wording.description(selected)),
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
    final MeteredNetworkWording wording = MeteredNetworkWording.of(context);
    return AlertDialog(
      title: Text(wording.settingTitle),
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
                  title: Text(wording.label(profile)),
                  subtitle: Text(wording.description(profile)),
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
