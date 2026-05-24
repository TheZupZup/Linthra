import 'jellyfin_server_capabilities.dart';

/// Builds the secret-free text the "Copy Jellyfin diagnostics" action puts on
/// the clipboard, so a user can paste it into a bug report without leaking
/// anything sensitive.
///
/// Security invariant: this can only ever emit non-secret, display-safe fields.
/// There is no parameter for a password, access token, `Authorization` header,
/// or full authenticated URL, and the server address is reduced to its host (by
/// [hostOnly]) so even a tokenless query string can't ride along. The
/// [lastErrorKind] is the stable enum *name*, never a raw error string. This
/// mirrors the same "diagnostic, never secret" rule `PlaybackDiagnostics` holds
/// for debug logs — here for a user-facing report.
abstract final class JellyfinDiagnostics {
  /// Assembles the multi-line report. Every field is optional except the app
  /// version and connection state, so the report is useful even before a
  /// successful connection.
  static String describe({
    required String appVersion,
    required String connectionState,
    String? serverHost,
    String? serverName,
    String? serverVersion,
    String? productName,
    JellyfinServerSupport? versionSupport,
    String? lastErrorKind,
  }) {
    final List<String> lines = <String>[
      'Linthra Jellyfin diagnostics',
      'App version: $appVersion',
      'Connection: $connectionState',
      if (serverName != null && serverName.isNotEmpty)
        'Server name: $serverName',
      if (productName != null && productName.isNotEmpty)
        'Product: $productName',
      if (serverVersion != null && serverVersion.isNotEmpty)
        'Server version: $serverVersion',
      if (versionSupport != null) 'Version support: ${versionSupport.label}',
      if (serverHost != null && serverHost.isNotEmpty)
        'Server host: $serverHost',
      'Last error: ${lastErrorKind ?? 'none'}',
    ];
    return lines.join('\n');
  }

  /// Reduces a full server base URL to just its host (and port), dropping the
  /// scheme, path, query, and anything else, so the diagnostics never carry a
  /// full URL. Returns `null` when [baseUrl] is empty or has no host.
  static String? hostOnly(String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) {
      return null;
    }
    final Uri? uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
}
