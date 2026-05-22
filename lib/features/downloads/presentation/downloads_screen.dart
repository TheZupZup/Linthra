import 'package:flutter/material.dart';

import '../../../widgets/empty_state.dart';

/// Manage explicit, user-controlled downloads. Placeholder until the downloads
/// feature lands. Downloads are always user-initiated — never automatic.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: const EmptyState(
        icon: Icons.download_outlined,
        title: 'Nothing downloaded',
        message: 'Downloads you start will appear here.',
      ),
    );
  }
}
