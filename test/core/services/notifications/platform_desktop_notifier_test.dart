import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/notifications/desktop_notifier.dart';
import 'package:linthra/core/services/notifications/platform_desktop_notifier.dart';

/// Records what it was asked to do, so the platform split can be asserted
/// without a session bus.
class _RecordingNotifier implements DesktopNotifier {
  _RecordingNotifier({required this.isSupported});

  @override
  final bool isSupported;

  final List<DesktopNotification> shown = <DesktopNotification>[];
  int disposeCount = 0;

  @override
  Future<void> show(DesktopNotification notification) async =>
      shown.add(notification);

  @override
  Future<void> dispose() async => disposeCount++;
}

void main() {
  const DesktopNotification notification = DesktopNotification(
    title: 'Trouble',
    body: 'Cat Power',
  );

  group('PlatformDesktopNotifier', () {
    test('on Linux, routes to the D-Bus notifier', () async {
      final _RecordingNotifier linux = _RecordingNotifier(isSupported: true);
      final _RecordingNotifier fallback =
          _RecordingNotifier(isSupported: false);
      final PlatformDesktopNotifier notifier = PlatformDesktopNotifier(
        host: HostPlatform.linux,
        linuxNotifier: linux,
        fallbackNotifier: fallback,
      );

      expect(notifier.isSupported, isTrue);
      await notifier.show(notification);

      expect(linux.shown, <DesktopNotification>[notification]);
      expect(fallback.shown, isEmpty);
    });

    test('on Android, shows nothing and reports itself unsupported', () async {
      final _RecordingNotifier linux = _RecordingNotifier(isSupported: true);
      final _RecordingNotifier fallback =
          _RecordingNotifier(isSupported: false);
      final PlatformDesktopNotifier notifier = PlatformDesktopNotifier(
        host: HostPlatform.android,
        linuxNotifier: linux,
        fallbackNotifier: fallback,
      );

      expect(notifier.isSupported, isFalse);
      await notifier.show(notification);

      // The Android per-track notification is the media session's, drawn by
      // the system. Nothing here may add a second one.
      expect(linux.shown, isEmpty);
      expect(fallback.shown, <DesktopNotification>[notification]);
    });

    test('macOS and Windows get the no-op too', () {
      for (final HostPlatform host in <HostPlatform>[
        HostPlatform.macOS,
        HostPlatform.windows,
        HostPlatform.ios,
        HostPlatform.other,
      ]) {
        expect(
          PlatformDesktopNotifier(host: host).isSupported,
          isFalse,
          reason: 'D-Bus notifications are Linux’s alone',
        );
      }
    });

    test('disposing never creates the Linux notifier it did not need',
        () async {
      final _RecordingNotifier fallback =
          _RecordingNotifier(isSupported: false);
      final PlatformDesktopNotifier notifier = PlatformDesktopNotifier(
        host: HostPlatform.android,
        fallbackNotifier: fallback,
      );

      await notifier.dispose();

      expect(fallback.disposeCount, 1);
    });

    test('disposing releases the Linux notifier it did create', () async {
      final _RecordingNotifier linux = _RecordingNotifier(isSupported: true);
      final PlatformDesktopNotifier notifier = PlatformDesktopNotifier(
        host: HostPlatform.linux,
        linuxNotifier: linux,
      );

      await notifier.show(notification);
      await notifier.dispose();

      expect(linux.disposeCount, 1);
    });
  });
}
