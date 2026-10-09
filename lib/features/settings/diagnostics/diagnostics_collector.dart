import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/diagnostics/app_diagnostics.dart';
import '../../../core/models/active_playback_output.dart';
import '../../../core/models/cast_state.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/repositories/catalog_track_counter.dart';
import '../../../core/repositories/music_library_repository.dart';
import '../../../core/services/active_playback_controller.dart';
import '../../../core/services/audio_decoder_capabilities.dart';
import '../../../core/services/notification_permission.dart';
import '../../../core/services/playback_diagnostics.dart';
import '../../../core/services/stability_diagnostics.dart';
import '../../../core/sources/local/audio_file_types.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_scan_diagnostics.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../core/sources/source_availability.dart';
import '../../../core/sources/subsonic/subsonic_account_fingerprint.dart';
import '../../../core/sources/subsonic/subsonic_music_source.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../../data/repositories/selected_music_folder_repository_provider.dart';
import '../../../data/repositories/subsonic_sync_pending_store_provider.dart';
import '../../downloads/download_providers.dart';
import '../../library/library_providers.dart';
import '../../library/source_availability_providers.dart';
import '../../player/cast/cast_providers.dart';
import '../../player/player_providers.dart';
import '../jellyfin/jellyfin_availability_controller.dart';
import '../jellyfin/jellyfin_settings_controller.dart';
import '../jellyfin/jellyfin_settings_state.dart';
import '../subsonic/subsonic_settings_controller.dart';
import '../subsonic/subsonic_settings_state.dart';
import '../subsonic/subsonic_sync_controller.dart';
import '../subsonic/subsonic_sync_state.dart';

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

    // Local-folder scan diagnostics: whether a folder is selected, whether a
    // persisted SAF grant is still held for it (the removable-SD-card signal),
    // and the counts from the last scan. All secret-free — never the path/URI.
    // Only the first folder is probed for a SAF grant: content URIs are the
    // Android case, and Android holds exactly one local selection. How many
    // folders a desktop library spans is carried by the scan report's own
    // counts, never as paths.
    final List<String> selectedFolders = await _selectedFolders();
    final String? selectedFolder =
        selectedFolders.isEmpty ? null : selectedFolders.first;
    final bool folderSelected = selectedFolders.isNotEmpty;
    final bool isContentFolder = selectedFolder != null &&
        FolderLocation.parse(selectedFolder).isContentUri;
    final bool? persistedPermission =
        await _persistedPermission(selectedFolder, isContentFolder);
    final LocalScanReport? scan = LocalScanDiagnostics.last;
    final AudioDecoderCapabilities? audio = await _audioCapabilities();
    final SubsonicSyncDiagnostics subsonicSync = await collectSubsonicSync();

    return AppDiagnosticsData(
      appVersion: AppInfo.version,
      androidVersion: _androidVersion(),
      androidSdkInt: audio?.sdkInt,
      androidAbis: audio?.supportedAbis,
      flacDecoding: audio?.flacSummary,
      platformAudioFormats: audio?.platformFormatNames,
      // No device-model plugin is bundled, so this stays null rather than a
      // guess; the report omits the line entirely when absent.
      deviceModel: null,
      jellyfinState: _jellyfinStateLabel(
        jellyfin.phase,
        _ref.read(jellyfinAvailabilityProvider).status,
      ),
      jellyfinHost: jellyfin.baseUrl,
      subsonicState: _subsonicStateLabel(subsonic),
      subsonicHost: subsonic.baseUrl,
      subsonicSyncState: subsonicSync.label,
      subsonicTrackCount: subsonicSync.trackCount,
      libraryTrackCount: await _trackCount(),
      unavailableTrackCount: _unavailableTrackCount(),
      localFolderSelected: folderSelected,
      localPersistedPermission: persistedPermission,
      localScanFilesVisited: scan?.filesVisited,
      localScanFoldersVisited: scan?.foldersVisited,
      localScanAudioCandidates: scan?.audioCandidates,
      localScanImportedTracks: scan?.importedTracks,
      localScanSkippedUnsupported: scan?.skippedUnsupported,
      localScanReadFailures: scan?.readFailures,
      localScanUnopenableNames: scan?.unopenableNames,
      localScanRecursive: scan?.recursive,
      // Static capability — always reportable, even before the first scan — so a
      // "my format isn't recognized" report shows what Linthra accepts.
      localSupportedExtensions: _supportedExtensions(),
      localScanError: scan?.error?.name,
      cacheUsedBytes: _cacheUsedBytes(),
      cacheLimitBytes: _cacheLimitBytes(),
      playbackOutput: _playbackOutput(),
      playbackStatus: _playbackStatus(),
      currentTrackIdHash: _currentTrackIdHash(),
      lastErrorKind: jellyfin.errorKind?.name ??
          subsonic.errorKind?.name ??
          subsonicSync.errorKind ??
          _playbackFailureKind(),
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

  /// The recognized audio extensions, sorted for a stable report line.
  List<String> _supportedExtensions() {
    final List<String> extensions = AudioFileTypes.supportedExtensions.toList()
      ..sort();
    return extensions;
  }

  /// Reads (never prompts for) the notification permission state, so the report
  /// can show whether the media notification / lock-screen controls can appear.
  /// Best-effort: the seam returns `unknown` off Android and on any read error.
  Future<NotificationPermissionStatus> _notificationPermission() =>
      const PermissionHandlerNotificationPermission().status();

  /// The device's audio decoder capabilities (Android only), best-effort: a
  /// failure leaves the lines out rather than breaking the report.
  Future<AudioDecoderCapabilities?> _audioCapabilities() async {
    if (!Platform.isAndroid) return null;
    try {
      return await readPlatformAudioDecoderCapabilities();
    } catch (_) {
      return null;
    }
  }

  String? _androidVersion() =>
      Platform.isAndroid ? Platform.operatingSystemVersion : null;

  bool _androidAutoSupported() => Platform.isAndroid;

  /// The Jellyfin line, reporting **reachability**, not just configuration.
  ///
  /// The old version returned `connected` for any saved session, which is how a
  /// report could read "Jellyfin: connected" beside "Playback state: error" for a
  /// LAN-only server the phone was nowhere near. A configured session now only
  /// says `connected` when a probe actually reached the server and it accepted
  /// the session; otherwise the line names what is really wrong, and says the
  /// connection is still *configured* so nobody reads it as "signed out".
  String _jellyfinStateLabel(
    JellyfinConnectionPhase phase,
    SourceAvailability availability,
  ) {
    switch (phase) {
      case JellyfinConnectionPhase.connected:
        return configuredSourceAvailabilityLabel(availability);
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

  /// How many stored tracks are currently hidden because their source is
  /// unreachable. Best-effort: never let it break the report.
  int? _unavailableTrackCount() {
    try {
      return _ref.read(unavailableTrackCountProvider);
    } catch (_) {
      return null;
    }
  }

  /// The Subsonic/Navidrome library sync's slice of the report: its state
  /// line, how many Subsonic tracks are stored, and the kind of its last
  /// failure (which feeds "Last error"; before #680 a failed sync never reached
  /// the report, so it read "Last error: none" beside an empty library).
  ///
  /// The state line also reports a sync that an earlier run left unfinished
  /// (the process was killed partway), which the in-memory state alone can't
  /// know. Public so it can be tested without the playback/cast plugins the
  /// rest of [collect] reads. Best-effort throughout.
  Future<SubsonicSyncDiagnostics> collectSubsonicSync() async {
    final SubsonicSyncState sync = _ref.read(subsonicSyncControllerProvider);
    final bool present =
        _subsonicStateLabel(_ref.read(subsonicSettingsControllerProvider)) !=
            null;
    final SubsonicMusicSource? source = _ref.read(subsonicMusicSourceProvider);
    bool pendingRetry = false;
    if (source != null) {
      try {
        pendingRetry =
            await _ref.read(subsonicSyncPendingStoreProvider).read() ==
                subsonicAccountFingerprint(source.session);
      } catch (_) {
        // Unknown reads as "nothing pending".
      }
    }
    return (
      label: sync.diagnosticsLabel(pendingRetry: pendingRetry),
      trackCount: present
          ? await _trackCount(sourceId: SubsonicMusicSource.sourceId)
          : null,
      errorKind: sync.errorKind,
    );
  }

  /// How many tracks are stored (only [sourceId]'s, when given). A `COUNT(*)`
  /// when the repository can count, so the report never loads a large library
  /// just for one number; otherwise (in-memory/test repositories) the whole
  /// catalog's length. Best-effort: a storage hiccup omits the line.
  Future<int?> _trackCount({String? sourceId}) async {
    try {
      final MusicLibraryRepository repository =
          _ref.read(musicLibraryRepositoryProvider);
      if (repository is CatalogTrackCounter) {
        return await (repository as CatalogTrackCounter)
            .countTracks(sourceId: sourceId);
      }
      if (sourceId != null) return null;
      return (await repository.getAllTracks()).length;
    } catch (_) {
      // A storage hiccup must not break the report; just omit the count.
      return null;
    }
  }

  /// The selected music folder paths/URIs, read best-effort. Used only to
  /// derive the secret-free "selected / not selected" and persisted-permission
  /// flags — the values themselves never reach the report.
  Future<List<String>> _selectedFolders() async {
    try {
      return await _ref
          .read(selectedMusicFolderRepositoryProvider)
          .getSelectedFolders();
    } catch (_) {
      return <String>[];
    }
  }

  /// Whether a persisted SAF read grant is still held for a `content://`
  /// selection. Null when not applicable (no selection or a plain path) or not
  /// determinable (off Android); best-effort so a probe failure can't break the
  /// report.
  Future<bool?> _persistedPermission(
    String? folder,
    bool isContentFolder,
  ) async {
    if (folder == null || !isContentFolder) {
      return null;
    }
    try {
      return await _ref
          .read(safPermissionProbeProvider)
          .hasPersistedPermission(folder);
    } catch (_) {
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

  /// The current playback failure's kind (a stable enum name such as
  /// `unplayableMedia`), when playback is in an error state. Before #674 a
  /// playback failure never reached "Last error", so a report could read
  /// "Last error: none" beside a track that would not play.
  String? _playbackFailureKind() =>
      _ref.read(playbackControllerProvider).state.failure?.kind.name;

  /// A non-reversible hash of the currently playing track's id (never the id,
  /// title, or URI), or null when nothing is playing.
  String? _currentTrackIdHash() {
    final String? id =
        _ref.read(playbackControllerProvider).state.currentTrack?.id;
    if (id == null || id.isEmpty) return null;
    return PlaybackDiagnostics.redactId(id);
  }
}

/// The Subsonic sync slice of the report (see
/// [DiagnosticsCollector.collectSubsonicSync]).
typedef SubsonicSyncDiagnostics = ({
  String? label,
  int? trackCount,
  String? errorKind,
});

/// Builds the secret-free diagnostics report text on demand.
typedef DiagnosticsReportBuilder = Future<String> Function();

/// The report builder the Diagnostics section invokes. Production wires it to a
/// live [DiagnosticsCollector]; tests override it with a stub so the widget can
/// be exercised without the playback/cast plugins behind the collector.
final diagnosticsReportBuilderProvider = Provider<DiagnosticsReportBuilder>(
  (ref) => DiagnosticsCollector(ref).buildReport,
);
