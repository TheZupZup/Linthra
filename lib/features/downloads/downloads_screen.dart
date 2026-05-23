import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/track.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../shared/widgets/empty_state.dart';
import 'download_providers.dart';

/// Manage explicit, user-controlled downloads. Lists the tracks the user has
/// marked for offline use and exposes the "Wi-Fi only" preference. Downloads
/// are always user-initiated — never automatic.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloaded = ref.watch(downloadedTracksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: Column(
        children: [
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
      error: (error, _) => Center(child: Text('$error')),
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
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _subtitle(track),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove download',
            padding: const EdgeInsets.all(AppSpacing.sm),
            onPressed: () =>
                ref.read(downloadRepositoryProvider).removeDownload(track.id),
          ),
        );
      },
    );
  }

  static Widget? _subtitle(Track track) {
    final artist = track.artistName;
    if (artist == null || artist.isEmpty) return null;
    return Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
