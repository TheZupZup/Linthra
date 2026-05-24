import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/cache_size.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../shared/widgets/empty_state.dart';
import 'download_providers.dart';

/// Manage explicit, user-controlled downloads. Lists the tracks the user has
/// marked for offline use — with their cache size and a "Keep offline" pin —
/// shows how much cache is in use, and exposes the "Wi-Fi only" preference.
/// Downloads are always user-initiated — never automatic.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloaded = ref.watch(downloadedTracksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: Column(
        children: [
          const _CacheUsageHeader(),
          const _WifiOnlyToggle(),
          const Divider(height: 1),
          Expanded(child: _list(downloaded)),
        ],
      ),
    );
  }

  Widget _list(AsyncValue<List<Track>> downloaded) {
    return downloaded.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      // Never surface raw exception text (it can carry paths or store detail);
      // show one calm, friendly line instead.
      error: (_, __) => const EmptyState(
        icon: Icons.error_outline,
        title: "Couldn't load downloads",
        message:
            'Something went wrong reading your downloads. Try again later.',
      ),
      data: (tracks) {
        if (tracks.isEmpty) {
          return const EmptyState(
            icon: Icons.download_outlined,
            title: 'Nothing downloaded',
            message: 'Downloads you start will appear here.',
          );
        }
        return _DownloadedList(tracks: tracks);
      },
    );
  }
}

/// A slim "used of limit" header. The full controls (change limit, clear) live
/// on the Settings screen; this is a glanceable status line.
class _CacheUsageHeader extends ConsumerWidget {
  const _CacheUsageHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final int maxBytes =
        ref.watch(maxCacheBytesControllerProvider).valueOrNull ??
            CacheSize.defaultLimit;
    final CacheSnapshot snapshot =
        ref.watch(cacheSnapshotProvider).valueOrNull ?? CacheSnapshot.empty;
    final double fraction =
        maxBytes <= 0 ? 0 : (snapshot.usedBytes / maxBytes).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${CacheSize.formatBytes(snapshot.usedBytes)} of '
            '${CacheSize.formatBytes(maxBytes)} cache used',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

class _WifiOnlyToggle extends ConsumerWidget {
  const _WifiOnlyToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifiOnly = ref.watch(wifiOnlyControllerProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.wifi_outlined),
      title: const Text('Wi-Fi only'),
      subtitle: const Text('Queue downloads until Wi-Fi is available'),
      value: wifiOnly.valueOrNull ?? false,
      onChanged: wifiOnly.isLoading ? null : (value) => _set(ref, value),
    );
  }

  void _set(WidgetRef ref, bool value) {
    ref.read(wifiOnlyControllerProvider.notifier).setWifiOnly(value);
  }
}

class _DownloadedList extends ConsumerWidget {
  const _DownloadedList({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Map<String, CachedTrack> entries =
        ref.watch(cacheEntriesByIdProvider);
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final CachedTrack? entry = entries[track.id];
        final bool pinned = entry?.pinned ?? false;
        return ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _subtitle(track, entry),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                color: pinned ? Theme.of(context).colorScheme.primary : null,
                tooltip: pinned ? 'Unpin' : 'Keep offline',
                onPressed: () => ref
                    .read(offlineCacheManagerProvider)
                    .setPinned(track.id, !pinned),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove download',
                onPressed: () => ref
                    .read(downloadRepositoryProvider)
                    .removeDownload(track.id),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget? _subtitle(Track track, CachedTrack? entry) {
    final String? artist = track.artistName;
    final bool hasArtist = artist != null && artist.isNotEmpty;
    final bool hasSize = entry != null && entry.sizeBytes > 0;
    if (!hasArtist && !hasSize) return null;
    final String text = <String>[
      if (hasArtist) artist,
      if (hasSize) CacheSize.formatBytes(entry.sizeBytes),
    ].join('  •  ');
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
