import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

/// Simple, clean settings. Placeholder until the settings feature lands.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const EmptyState(
        icon: Icons.settings_outlined,
        title: 'Settings',
        message: 'Theme, downloads, and library options will live here.',
      ),
    );
  }
}
