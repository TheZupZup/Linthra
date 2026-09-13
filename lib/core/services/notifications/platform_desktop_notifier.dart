import '../../platform/host_platform.dart';
import 'dbus_desktop_notifier.dart';
import 'desktop_notifier.dart';

/// The default [DesktopNotifier]: real D-Bus notifications on Linux, a no-op
/// everywhere else.
///
/// This is the one place that knows about the platform split, mirroring
/// [PlatformAudioOutputDeviceService] and [PlatformMediaSessionBinding]. Linux
/// gets [DBusDesktopNotifier]; every other platform, Android included, gets
/// [NoopDesktopNotifier], so nothing here can change what Android does. The
/// media notification there belongs to `audio_service` and the media session,
/// and a second per-track notification on top of it would be both duplicated
/// and wrong.
class PlatformDesktopNotifier implements DesktopNotifier {
  PlatformDesktopNotifier({
    HostPlatform? host,
    DesktopNotifier? linuxNotifier,
    DesktopNotifier fallbackNotifier = const NoopDesktopNotifier(),
  })  : _host = host,
        _linuxNotifier = linuxNotifier,
        _fallbackNotifier = fallbackNotifier;

  /// The platform to route for; null reads the real host. Injectable so the
  /// split can be exercised for both platforms on one machine.
  final HostPlatform? _host;

  /// Built lazily: constructing it is cheap and opens nothing (the D-Bus
  /// client connects on its first call), but a platform that has no
  /// notification bus should never own one at all.
  DesktopNotifier? _linuxNotifier;
  final DesktopNotifier _fallbackNotifier;

  bool get _isLinux => (_host ?? HostPlatform.current) == HostPlatform.linux;

  DesktopNotifier get _delegate {
    if (!_isLinux) return _fallbackNotifier;
    return _linuxNotifier ??= DBusDesktopNotifier();
  }

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<void> show(DesktopNotification notification) =>
      _delegate.show(notification);

  @override
  Future<void> dispose() async {
    // Deliberately not through [_delegate]: disposing must never be the thing
    // that first creates a bus client.
    await _linuxNotifier?.dispose();
    await _fallbackNotifier.dispose();
  }
}
