import 'package:flutter/material.dart';

import '../../app/dimens.dart';
import 'cache/cache_settings_section.dart';
import 'jellyfin/jellyfin_settings_section.dart';

/// Settings. Hosts the connection/source and offline-storage options. Theme and
/// other options will join them here.
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
          SizedBox(height: AppSpacing.md),
          CacheSettingsSection(),
        ],
      ),
    );
  }
}
