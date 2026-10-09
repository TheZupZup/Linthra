import 'package:flutter/services.dart';

/// Where Android 17's local network permission (ACCESS_LOCAL_NETWORK) stands
/// for this app.
enum LocalNetworkPermissionStatus {
  /// The device or the app's target doesn't enforce the permission (anything
  /// before Android 17, desktop): local connections just work and nothing is
  /// ever asked.
  notRequired,

  /// Granted, directly or through another "Nearby devices" permission.
  granted,

  /// Never asked yet. A request shows the system dialog.
  notRequested,

  /// Asked and refused, and Android will still show the dialog again.
  denied,

  /// Refused for good: a request returns at once without a dialog, so only the
  /// app's settings page can grant it now.
  permanentlyDenied,

  /// The platform couldn't be asked right now, typically because the engine
  /// was started by the media service (Android Auto, a headset button) with no
  /// activity to host the channel. Treated as "don't know": nothing is blocked
  /// on it and nothing is requested.
  unknown,
}

extension LocalNetworkPermissionStatusX on LocalNetworkPermissionStatus {
  /// Whether local connections can go ahead as far as Android is concerned.
  bool get allowsLocalNetwork =>
      this == LocalNetworkPermissionStatus.notRequired ||
      this == LocalNetworkPermissionStatus.granted;

  /// Whether asking would actually show the system dialog.
  bool get canPrompt =>
      this == LocalNetworkPermissionStatus.notRequested ||
      this == LocalNetworkPermissionStatus.denied;
}

/// The platform seam for Android 17's local network permission.
///
/// Only ever asked from something the user did (see `LocalNetworkAccess`), so
/// a fresh install or an update never meets a permission dialog on launch.
abstract interface class LocalNetworkPermission {
  Future<LocalNetworkPermissionStatus> status();

  /// Shows the system dialog when Android still allows it and returns the
  /// status afterwards. Returns the current status unchanged when there is
  /// nothing to ask.
  Future<LocalNetworkPermissionStatus> request();

  /// Opens Linthra's page in Android's app settings, the only place a
  /// permanently refused permission can be granted.
  Future<void> openAppSettings();
}

/// Every non-Android host: there is no such permission, so local servers are
/// always reachable as far as the OS is concerned.
class UnsupportedLocalNetworkPermission implements LocalNetworkPermission {
  const UnsupportedLocalNetworkPermission();

  @override
  Future<LocalNetworkPermissionStatus> status() async =>
      LocalNetworkPermissionStatus.notRequired;

  @override
  Future<LocalNetworkPermissionStatus> request() async =>
      LocalNetworkPermissionStatus.notRequired;

  @override
  Future<void> openAppSettings() async {}
}

/// Android: backed by `LocalNetworkPermissionChannel.kt`.
class MethodChannelLocalNetworkPermission implements LocalNetworkPermission {
  const MethodChannelLocalNetworkPermission();

  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/local_network');

  @override
  Future<LocalNetworkPermissionStatus> status() async {
    try {
      return parseStatus(await _channel.invokeMethod<String>('status'));
    } on MissingPluginException {
      return LocalNetworkPermissionStatus.unknown;
    } on PlatformException {
      return LocalNetworkPermissionStatus.unknown;
    }
  }

  @override
  Future<LocalNetworkPermissionStatus> request() async {
    try {
      return parseStatus(await _channel.invokeMethod<String>('request'));
    } on MissingPluginException {
      return LocalNetworkPermissionStatus.unknown;
    } on PlatformException {
      // Another request still open, or no activity to show it on. Report what
      // Android says now rather than inventing a refusal.
      return status();
    }
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } on MissingPluginException {
      // No activity: nothing to open from.
    } on PlatformException {
      // No settings activity on this device; the card's text still says where.
    }
  }

  static LocalNetworkPermissionStatus parseStatus(String? raw) {
    switch (raw) {
      case 'notRequired':
        return LocalNetworkPermissionStatus.notRequired;
      case 'granted':
        return LocalNetworkPermissionStatus.granted;
      case 'notRequested':
        return LocalNetworkPermissionStatus.notRequested;
      case 'denied':
        return LocalNetworkPermissionStatus.denied;
      case 'permanentlyDenied':
        return LocalNetworkPermissionStatus.permanentlyDenied;
      default:
        return LocalNetworkPermissionStatus.unknown;
    }
  }
}
