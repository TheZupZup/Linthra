import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

/// Browse tracks, albums, and artists from the local catalog.
/// Placeholder until the library scanning + catalog feature lands.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: const EmptyState(
        icon: Icons.library_music_outlined,
        title: 'Your library is empty',
        message: 'Scan a folder to add your music. Coming soon.',
      ),
    );
  }
}
