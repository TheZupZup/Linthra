import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Asks the OS for the notification permission the media session needs.
///
/// On Android 13+ (API 33) the `POST_NOTIFICATIONS` permission is required
/// before `audio_service` can show its playback notification — without it the
/// foreground service still runs but the notification and its transport
/// controls are silently suppressed. This is the single seam the app calls so
/// the request stays testable (UI/tests inject a fake) and the rest of the app
/// never touches `permission_handler` directly.
abstract interface class NotificationPermission {
  /// Requests the notification permission if it isn't already granted.
  ///
  /// Best-effort and safe to call more than once: a no-op where the permission
  /// doesn't apply (older Android, other platforms) and when already granted.
  /// Never throws — a platform that can't service the request is treated as
  /// "nothing to do" so startup is never blocked by it.
  Future<void> ensureGranted();

  /// The current notification-permission state, for diagnostics.
  ///
  /// Never throws and never prompts: it only *reads* the status so a bug report
  /// can say whether the media notification / lock-screen controls can appear at
  /// all. Returns [NotificationPermissionStatus.unknown] off Android (where
  /// there is no `POST_NOTIFICATIONS` gate) and whenever the platform can't
  /// answer.
  Future<NotificationPermissionStatus> status();
}

/// The display-safe notification-permission state surfaced in diagnostics.
///
/// On Android 13+ the media notification (and its transport controls) only
/// appears when [granted]; when [denied] the foreground service still runs but
/// the controls are suppressed, which is worth surfacing in a bug report.
/// [unknown] covers platforms with no runtime gate and any read that fails.
enum NotificationPermissionStatus {
  granted,
  denied,
  unknown;

  /// A stable, secret-free label for the diagnostics report.
  String get label {
    switch (this) {
      case NotificationPermissionStatus.granted:
        return 'granted';
      case NotificationPermissionStatus.denied:
        return 'denied';
      case NotificationPermissionStatus.unknown:
        return 'unknown';
    }
  }
}

/// The production [NotificationPermission], backed by `permission_handler`.
///
/// Only meaningful on Android: elsewhere there is no `POST_NOTIFICATIONS`
/// runtime gate, so it returns immediately. Any plugin failure is swallowed so
/// a permission hiccup can never crash or stall app start; playback still works
/// without the notification.
class PermissionHandlerNotificationPermission
    implements NotificationPermission {
  const PermissionHandlerNotificationPermission();

  @override
  Future<void> ensureGranted() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final PermissionStatus status = await Permission.notification.status;
      // Only prompt when it can still be granted. A permanently-denied grant is
      // left alone: re-prompting does nothing and the user can enable it from
      // system settings.
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {
      // A platform/plugin that can't service the request is non-fatal: the app
      // runs without the notification rather than failing to start.
    }
  }

  @override
  Future<NotificationPermissionStatus> status() async {
    if (!Platform.isAndroid) {
      return NotificationPermissionStatus.unknown;
    }
    try {
      final PermissionStatus status = await Permission.notification.status;
      return status.isGranted
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
    } catch (_) {
      // A read that the platform can't service must never crash diagnostics.
      return NotificationPermissionStatus.unknown;
    }
  }
}

/// A [NotificationPermission] that does nothing.
///
/// For tests and any context that must not trigger a real OS prompt.
class NoopNotificationPermission implements NotificationPermission {
  const NoopNotificationPermission();

  @override
  Future<void> ensureGranted() async {}

  @override
  Future<NotificationPermissionStatus> status() async =>
      NotificationPermissionStatus.unknown;
}
