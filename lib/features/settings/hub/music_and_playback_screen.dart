import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/platform/host_platform.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../desktop/desktop_window_section.dart';
import '../playback/audio_output_settings_section.dart';
import '../playback/playback_settings_section.dart';
import '../source/default_provider_section.dart';
import '../source/playback_source_strategy_section.dart';
import 'settings_detail_scaffold.dart';

/// The "Music & playback" page of the Settings hub.
///
/// Groups the choices about *which* copy of a song plays and *how* it sounds:
/// the default source, the playback source strategy, volume normalization, and
/// (where the platform lets Linthra route audio itself) which output device
/// plays. Each card is the existing section, unchanged: nothing here touches
/// the playback engine or provider logic.
///
/// On a desktop host it also carries the close-window behaviour (#401): what
/// closing the window does is a playback choice there, since the answer is
/// whether the music keeps going. Android never shows it, because closing a
/// window is not something Android does.
class MusicAndPlaybackScreen extends ConsumerWidget {
  const MusicAndPlaybackScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HostPlatform host = ref.watch(hostPlatformProvider);
    return SettingsDetailScaffold(
      title: 'Music & playback',
      children: <Widget>[
        const DefaultProviderSettingsSection(),
        const SizedBox(height: AppSpacing.md),
        const PlaybackSourceStrategySettingsSection(),
        const SizedBox(height: AppSpacing.md),
        const PlaybackSettingsSection(),
        // Renders nothing where output routing belongs to the system (Android).
        const SizedBox(height: AppSpacing.md),
        const AudioOutputSettingsSection(),
        if (host.isDesktop) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          const DesktopWindowSettingsSection(),
        ],
      ],
    );
  }
}
