import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/sources/local/android_media_library.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../library/library_providers.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';
import 'local_music_controller.dart';

/// Settings home for music already stored on the device.
///
/// Android deliberately exposes two privacy levels: device-wide MediaStore
/// access, or a targeted SAF folder grant. Android 13+ names the device-wide
/// runtime permission "Music and audio"; Android 12 and older use the legacy
/// shared-storage read permission instead. The UI states that distinction so
/// no local access is a "ghost" setting.
class LocalMusicSettingsSection extends ConsumerWidget {
  const LocalMusicSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final List<String> folders =
        ref.watch(selectedFolderControllerProvider).valueOrNull ?? <String>[];
    final LocalScanReport? report = ref.watch(localScanReportProvider);
    final LocalMusicActionState action =
        ref.watch(localMusicControllerProvider);
    final Map<String, bool> access =
        ref.watch(localFolderAccessProvider).valueOrNull ?? <String, bool>{};
    final bool hasFolder = folders.isNotEmpty;
    final HostPlatform host = ref.watch(hostPlatformProvider);
    final FolderLocation? location =
        hasFolder ? FolderLocation.parse(folders.first) : null;
    final AndroidMusicPermissionStatus? musicPermission = host.isAndroid
        ? ref.watch(androidMusicPermissionStatusProvider).valueOrNull
        : null;
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
                Icon(
                  Icons.folder_special_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('Local music', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _blurbFor(host),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (host.isAndroid) ...[
              const SizedBox(height: AppSpacing.md),
              _AndroidPrivacyStatus(
                permission: musicPermission,
                location: location,
                onOpenSettings: controller.openAndroidPermissions,
                onRefresh: controller.refreshAndroidPermissionStatus,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            if (hasFolder)
              _SelectedFoldersView(
                folders: folders,
                access: access,
                report: report,
                host: host,
                // Removing a folder is a desktop affordance: Android holds a
                // single grant at a time, which "Forget local music" covers.
                onRemove: host.isAndroid ? null : controller.removeFolder,
              )
            else
              Text(
                'No local music source selected yet.',
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
                onAdd: host.isAndroid ? null : controller.addFolder,
                onForget: controller.forget,
                onUseAllDeviceMusic:
                    host.isAndroid && !location!.isAndroidMediaStore
                        ? controller.useAllDeviceMusic
                        : null,
                host: host,
              )
            else if (host.isAndroid)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: controller.useAllDeviceMusic,
                    icon: const Icon(Icons.library_music_outlined),
                    label: const Text('All music on this device'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: controller.pickFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Select a folder'),
                  ),
                ],
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

String _blurbFor(HostPlatform host) {
  if (host.isAndroid) {
    return 'Choose all music on this device for device-wide MediaStore access, '
        'or select one folder for narrower Android folder access. Android 13+ '
        'uses the Music and audio permission; Android 12 and older use the '
        'legacy shared-storage read permission. Linthra never requests All '
        'files access.';
  }
  return 'Play music from folders on this computer or on external drives. Add '
      'as many as you like — they are scanned together as one library. Linthra '
      'reads only the folders you choose in the system file chooser: it needs '
      'no broad filesystem permission, and your files are never moved or '
      'copied.';
}

class _AndroidPrivacyStatus extends StatelessWidget {
  const _AndroidPrivacyStatus({
    required this.permission,
    required this.location,
    required this.onOpenSettings,
    required this.onRefresh,
  });

  final AndroidMusicPermissionStatus? permission;
  final FolderLocation? location;
  final VoidCallback onOpenSettings;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Privacy & permissions', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Device music access: ${_permissionLabel(permission)}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _accessExplanation(location),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                TextButton(
                  onPressed: onOpenSettings,
                  child: const Text('Android settings'),
                ),
                TextButton(
                  onPressed: onRefresh,
                  child: const Text('Refresh status'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _permissionLabel(AndroidMusicPermissionStatus? status) {
    switch (status) {
      case AndroidMusicPermissionStatus.allowed:
        return 'Allowed';
      case AndroidMusicPermissionStatus.denied:
        return 'Denied';
      case AndroidMusicPermissionStatus.notRequested:
        return 'Not requested';
      case AndroidMusicPermissionStatus.unavailable:
        return 'Unavailable';
      case null:
        return 'Checking…';
    }
  }

  static String _accessExplanation(FolderLocation? location) {
    if (location?.isAndroidMediaStore ?? false) {
      return 'Local library mode: all device music through Android MediaStore. '
          'Android 13+ exposes Music and audio; older Android versions use the '
          'legacy shared-storage read permission for this device-wide mode. '
          'Revoking that access stops this scan.';
    }
    if (location?.isContentUri ?? false) {
      return 'Selected folder: targeted Storage Access Framework grant. This '
          'folder grant may not appear as a normal Android runtime permission.';
    }
    return 'Device-wide access is requested only if you choose All music on '
        'this device. Folder access stays targeted and separate.';
  }
}

/// The folders the user has selected, one row each, with the access problems
/// attached to the folder they belong to rather than to the library as a whole.
class _SelectedFoldersView extends StatelessWidget {
  const _SelectedFoldersView({
    required this.folders,
    required this.access,
    required this.report,
    required this.host,
    this.onRemove,
  });

  final List<String> folders;
  final Map<String, bool> access;
  final LocalScanReport? report;
  final HostPlatform host;
  final void Function(String folder)? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (folders.length > 1) ...[
          Text(
            '${folders.length} folders',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        for (final String folder in folders)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: _SelectedFolderRow(
              location: FolderLocation.parse(folder),
              reachable: access[folder],
              onRemove: onRemove == null ? null : () => onRemove!(folder),
            ),
          ),
        if (report != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ScanSummary(report: report!, host: host),
        ],
      ],
    );
  }
}

class _SelectedFolderRow extends StatelessWidget {
  const _SelectedFolderRow({
    required this.location,
    required this.reachable,
    this.onRemove,
  });

  final FolderLocation location;
  final bool? reachable;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final bool isDeviceLibrary = location.isAndroidMediaStore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isDeviceLibrary
                  ? Icons.library_music_outlined
                  : Icons.folder_outlined,
              size: 20,
              color: muted,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                location.displayLabel,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onRemove != null)
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove this folder',
              ),
          ],
        ),
        if (reachable == false) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            isDeviceLibrary
                ? 'Device music access is currently off. Your indexed library '
                    'stays in Linthra; re-enable access to rescan.'
                : 'Linthra can no longer reach this folder. Its music stays in '
                    'your library; select the folder again to restore access.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}

