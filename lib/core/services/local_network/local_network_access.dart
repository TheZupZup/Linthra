import 'dart:async';

import 'package:http/http.dart' as http;

import 'local_network_address.dart';
import 'local_network_permission.dart';

/// When a check may show Android's local network permission dialog.
enum LocalNetworkPrompt {
  /// Never: background work (a sync, an availability probe, a prefetch) and
  /// anything started without the app on screen.
  never,

  /// At most once per app session, and only with the app on screen: playback
  /// the user started, which needs the server but isn't the place to nag.
  oncePerSession,

  /// Whenever Android would still show it: the user pressed something whose
  /// whole point is reaching that server (Test connection, Sign in, Allow).
  userAction,
}

/// Decides whether a connection to a server may go ahead under Android 17's
/// local network permission, and asks for the permission when the user's own
/// action calls for it.
///
/// The rules, in order:
///  * Nothing changes where the permission isn't enforced (before Android 17,
///    desktop) or is already granted. That's every device today, so the check
///    costs one cached answer.
///  * Only a server that resolves to a local address can be blocked. An
///    internet server is never held back and never triggers a prompt.
///  * A prompt only ever follows something the user did, never startup, never
///    a background job, and never while the app is off screen. Android itself
///    stops showing the dialog after repeated refusals; past that point the
///    user is pointed at the app's settings instead.
///
/// The host is resolved through the system resolver, which the permission
/// leaves alone, and the answer is kept briefly so a sync doesn't look the
/// same name up for every request.
class LocalNetworkAccess {
  LocalNetworkAccess({
    required LocalNetworkPermission permission,
    HostLookup? lookup,
    bool Function()? isAppVisible,
    void Function()? onGranted,
    DateTime Function()? now,
    this.hostTtl = const Duration(minutes: 2),
  })  : _permission = permission,
        _lookup = lookup,
        _isAppVisible = isAppVisible ?? _alwaysVisible,
        _onGranted = onGranted,
        _now = now ?? DateTime.now;

  static bool _alwaysVisible() => true;

  final LocalNetworkPermission _permission;
  final HostLookup? _lookup;
  final bool Function() _isAppVisible;
  final void Function()? _onGranted;
  final DateTime Function() _now;

  /// How long a host's locality is trusted before it is looked up again.
  final Duration hostTtl;

  LocalNetworkPermissionStatus? _status;
  Future<LocalNetworkPermissionStatus>? _statusRead;
  Future<LocalNetworkPermissionStatus>? _request;
  bool _promptedThisSession = false;
  final Map<String, ({HostLocality locality, DateTime at})> _hosts =
      <String, ({HostLocality locality, DateTime at})>{};

  /// The permission's current state. Cached until the app comes back to the
  /// foreground ([onAppShown]) or a request answers: Android kills the process
  /// when a granted runtime permission is revoked, so the only change that can
  /// happen under a live process is one made in Settings while Linthra was in
  /// the background. An `unknown` answer is never cached.
  Future<LocalNetworkPermissionStatus> status() {
    final LocalNetworkPermissionStatus? cached = _status;
    if (cached != null) {
      return Future<LocalNetworkPermissionStatus>.value(cached);
    }
    return _statusRead ??= _readStatus();
  }

  Future<LocalNetworkPermissionStatus> _readStatus() async {
    try {
      final LocalNetworkPermissionStatus read = await _permission.status();
      if (read != LocalNetworkPermissionStatus.unknown) _status = read;
      return read;
    } catch (_) {
      return LocalNetworkPermissionStatus.unknown;
    } finally {
      _statusRead = null;
    }
  }

  /// The app is on screen again: the user may have changed the permission in
  /// Android's settings meanwhile, so read it afresh next time.
  void onAppShown() {
    if (_status != LocalNetworkPermissionStatus.notRequired) _status = null;
  }

  /// Whether [host] resolves to a local address. Cached for [hostTtl]; an
  /// `unknown` answer (DNS failed) is not cached, so a lookup made offline
  /// doesn't stick once the network is back.
  Future<HostLocality> localityOf(String host) async {
    final String key = host.trim().toLowerCase();
    final ({HostLocality locality, DateTime at})? cached = _hosts[key];
    final DateTime now = _now();
    if (cached != null && now.difference(cached.at) < hostTtl) {
      return cached.locality;
    }
    final HostLookup? lookup = _lookup;
    final HostLocality locality = lookup == null
        ? await classifyHost(key)
        : await classifyHost(key, lookup: lookup);
    if (locality != HostLocality.unknown) {
      _hosts[key] = (locality: locality, at: now);
    }
    return locality;
  }

