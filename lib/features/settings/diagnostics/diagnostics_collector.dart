import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/diagnostics/app_diagnostics.dart';
import '../../../core/models/active_playback_output.dart';
import '../../../core/models/cast_state.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/services/active_playback_controller.dart';
import '../../../core/services/notification_permission.dart';
import '../../../core/services/playback_diagnostics.dart';
import '../../../core/services/stability_diagnostics.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../downloads/download_providers.dart';
import '../../player/cast/cast_providers.dart';
import '../../player/player_providers.dart';
import '../jellyfin/jellyfin_settings_controller.dart';
import '../jellyfin/jellyfin_settings_state.dart';
import '../subsonic/subsonic_settings_controller.dart';
import '../subsonic/subsonic_settings_state.dart';

/// Gathers the live, display-safe app state into an [AppDiagnosticsData] and
/// renders it through [AppDiagnostics].
///
/// It only ever reads already-secret-free values — the settings *states* (which
/// hold no token/password by design), host-only addresses, counts, and feature
/// flags — so nothing sensitive can be assembled here in the first place. The
/// rendering step ([AppDiagnostics.report]) is the second guard: it forces both
/// server addresses through `hostOnly`.
class DiagnosticsCollector {
  DiagnosticsCollector(this._ref);

  final Ref _ref;

  /// Builds the secret-free report text for the Copy/Save actions. Reads the
  /// library track count asynchronously; everything else is read synchronously
  /// from the current provider state.
  Future<String> buildReport() async {
    return AppDiagnostics.report(await collect());
  }

  /// Gathers the live, display-safe snapshot. Public so the "Report a bug" flow
  /// can render it with its own toggles via [AppDiagnostics.report].
  Future<AppDiagnosticsData> collect() async {
    final JellyfinSettingsState jellyfin =
        _ref.read(jellyfinSettingsControllerProvider);
    final SubsonicSettingsState subsonic =
        _ref.read(subsonicSettingsControllerProvider);
    final CastState cast = _ref.read(castServiceProvider).state;

    return AppDiagnosticsData(
      appVersion: AppInfo.version,
      androidVersion: _androidVersion(),
      // No device-model plugin is bundled, so this stays null rather than a
      // guess; the report omits the line entirely when absent.
      deviceModel: null,
      jellyfinState: _jellyfinStateLabel(jellyfin.phase),
      jellyfinHost: jellyfin.baseUrl,
      subsonicState: _subsonicStateLabel(subsonic),
      subsonicHost: subsonic.baseUrl,
      libraryTrackCount: await _libraryTrackCount(),
      cacheUsedBytes: _cacheUsedBytes(),
      cacheLimitBytes: _cacheLimitBytes(),
      playbackOutput: _playbackOutput(),
      playbackStatus: _playbackStatus(),
      currentTrackIdHash: _currentTrackIdHash(),
      lastErrorKind: jellyfin.errorKind?.name ?? subsonic.errorKind?.name,
      notificationPermission: (await _notificationPermission()).label,
      lastLifecycleState: StabilityDiagnostics.lastLifecycleState,
      playbackStateAtBackground: StabilityDiagnostics.playbackStateAtBackground,
      lastInterruptionKind: StabilityDiagnostics.lastInterruptionKind,
      castAvailable: cast.isAvailable,
      castConnected: cast.isConnected,
      androidAutoSupported: _androidAutoSupported(),
      // Offline caching/downloads are always available in the app; there is no
      // user switch that turns the cache off.
      offlineCacheEnabled: true,
      smartPrecacheEnabled: _ref.read(smartPrecacheEnabledProvider).valueOrNull,
    );
  }

  /// Reads (never prompts for) the notification permission state, so the report
  /// can show whether the media notification / lock-screen controls can appear.
  /// Best-effort: the seam returns `unknown` off Android and on any read error.
  Future<NotificationPermissionStatus> _notificationPermission() =>
      const PermissionHandlerNotificationPermission().status();

  String? _androidVersion() =>
      Platform.isAndroid ? Platform.operatingSystemVersion : null;

  bool _androidAutoSupported() => Platform.isAndroid;

  String _jellyfinStateLabel(JellyfinConnectionPhase phase) {
    switch (phase) {
      case JellyfinConnectionPhase.connected:
        return 'connected';
      case JellyfinConnectionPhase.tested:
        return 'tested (not signed in)';
      case JellyfinConnectionPhase.testing:
        return 'testing';
      case JellyfinConnectionPhase.signingIn:
        return 'signing in';
      case JellyfinConnectionPhase.disconnected:
        return 'disconnected';
    }
  }

  /// Subsonic is optional, so it is only reported once the user has touched it
  /// (a connection in progress, established, or at least an address entered).
  String? _subsonicStateLabel(SubsonicSettingsState state) {
    final bool present = state.phase != SubsonicConnectionPhase.disconnected ||
        (state.baseUrl != null && state.baseUrl!.isNotEmpty);
    if (!present) return null;
    switch (state.phase) {
      case SubsonicConnectionPhase.connected:
        return 'connected';
      case SubsonicConnectionPhase.tested:
        return 'tested (not signed in)';
      case SubsonicConnectionPhase.testing:
        return 'testing';
      case SubsonicConnectionPhase.signingIn:
        return 'signing in';
      case SubsonicConnectionPhase.disconnected:
        return 'disconnected';
    }
  }

  Future<int?> _libraryTrackCount() async {
    try {
      final tracks =
          await _ref.read(musicLibraryRepositoryProvider).getAllTracks();
      return tracks.length;
    } catch (_) {
      // A storage hiccup must not break the report; just omit the count.
      return null;
    }
  }

  int? _cacheUsedBytes() =>
      _ref.read(cacheSnapshotProvider).valueOrNull?.usedBytes;

  int? _cacheLimitBytes() =>
      _ref.read(maxCacheBytesControllerProvider).valueOrNull;

  String? _playbackOutput() {
    final controller = _ref.read(playbackControllerProvider);
    if (controller is! ActivePlaybackController) return null;
    switch (controller.activeOutput) {
      case ActivePlaybackOutput.local:
        return 'local';
      case ActivePlaybackOutput.cast:
        return 'cast';
    }
  }

  /// The current playback status as a stable enum name, or null when nothing is
  /// loaded (so a quiet, never-played session reports no line).
  String? _playbackStatus() {
    final PlaybackState state = _ref.read(playbackControllerProvider).state;
    if (state.currentTrack == null && state.status == PlaybackStatus.idle) {
      return null;
    }
    return state.status.name;
  }

  /// A non-reversible hash of the currently playing track's id (never the id,
  /// title, or URI), or null when nothing is playing.
  String? _currentTrackIdHash() {
    final String? id =
        _ref.read(playbackControllerProvider).state.currentTrack?.id;
    if (id == null || id.isEmpty) return null;
    return PlaybackDiagnostics.redactId(id);
  }
}

/// Builds the secret-free diagnostics report text on demand.
typedef DiagnosticsReportBuilder = Future<String> Function();

/// The report builder the Diagnostics section invokes. Production wires it to a
/// live [DiagnosticsCollector]; tests override it with a stub so the widget can
/// be exercised without the playback/cast plugins behind the collector.
final diagnosticsReportBuilderProvider = Provider<DiagnosticsReportBuilder>(
  (ref) => DiagnosticsCollector(ref).buildReport,
);
