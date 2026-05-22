import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

/// Create and edit playlists. Placeholder until the playlists feature lands.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      body: const EmptyState(
        icon: Icons.queue_music_outlined,
        title: 'No playlists yet',
        message: 'Your playlists will appear here.',
      ),
    );
  }
}
