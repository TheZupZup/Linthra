import '../models/cache_size.dart';

/// An immutable, display-safe snapshot of everything the diagnostics report can
/// show. Built by the collector from live app state and rendered by
/// [AppDiagnostics.report].
///
/// Security: by construction this object can only ever hold non-secret,
/// report-safe values. There is no field for a password, token, `Authorization`
/// header, salt, or a full authenticated URL. The server addresses are reduced
/// to host[:port] by [AppDiagnostics.hostOnly] when rendered, the last error is
/// a stable enum *name* (never a raw error string that could carry a path or
/// server response), and any device-supplied free text is omitted rather than
/// risk leaking a private path. This mirrors the "diagnostic, never secret" rule
/// the per-source `JellyfinDiagnostics`/`PlaybackDiagnostics` already hold.
class AppDiagnosticsData {
  const AppDiagnosticsData({
    required this.appVersion,
    this.androidVersion,
    this.deviceModel,
    this.jellyfinState,
    this.jellyfinHost,
    this.subsonicState,
    this.subsonicHost,
    this.libraryTrackCount,
    this.localFolderSelected,
    this.localPersistedPermission,
    this.localScanFilesVisited,
    this.localScanAudioCandidates,
    this.localScanSkippedUnsupported,
    this.localScanReadFailures,
    this.localScanError,
    this.cacheUsedBytes,
    this.cacheLimitBytes,
    this.playbackOutput,
    this.playbackStatus,
    this.currentTrackIdHash,
    this.lastErrorKind,
    this.notificationPermission,
    this.lastLifecycleState,
    this.playbackStateAtBackground,
    this.lastInterruptionKind,
    this.castAvailable = false,
    this.castConnected = false,
    this.androidAutoSupported = false,
    this.offlineCacheEnabled = false,
    this.smartPrecacheEnabled,
  });

  /// The app `versionName` (e.g. `0.1.0-alpha.30`). Always present.
  final String appVersion;

  /// The Android OS version string, when running on Android. Null elsewhere.
  final String? androidVersion;

  /// The device model, when a platform source for it is available. Null
  /// otherwise — never a guess.
  final String? deviceModel;

  /// The Jellyfin connection state label (e.g. `connected`), when Jellyfin has
  /// been touched at all. Null when there is nothing to report.
  final String? jellyfinState;

  /// The Jellyfin server address. Rendered host-only; never a full URL.
  final String? jellyfinHost;

  /// The Subsonic/Navidrome connection state label, when present. Null when the
  /// user has never used Subsonic.
  final String? subsonicState;

  /// The Subsonic/Navidrome server address. Rendered host-only.
  final String? subsonicHost;

  /// How many tracks are in the local catalog, when known.
  final int? libraryTrackCount;

  /// Whether a local music folder is currently selected, when known. The folder
  /// path/URI itself is never carried — only its presence.
  final bool? localFolderSelected;

  /// For a `content://` (SAF) selection: whether the app still holds a persisted
  /// read grant for it. Null when not applicable (no selection, a plain path) or
  /// not determinable (off Android). The removable-SD-card "no access" signal.
  final bool? localPersistedPermission;

  /// How many non-directory entries the last local scan walked, when a scan has
  /// run. Counts only — never a path or file name.
  final int? localScanFilesVisited;

  /// How many of those entries the last scan kept as playable audio.
  final int? localScanAudioCandidates;

  /// How many entries the last scan skipped as unsupported (e.g. artwork/notes).
  final int? localScanSkippedUnsupported;

  /// How many entries/subfolders the last scan could not read and skipped — the
  /// scoped-storage / removable-storage signal.
  final int? localScanReadFailures;

  /// The last local-scan failure kind (a stable enum name like `safTraversal`),
  /// when the last scan threw. Null when it completed (even with zero audio).
  final String? localScanError;

  /// App-managed cache bytes in use, when known.
  final int? cacheUsedBytes;

  /// The configured cache limit in bytes, when known.
  final int? cacheLimitBytes;

