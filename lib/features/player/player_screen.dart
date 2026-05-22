import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

/// Full-screen now-playing view. Placeholder until playback is wired to the
/// PlaybackController. Pushed above the shell via AppRoutes.player.
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Now Playing')),
      body: const EmptyState(
        icon: Icons.music_note_outlined,
        title: 'Nothing playing',
        message: 'Pick a track to start listening.',
      ),
    );
  }
}
