import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/diagnostics/app_diagnostics.dart';
import '../../core/diagnostics/playback_failure_report.dart';
import '../../core/models/playback_failure.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_diagnostics.dart';
import '../../core/sources/music_provider.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../library/source_availability_providers.dart';
import '../settings/diagnostics/diagnostics_collector.dart';
import '../settings/diagnostics/linux_playback_diagnostics_collector.dart';
import 'player_providers.dart';

/// Works out the details of a failure on a track.
typedef PlaybackFailureDetailsBuilder = PlaybackFailureDetails Function(
  PlaybackFailure failure,
  Track? track,
);

/// The details of a failure, from what the app knows when they are opened:
/// the track's source, what the last check of that source found, and, for an
/// audio engine that won't start, which part of the Linux runtime is at fault.
final playbackFailureDetailsBuilderProvider =
    Provider<PlaybackFailureDetailsBuilder>((ref) {
  return (PlaybackFailure failure, Track? track) {
    final String? sourceId = track == null ? null : _sourceIdOf(track.uri);
    return PlaybackFailureDetails(
      failure: failure,
      sourceId: sourceId,
      availability: sourceId == null
          ? null
          : ref.read(sourceAvailabilityProvider)[sourceId],
      runtimeProblem: failure.kind.isEngineFailure
          ? ref.read(linuxPlaybackRuntimeProblemProvider)()
          : null,
    );
  };
});

/// The provider a track uri belongs to, or null for a uri no provider owns:
/// [MusicProviders.forTrackUri] answers "local" for anything it doesn't
/// recognize, which the details mustn't repeat as a fact.
String? _sourceIdOf(String uri) {
  final MusicProvider provider = MusicProviders.forTrackUri(uri);
  if (provider != MusicProviders.local) return provider.sourceId;
  final bool onDevice = uri.startsWith('/') ||
      uri.startsWith('file:') ||
      uri.startsWith('content:');
  return onDevice ? provider.sourceId : null;
}

/// Builds the text "Copy diagnostics" copies for a failure's details.
typedef PlaybackFailureReportBuilder = Future<String> Function(
  PlaybackFailureDetails details,
  Track? track,
);

/// Where the failure report gets the rest of the app's diagnostics from:
/// the same collector Settings > Diagnostics uses. A seam so a test can hand
/// it a snapshot without the whole app behind it.
final playbackFailureAppDiagnosticsProvider =
    Provider<Future<AppDiagnosticsData> Function()>((ref) {
  return DiagnosticsCollector(ref).collect;
});

/// The report builder the details sheet calls. It reuses the app diagnostics'
/// collector for everything that isn't about the failure itself (version,
/// platform, decoders, the source's status line), so the two reports never
/// describe the same app differently.
final playbackFailureReportBuilderProvider =
    Provider<PlaybackFailureReportBuilder>((ref) {
  return (PlaybackFailureDetails details, Track? track) async {
    AppDiagnosticsData app;
    try {
      app = await ref.read(playbackFailureAppDiagnosticsProvider)();
    } catch (_) {
      // The failure's own lines are what this report is for; it goes out
      // without the rest rather than not at all.
      app = AppDiagnosticsData(appVersion: AppInfo.version);
    }
    final String? id = track?.id;
    return PlaybackFailureReport.render(PlaybackFailureReportData(
      details: details,
      appVersion: app.appVersion,
      platform: ref.read(hostPlatformProvider).name,
      androidVersion: app.androidVersion,
      androidSdkInt: app.androidSdkInt,
      sourceStatus: _sourceStatus(details.sourceId, app),
      playbackStatus: ref.read(playbackControllerProvider).state.status.name,
      trackIdHash:
          id == null || id.isEmpty ? null : PlaybackDiagnostics.redactId(id),
      platformAudioFormats: app.platformAudioFormats,
      flacDecoding: app.flacDecoding,
    ));
  };
});

/// The app diagnostics' own status line for [sourceId], when it has one.
String? _sourceStatus(String? sourceId, AppDiagnosticsData app) {
  switch (sourceId) {
    case 'jellyfin':
      return app.jellyfinState;
    case 'subsonic':
      return app.subsonicState;
    case 'local':
      final bool? selected = app.localFolderSelected;
      if (selected == null) return null;
      return selected ? 'folder selected' : 'no folder selected';
    default:
      return null;
  }
}
