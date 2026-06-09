import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';
import 'local_music_controller.dart';

/// The "Local music" source card on the Settings screen, grouped with the other
/// music sources (Jellyfin, Navidrome/Subsonic).
///
/// This is the primary place to configure on-device music: choose a folder on
/// this phone or an SD card, rescan it, or forget it. It reuses the same pick +
/// scan path as the Library empty-state "Change folder" button, so the two stay
/// in sync. Everything it shows is read reactively from the selected-folder and
/// last-scan providers; the card itself holds no scanning logic.
///
/// "Local music" is deliberately distinct from two neighbours users conflate,
/// both of which live under Settings ▸ Storage & offline:
///  - Offline downloads — copies Linthra makes for offline playback of a server
///    track (the download action), and
///  - Cache — Linthra-managed storage that speeds playback up.
/// This card only points Linthra at music that already lives on the device.
class LocalMusicSettingsSection extends ConsumerWidget {
  const LocalMusicSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    final String? folder =
        ref.watch(selectedFolderControllerProvider).valueOrNull;
    final LocalScanReport? report = ref.watch(localScanReportProvider);
    final LocalMusicActionState action =
        ref.watch(localMusicControllerProvider);
    final bool? persisted = ref.watch(localFolderAccessProvider).valueOrNull;
    final bool hasFolder = folder != null && folder.isNotEmpty;

    final LocalMusicController controller =
        ref.read(localMusicControllerProvider.notifier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.folder_special_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Local music', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Play music from a folder on this device or an SD card. Linthra '
              "reads it through Android's folder access — it needs no broad "
              'storage permission, and your files are never moved or copied.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.md),
            if (hasFolder)
              _SelectedFolderView(
                folderLabel: FolderLocation.parse(folder).displayLabel,
                persisted: persisted,
                report: report,
              )
            else
              Text(
                'No folder selected yet.',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            const SizedBox(height: AppSpacing.md),
            if (action.busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (hasFolder)
              _FolderActions(
                onRescan: controller.rescan,
                onChange: controller.pickFolder,
                onForget: controller.forget,
              )
            else
              FilledButton.icon(
                onPressed: controller.pickFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Select a folder'),
              ),
            if (action.message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _StatusLine(message: action.message!, isError: action.isError),
            ],
          ],
        ),
      ),
    );
  }
}

/// The selected-folder summary: which folder, whether access is still held, and
/// what the last scan saw.
class _SelectedFolderView extends StatelessWidget {
  const _SelectedFolderView({
    required this.folderLabel,
    required this.persisted,
    required this.report,
  });

  final String folderLabel;
  final bool? persisted;
  final LocalScanReport? report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.folder_outlined, size: 20, color: muted),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                folderLabel,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (persisted == false) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Access to this folder was lost. Select it again to restore it.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (report != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            _scanSummary(report!),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }

  /// A short, secret-free recap of the last scan — counts only.
  static String _scanSummary(LocalScanReport report) {
    if (report.hadError) {
      return 'Last scan: failed. Try selecting the folder again.';
    }
    final StringBuffer summary = StringBuffer()
      ..write('Last scan: ${report.importedTracks} ')
      ..write(report.importedTracks == 1 ? 'track' : 'tracks')
      ..write(' from ${report.filesVisited} ')
      ..write(report.filesVisited == 1 ? 'file' : 'files')
      ..write(' in ${report.foldersVisited} ')
      ..write(report.foldersVisited == 1 ? 'folder' : 'folders');
    if (report.readFailures > 0) {
      summary.write(' · ${report.readFailures} unreadable');
    }
    return summary.toString();
  }
}

/// The Rescan / Change / Forget actions shown once a folder is selected.
class _FolderActions extends StatelessWidget {
  const _FolderActions({
    required this.onRescan,
    required this.onChange,
    required this.onForget,
  });

  final VoidCallback onRescan;
  final VoidCallback onChange;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onRescan,
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onChange,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Change'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onForget,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Forget folder'),
          ),
        ),
      ],
    );
  }
}

/// A friendly one-line status or error message under the actions.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color =
        isError ? theme.colorScheme.error : theme.colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isError ? Icons.error_outline : Icons.info_outline,
          size: 18,
          color: color,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