  /// Which output is producing sound now: `local`, `cast`, or `android auto`.
  /// Null when nothing is playing / not known.
  final String? playbackOutput;

  /// The current playback status (a stable enum name like `playing`/`buffering`/
  /// `error`), when a controller is available. Null otherwise.
  final String? playbackStatus;

  /// A non-reversible hash tag of the currently playing track's id (e.g.
  /// `id#1a2b3c`) — never the raw id, title, or URI — so a report can correlate
  /// "which track was playing when it froze" without revealing anything.
  final String? currentTrackIdHash;

  /// The stable name of the last safe error kind (an enum name), when one
  /// occurred. Never a raw error message.
  final String? lastErrorKind;

  /// Whether the notification permission is `granted`/`denied`/`unknown`, so a
  /// "lock-screen controls don't work" report can show whether the Android 13+
  /// `POST_NOTIFICATIONS` grant — required for the media notification and its
  /// transport controls — is in place. Null when not collected.
  final String? notificationPermission;

  /// The most recent app lifecycle state (`resumed`/`paused`/…), when known —
  /// the background/foreground boundary screen-off playback bugs cluster around.
  final String? lastLifecycleState;

  /// The playback status captured the last time the app was backgrounded
  /// (`playing`/`buffering`/`paused`/…), when known — so a "music stopped when I
  /// locked the phone" report shows what state playback was in at that boundary.
  final String? playbackStateAtBackground;

  /// The last safe playback/stream interruption kind (an enum name or fixed
  /// label like `load`), when one occurred. Never a raw error.
  final String? lastInterruptionKind;

  final bool castAvailable;
  final bool castConnected;
  final bool androidAutoSupported;
  final bool offlineCacheEnabled;

  /// Whether smart pre-cache is on, when the preference is known. Null when not
  /// loaded.
  final bool? smartPrecacheEnabled;
}

/// Builds the secret-free text the Settings ▸ Diagnostics "Copy"/"Save" actions
/// produce, so a user can paste it into a bug report without leaking anything
/// sensitive.
///
/// Security invariant: every field is rendered from the display-safe
/// [AppDiagnosticsData], and the two server-address fields are always passed
/// through [hostOnly] here — so even if a caller mistakenly handed in a full
/// authenticated URL, only its host[:port] can ever reach the output. There is
/// no parameter for a password, token, `Authorization` header, or raw server
/// response.
abstract final class AppDiagnostics {
  /// Assembles the multi-line report. Only [AppDiagnosticsData.appVersion] is
  /// guaranteed present; every other line is emitted only when its value is
  /// known, so the report is useful even before a connection or a library sync.
  ///
  /// [includePlayback] and [includeCache] let the "Report a bug" flow drop the
  /// playback (output/state/current-track) and cache lines when the user turns
  /// those toggles off. Both default to true, so the plain Diagnostics export is
  /// unchanged.
  static String report(
    AppDiagnosticsData data, {
    bool includePlayback = true,
    bool includeCache = true,
  }) {
    final String? jellyfinHost = hostOnly(data.jellyfinHost);
    final String? subsonicHost = hostOnly(data.subsonicHost);
    final String? cache = includeCache ? _cacheLine(data) : null;
    final List<String> lines = <String>[
      'Linthra diagnostics',
      'App version: ${data.appVersion}',
      if (_has(data.androidVersion)) 'Android: ${data.androidVersion}',
      if (_has(data.deviceModel)) 'Device: ${data.deviceModel}',
      if (data.jellyfinState != null) 'Jellyfin: ${data.jellyfinState}',
      if (jellyfinHost != null) 'Jellyfin host: $jellyfinHost',
      if (data.subsonicState != null) 'Subsonic: ${data.subsonicState}',
      if (subsonicHost != null) 'Subsonic host: $subsonicHost',
      if (data.libraryTrackCount != null)
        'Library tracks: ${data.libraryTrackCount}',
      if (data.localFolderSelected != null)
        'Local folder: ${data.localFolderSelected! ? 'selected' : 'not selected'}',
      if (data.localPersistedPermission != null)
        'Local folder access: '
            '${data.localPersistedPermission! ? 'persisted' : 'not persisted'}',
      if (data.localScanFilesVisited != null) _localScanLine(data),
      if (_has(data.localScanError)) 'Local scan error: ${data.localScanError}',
      if (cache != null) cache,
      if (includePlayback && data.playbackOutput != null)
        'Playback output: ${data.playbackOutput}',
      if (includePlayback && data.playbackStatus != null)
        'Playback state: ${data.playbackStatus}',
      if (includePlayback && data.currentTrackIdHash != null)
        'Current track: ${data.currentTrackIdHash}',
      if (includePlayback && data.playbackStateAtBackground != null)
        'Playback at last background: ${data.playbackStateAtBackground}',
      if (_has(data.lastLifecycleState))
        'Last lifecycle: ${data.lastLifecycleState}',
      if (_has(data.notificationPermission))
        'Notification permission: ${data.notificationPermission}',
      'Last error: ${data.lastErrorKind ?? 'none'}',
      if (includePlayback && _has(data.lastInterruptionKind))
        'Last interruption: ${data.lastInterruptionKind}',
      'Cast available: ${_yesNo(data.castAvailable)}',
      'Cast connected: ${_yesNo(data.castConnected)}',
      'Android Auto supported: ${_yesNo(data.androidAutoSupported)}',
      'Offline cache: ${_enabledDisabled(data.offlineCacheEnabled)}',
      if (data.smartPrecacheEnabled != null)
        'Smart pre-cache: ${_enabledDisabled(data.smartPrecacheEnabled!)}',
    ];
    return lines.join('\n');
  }

