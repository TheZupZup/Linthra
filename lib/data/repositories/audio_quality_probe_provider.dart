import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/audio_quality_probe.dart';
import '../../core/services/media_kit_audio_quality_probe.dart';

/// The seam Now Playing asks the engine's audio quality through.
///
/// Defaults to the unavailable probe, so tests never touch libmpv and every
/// platform without a readable engine hides the setting. The Linux build
/// applies [mediaKitAudioQualityProbeOverride]. Android has no probe yet:
/// just_audio does not pass ExoPlayer's track format up to Dart.
final audioQualityProbeProvider = Provider<AudioQualityProbe>(
  (ref) => const UnavailableAudioQualityProbe(),
);

/// Production binding for Linux, applied by `productionApplicationOverrides`.
final mediaKitAudioQualityProbeOverride =
    audioQualityProbeProvider.overrideWithValue(
  const MediaKitAudioQualityProbe(),
);
