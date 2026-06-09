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
          const SizedBox(height: AppSpacing.sm),
          _ScanSummary(report: report!),
        ],
      ],
    );
  }
}

/// A clear, secret-free recap of the last local scan, shown under the selected
/// folder: a status headline, the safe counts the scan produced, and — when the
/// scan turned up nothing playable — a calm, non-blaming hint on what to try.
///
/// Everything here derives from [LocalScanReport], which by construction holds
/// only booleans and counts (never a path, file name, or raw error), so nothing
/// private about the user's library can reach the card.
class _ScanSummary extends StatelessWidget {
  const _ScanSummary({required this.report});

  final LocalScanReport report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    // A scan that threw produced no trustworthy counts, so the breakdown is
    // dropped and only the status + hint are shown.
    final String? counts = report.hadError ? null : _counts(report);
    final String? hint = _hint(report);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_headline(report), style: theme.textTheme.bodyMedium),
        if (counts != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            counts,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.xs),
          _ScanHintLine(message: hint),
        ],
      ],
    );
  }

  /// The headline: what the scan did, in the user's terms. Imported-count first
  /// (the thing they care about), then the "nothing found" and "couldn't finish"
  /// cases — never a path or file name.
  static String _headline(LocalScanReport report) {
    if (report.hadError) {
      return "Last scan couldn't finish";
    }
    if (report.importedTracks > 0) {
      final String word = report.importedTracks == 1 ? 'track' : 'tracks';
      return 'Last scan: ${report.importedTracks} $word added';
    }
    return 'Last scan: no tracks found';
  }

  /// The secret-free count breakdown — folders and files seen, how many looked
  /// like audio, and how many were skipped or unreadable. Folders are omitted
  /// when zero (a filesystem-path scan reports no folder count).
  static String _counts(LocalScanReport report) {
    final List<String> parts = <String>[
      if (report.foldersVisited > 0)
        '${report.foldersVisited} '
            '${report.foldersVisited == 1 ? 'folder' : 'folders'}',
      '${report.filesVisited} ${report.filesVisited == 1 ? 'file' : 'files'}',
      '${report.audioCandidates} audio',
    ];
    if (report.skippedUnsupported > 0) {
      parts.add('${report.skippedUnsupported} skipped');
    }
    if (report.readFailures > 0) {
      parts.add('${report.readFailures} unreadable');
    }
    return parts.join(' · ');
  }

  /// A calm, non-blaming next step when the scan imported nothing. Two shapes: a
  /// likely access problem (the SD-card / lost-grant case) versus a folder that
  /// simply held no recognized audio. Both point at re-picking the folder with
  /// the Android chooser; neither faults the user.
  static String? _hint(LocalScanReport report) {
    if (report.importedTracks > 0) {
      return null;
    }
    final bool blocked = report.hadError ||
        report.readFailures > 0 ||
        (report.isContentUri && report.filesVisited == 0);
    if (blocked) {
      final String sdNote =
          report.isContentUri ? ' — common with SD cards' : '';
      return "Linthra couldn't read this folder$sdNote. Select it again with "
          "Android's folder chooser to restore access.";
    }
    return "This folder doesn't seem to contain audio Linthra recognizes. Check "
        'that it has supported audio files (like MP3, M4A, FLAC, or OGG), or '
        "select the folder again with Android's folder chooser.";
  }
}

/// One line of calm guidance (info icon + muted text) shown when a scan needs a
/// follow-up action. Kept visually lighter than [_StatusLine] so a longer hint
/// reads as help, not an alarm.
class _ScanHintLine extends StatelessWidget {
  const _ScanHintLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
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