  /// The single-line local-scan summary: how many entries the last scan walked,
  /// how many were kept as audio, how many were skipped as unsupported, and how
  /// many could not be read. Only counts — never a path or file name.
  static String _localScanLine(AppDiagnosticsData data) {
    return 'Local scan: visited ${data.localScanFilesVisited ?? 0}, '
        'audio ${data.localScanAudioCandidates ?? 0}, '
        'skipped ${data.localScanSkippedUnsupported ?? 0}, '
        'read failures ${data.localScanReadFailures ?? 0}';
  }

  static String? _cacheLine(AppDiagnosticsData data) {
    final int? used = data.cacheUsedBytes;
    final int? limit = data.cacheLimitBytes;
    if (used == null || limit == null) return null;
    return 'Cache: ${CacheSize.formatBytes(used)} of '
        '${CacheSize.formatBytes(limit)}';
  }

  static bool _has(String? value) => value != null && value.isNotEmpty;

  /// Reduces a server address to just its host (and port), dropping the scheme,
  /// path, query, userinfo, and fragment — so a full authenticated URL can never
  /// carry a token, an `api_key` query, or a `user:pass@` prefix into the
  /// report. Accepts a bare host (`music.example.com[:8096]`) too, returning it
  /// reduced. Returns null when [value] is empty or has no host.
  static String? hostOnly(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      // No scheme present: re-parse as a bare authority so a value like
      // `music.example.com:8096` (or one with a stray path) still reduces.
      uri = Uri.tryParse('//$trimmed');
    }
    if (uri == null || uri.host.isEmpty) return null;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// Redacts a local filesystem path to just its basename behind a `…/` marker,
  /// so a diagnostic that must mention a file never reveals the private,
  /// user-identifying directory tree leading to it. Returns null for null/empty.
  static String? redactPath(String? path) {
    if (path == null) return null;
    final String trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    final int slash = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    if (slash < 0) return trimmed;
    final String basename = trimmed.substring(slash + 1);
    return basename.isEmpty ? '…' : '…/$basename';
  }

  static String _yesNo(bool value) => value ? 'yes' : 'no';

  static String _enabledDisabled(bool value) => value ? 'enabled' : 'disabled';
}
