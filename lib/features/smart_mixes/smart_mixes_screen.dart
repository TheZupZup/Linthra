import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/models/smart_playlist.dart';
import '../../shared/widgets/empty_state.dart';
import 'smart_mix_providers.dart';

/// The "Smart mixes" section: automatic, Made-by-Linthra collections built from
/// on-device signals (library timestamps, play history, favourites, the offline
/// cache, the catalog). Each row opens the mix's tracks with Play / Shuffle.
class SmartMixesScreen extends ConsumerWidget {
  const SmartMixesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<SmartMixSummary>> mixes =
        ref.watch(smartMixesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Smart mixes')),
      body: mixes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const EmptyState(
          icon: Icons.error_outline,
          title: "Couldn't build your mixes",
          message: 'Try again in a moment.',
        ),
        data: (List<SmartMixSummary> items) => ListView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: items.length,
          itemBuilder: (context, index) => _SmartMixTile(summary: items[index]),
        ),
      ),
    );
  }
}

class _SmartMixTile extends StatelessWidget {
  const _SmartMixTile({required this.summary});

  final SmartMixSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;
    final int count = summary.trackCount;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: accent.withValues(alpha: 0.12),
        child: Icon(iconFor(summary.mix.kind), color: accent),
      ),
      title: Text(
        summary.mix.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${summary.mix.description} · '
        '$count ${count == 1 ? 'song' : 'songs'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(AppRoutes.smartMixPath(summary.mix.id)),
    );
  }

  /// The glyph for each mix. Kept with the UI (not the model) so the domain
  /// stays free of widget concerns.
  static IconData iconFor(SmartPlaylistKind kind) {
    switch (kind) {
      case SmartPlaylistKind.recentlyAdded:
        return Icons.library_add_outlined;
      case SmartPlaylistKind.recentlyPlayed:
        return Icons.history;
      case SmartPlaylistKind.mostPlayed:
        return Icons.trending_up;
      case SmartPlaylistKind.favorites:
        return Icons.favorite;
      case SmartPlaylistKind.downloaded:
        return Icons.download_done;
      case SmartPlaylistKind.random:
        return Icons.shuffle;
      case SmartPlaylistKind.neverPlayed:
        return Icons.auto_awesome;
    }
  }
}
