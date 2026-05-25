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
    this.cacheUsedBytes,
    this.cacheLimitBytes,
    this.playbackOutput,
    this.lastErrorKind,
    this.castAvailable = false,
    this.castConnected = false,
    this.androidAutoSupported = false,
    this.offlineCacheEnabled = false,
    this.smartPrecacheEnabled,
  });

  /// The app `versionName` (e.g. `0.1.0-alpha.15`). Always present.
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

  /// App-managed cache bytes in use, when known.
  final int? cacheUsedBytes;

  /// The configured cache limit in bytes, when known.
  final int? cacheLimitBytes;

  /// Which output is producing sound now: `local`, `cast`, or `android auto`.
  /// Null when nothing is playing / not known.
  final String? playbackOutput;

  /// The stable name of the last safe error kind (an enum name), when one
  /// occurred. Never a raw error message.
  final String? lastErrorKind;

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
  static String report(AppDiagnosticsData data) {
    final String? jellyfinHost = hostOnly(data.jellyfinHost);
    final String? subsonicHost = hostOnly(data.subsonicHost);
    final String? cache = _cacheLine(data);
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
      if (cache != null) cache,
      if (data.playbackOutput != null)
        'Playback output: ${data.playbackOutput}',
      'Last error: ${data.lastErrorKind ?? 'none'}',
      'Cast available: ${_yesNo(data.castAvailable)}',
      'Cast connected: ${_yesNo(data.castConnected)}',
      'Android Auto supported: ${_yesNo(data.androidAutoSupported)}',
      'Offline cache: ${_enabledDisabled(data.offlineCacheEnabled)}',
      if (data.smartPrecacheEnabled != null)
        'Smart pre-cache: ${_enabledDisabled(data.smartPrecacheEnabled!)}',
    ];
    return lines.join('\n');
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