  /// What stops a connection to [server], or `null` when it may go ahead.
  ///
  /// Asks for the permission first when [prompt] allows it, and returns `null`
  /// if the user grants it. Never throws.
  Future<LocalNetworkPermissionStatus?> blockerFor(
    Uri server, {
    LocalNetworkPrompt prompt = LocalNetworkPrompt.never,
  }) async {
    LocalNetworkPermissionStatus current = await status();
    // Enforcement off, already granted, or the platform can't say (an engine
    // with no activity): let the connection try and report what it finds.
    if (current.allowsLocalNetwork ||
        current == LocalNetworkPermissionStatus.unknown) {
      return null;
    }
    if (server.host.isEmpty) return null;
    if (await localityOf(server.host) != HostLocality.local) return null;

    if (current.canPrompt && _mayPrompt(prompt)) {
      if (prompt == LocalNetworkPrompt.oncePerSession) {
        _promptedThisSession = true;
      }
      current = await request();
      if (current.allowsLocalNetwork) return null;
    }
    return current;
  }

  bool _mayPrompt(LocalNetworkPrompt prompt) {
    switch (prompt) {
      case LocalNetworkPrompt.never:
        return false;
      case LocalNetworkPrompt.oncePerSession:
        return !_promptedThisSession && _isAppVisible();
      case LocalNetworkPrompt.userAction:
        return _isAppVisible();
    }
  }

  /// Shows Android's dialog when it still can, and returns the outcome. Calls
  /// that overlap share the one dialog. Tells [onGranted] when it turns the
  /// permission on, so whatever was held back can be retried.
  Future<LocalNetworkPermissionStatus> request() {
    return _request ??= _runRequest();
  }

  Future<LocalNetworkPermissionStatus> _runRequest() async {
    try {
      final LocalNetworkPermissionStatus before = await status();
      if (!before.canPrompt) return before;
      LocalNetworkPermissionStatus after;
      try {
        after = await _permission.request();
      } catch (_) {
        after = LocalNetworkPermissionStatus.unknown;
      }
      _status = after == LocalNetworkPermissionStatus.unknown ? null : after;
      if (after == LocalNetworkPermissionStatus.granted) {
        try {
          _onGranted?.call();
        } catch (_) {
          // A listener's failure must not turn a grant into an error.
        }
      }
      return after;
    } finally {
      _request = null;
    }
  }

  Future<void> openAppSettings() => _permission.openAppSettings();

  /// The sentence shown when [blocker] keeps Linthra off a local server. Says
  /// what to do, and names nothing about the server itself.
  static String messageFor(LocalNetworkPermissionStatus blocker) {
    if (blocker == LocalNetworkPermissionStatus.permanentlyDenied) {
      return 'Local network access is off for Linthra, so it can\'t reach '
          'a server on your network. Turn it on in Android settings: Apps > '
          'Linthra > Permissions > Nearby devices.';
    }
    return 'Linthra needs local network access to reach a server on your '
        'network. Allow it when Android asks, or under Settings > '
        'Connections > Local network access.';
  }
}

/// Thrown instead of opening a connection the local network permission would
/// block anyway, so the caller fails at once with the right reason rather than
/// waiting out a connect timeout.
///
/// A [http.ClientException], so every client's existing transport-error path
/// takes it unchanged. Carries no URL: the message is safe to show and log.
class LocalNetworkBlockedException extends http.ClientException {
  LocalNetworkBlockedException(this.status)
      : super(LocalNetworkAccess.messageFor(status));

  final LocalNetworkPermissionStatus status;
}

/// An [http.Client] that asks [LocalNetworkAccess] before every request and
/// refuses, without a prompt, the ones Android would block.
///
/// Wraps the clients Linthra talks to its servers through, so background work
/// (a sync, the availability probe, a stream probe) on a local server fails
/// fast while the permission is missing instead of hanging on a timeout.
class LocalNetworkGuardedClient extends http.BaseClient {
  LocalNetworkGuardedClient(this._inner, this._access);

  final http.Client _inner;
  final LocalNetworkAccess _access;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final LocalNetworkPermissionStatus? blocker =
        await _access.blockerFor(request.url);
    if (blocker != null) throw LocalNetworkBlockedException(blocker);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
