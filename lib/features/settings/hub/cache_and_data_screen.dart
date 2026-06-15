import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../cache/cache_settings_section.dart';
import '../precache/precache_settings_section.dart';
import 'settings_detail_scaffold.dart';

/// The "Cache & data" page of the Settings hub.
///
/// Groups the on-device storage Linthra manages itself: the smart pre-cache and
/// the cache-size limit (with "Free up storage"). The Wi-Fi / mobile-data
/// download policy lives on the "Offline & downloads" page instead, since it is
/// about *when* downloads run rather than *how much* they keep.
class CacheAndDataScreen extends StatelessWidget {
  const CacheAndDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsDetailScaffold(
      title: 'Cache & data',
      children: <Widget>[
        CacheSettingsSection(),
        SizedBox(height: AppSpacing.md),
        PrecacheSettingsSection(),
      ],
    );
  }
}
