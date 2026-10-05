import 'package:flutter/material.dart';

import '../../../core/repositories/download_preferences.dart';
import '../../../shared/layout/desktop_presentation.dart';

/// What the metered-network setting is called where it is shown.
///
/// A phone has mobile data, and the setting is named for it. A desktop has no
/// data plan of its own: what it meets is a connection the system marks as
/// metered, most often a phone's hotspot, so there it is named for that. The
/// setting, and what each profile lets through, are the same on both.
class MeteredNetworkWording {
  const MeteredNetworkWording._(this._desktop);

  factory MeteredNetworkWording.of(BuildContext context) =>
      MeteredNetworkWording._(usesDesktopPresentation(context));

  final bool _desktop;

  /// The icon beside the section's title.
  IconData get sectionIcon =>
      _desktop ? Icons.data_usage_outlined : Icons.network_cell_outlined;

  /// The title of the card the setting sits in.
  String get sectionTitle =>
      _desktop ? 'Metered connections' : 'Wi-Fi & mobile data';

  /// The line under [sectionTitle] saying what the setting is for.
  String get sectionIntro => _desktop
      ? 'Choose how Linthra uses connections your system marks as metered, '
          'such as a phone hotspot. Offline and unknown connections remain '
          'protected.'
      : 'Choose how Linthra uses metered networks such as LTE, 5G, or a '
          'metered Wi-Fi hotspot. Offline and unknown connections remain '
          'protected.';

  /// The setting's own row, and the title of the dialog it opens.
  String get settingTitle =>
      _desktop ? 'Downloads on metered connections' : 'Mobile data usage';

  /// The Settings hub's summary of the page the setting lives on.
  String get hubSubtitle => _desktop
      ? 'Metered connections and offline downloads'
      : 'Mobile data and offline downloads';

  /// The name of [profile].
  String label(MobileDataProfile profile) => switch (profile) {
        MobileDataProfile.wifiOnly =>
          _desktop ? 'Unmetered only' : 'Wi-Fi only',
        MobileDataProfile.saveData => 'Save data',
        MobileDataProfile.unlimited =>
          _desktop ? 'Unlimited' : 'Unlimited plan',
      };

  /// What [profile] lets downloads and smart pre-cache do.
  String description(MobileDataProfile profile) => switch (profile) {
        MobileDataProfile.wifiOnly => _desktop
            ? 'Downloads and smart pre-cache wait for an unmetered connection.'
            : 'Downloads and smart pre-cache wait for an unmetered network.',
        MobileDataProfile.saveData => _desktop
            ? 'Manual downloads may use a metered connection. Smart pre-cache '
                'is paused.'
            : 'Manual downloads may use mobile data. Smart pre-cache is paused.',
        MobileDataProfile.unlimited => _desktop
            ? 'Downloads and smart pre-cache may use a metered connection.'
            : 'Downloads and smart pre-cache may use mobile data.',
      };
}