/// The recap of the last scan.
///
/// It describes *the scan the report came from*, not whatever source happens to
/// be selected right now: trying device-wide mode and failing leaves the old
/// folder selected while the newest report is a MediaStore one, and telling
/// that user to reselect a folder Linthra never scanned would be nonsense. So
/// the source kind is read off the report itself.
class _ScanSummary extends StatelessWidget {
  const _ScanSummary({required this.report, required this.host});

  final LocalScanReport report;
  final HostPlatform host;

  bool get isDeviceLibrary => report.isDeviceLibrary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String? counts = report.hadError ? null : _counts(report);
    final String? hint = _hint(report, host, isDeviceLibrary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _headline(report, isDeviceLibrary),
          style: theme.textTheme.bodyMedium,
        ),
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

  static String _headline(LocalScanReport report, bool isDeviceLibrary) {
    if (report.hadError) return "Last scan couldn't finish";
    if (report.importedTracks > 0) {
      final String word = report.importedTracks == 1 ? 'track' : 'tracks';
      return 'Last scan: ${report.importedTracks} $word added';
    }
    return isDeviceLibrary
        ? 'Last scan: no music on this device'
        : 'Last scan: no tracks found';
  }

  static String _counts(LocalScanReport report) {
    final List<String> parts = <String>[
      if (report.rootsScanned > 1)
        '${report.rootsAvailable}/${report.rootsScanned} folders read',
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

  static String? _hint(
    LocalScanReport report,
    HostPlatform host,
    bool isDeviceLibrary,
  ) {
    // A partial scan is the multi-folder case worth explaining first: some
    // folders were refreshed, one was not, and the music of the one that was
    // not is still there. Said before the "no tracks" advice below, because it
    // is the reason the counts look short.
    if (report.isPartial) {
      // A partial scan always has at least two folders: one folder failing on
      // its own is a plain error, so the plural here is always right.
      return '${report.rootsUnavailable} of ${report.rootsScanned} folders '
          "couldn't be read. Their music stays in your library — reconnect the "
          'drive or select the folder again, then rescan.';
    }
    if (report.importedTracks > 0) return null;
    // A revoked Music and audio permission is recovered in Android's app
    // settings, whichever source is selected.
    if (report.error == LocalScanError.mediaPermission) {
      return 'Device music access is off. Re-enable it in Android settings or '
          'select a folder instead.';
    }
    // Device-wide mode has no folder to reselect: an empty or failed MediaStore
    // scan must never point at the folder chooser.
    if (isDeviceLibrary) {
      if (report.hadError) {
        return "Linthra couldn't read Android's shared music library. Try "
            'scanning this device again. Your indexed music stays as it is.';
      }
      return "Android's music library reported no audio on this device. Music "
          'added since the last scan shows up after another scan.';
    }
    final bool blocked = report.hadError ||
        report.readFailures > 0 ||
        (report.isContentUri && report.filesVisited == 0);
    if (blocked) {
      final String sdNote =
          report.isContentUri ? ' — common with SD cards' : '';
      return "Linthra couldn't read this folder$sdNote. Select it again with "
          '${_chooserName(host)} to restore access.';
    }
    return "This folder doesn't seem to contain audio Linthra recognizes. Check "
        'that it has supported audio files (like MP3, M4A, FLAC, or OGG), or '
        'select the folder again with ${_chooserName(host)}.';
  }

  static String _chooserName(HostPlatform host) =>
      host.isAndroid ? "Android's folder chooser" : 'the system folder chooser';
}

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

class _FolderActions extends StatelessWidget {
  const _FolderActions({
    required this.onRescan,
    required this.onChange,
    required this.onForget,
    required this.host,
    this.onAdd,
    this.onUseAllDeviceMusic,
  });

  final VoidCallback onRescan;
  final VoidCallback onChange;
  final VoidCallback onForget;

  /// Adds another folder to the library. Null on Android, which holds a single
  /// local grant at a time.
  final VoidCallback? onAdd;
  final VoidCallback? onUseAllDeviceMusic;
  final HostPlatform host;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onUseAllDeviceMusic != null) ...[
          FilledButton.icon(
            onPressed: onUseAllDeviceMusic,
            icon: const Icon(Icons.library_music_outlined),
            label: const Text('All music on this device'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
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
                onPressed: onAdd ?? onChange,
                icon: Icon(
                  onAdd != null
                      ? Icons.create_new_folder_outlined
                      : Icons.folder_open_outlined,
                ),
                label: Text(
                  onAdd != null
                      ? 'Add a folder'
                      : host.isAndroid
                          ? 'Use a folder'
                          : 'Change',
                ),
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
            label: const Text('Forget local music'),
          ),
        ),
      ],
    );
  }
}

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
