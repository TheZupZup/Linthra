import 'package:flutter/material.dart';

import '../../app/dimens.dart';
import 'jellyfin/jellyfin_settings_section.dart';

/// Settings. Hosts the connection/source options; the Jellyfin section is the
/// first real entry. Theme, downloads, and other options will join it here.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: const [
          JellyfinSettingsSection(),
        ],
      ),
    );
  }
}
