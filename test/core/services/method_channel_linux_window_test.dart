import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/desktop_window_controller.dart';
import 'package:linthra/core/services/method_channel_linux_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel(MethodChannelLinuxWindow.channelName);
  const StandardMethodCodec codec = StandardMethodCodec();

  /// Installs a handler for the runner's channel and records what Dart sent.
  List<MethodCall> handleWith(Future<Object?> Function(MethodCall) handler) {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return handler(call);
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    return calls;
  }

  MethodChannelLinuxWindow window({HostPlatform host = HostPlatform.linux}) {
    final MethodChannelLinuxWindow controller =
        MethodChannelLinuxWindow(host: host);
    addTearDown(controller.dispose);
    return controller;
  }

  /// Delivers a call *from* the runner, the way the engine would.
  Future<void> sendFromRunner(String method) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      MethodChannelLinuxWindow.channelName,
      codec.encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  group('MethodChannelLinuxWindow', () {
    test('sends the close behaviour the runner has to act on', () async {
      final List<MethodCall> calls = handleWith((_) async => null);

      await window().setHideOnClose(true);

      expect(
          calls.single.method, MethodChannelLinuxWindow.setHideOnCloseMethod);
      expect(
        calls.single.arguments,
        <String, Object?>{MethodChannelLinuxWindow.hideOnCloseArgument: true},
      );
    });

    test('asks the runner to show the window and to quit', () async {
      final List<MethodCall> calls = handleWith((_) async => null);
      final MethodChannelLinuxWindow controller = window();

      await controller.showWindow();
      await controller.quit();

      expect(
        calls.map((MethodCall call) => call.method),
        <String>[
          MethodChannelLinuxWindow.showWindowMethod,
          MethodChannelLinuxWindow.quitMethod,
        ],
      );
    });

    test('reports the window being hidden and shown again', () async {
      handleWith((_) async => null);
      final MethodChannelLinuxWindow controller = window();
      final List<DesktopWindowVisibility> seen = <DesktopWindowVisibility>[];
      final sub = controller.visibility.listen(seen.add);
      addTearDown(sub.cancel);

      await sendFromRunner(MethodChannelLinuxWindow.windowHiddenMethod);
      await sendFromRunner(MethodChannelLinuxWindow.windowShownMethod);

      expect(seen, <DesktopWindowVisibility>[
        DesktopWindowVisibility.hidden,
        DesktopWindowVisibility.shown,
      ]);
    });

    test('never opens the channel off Linux', () async {
      final List<MethodCall> calls = handleWith((_) async => null);

      await window(host: HostPlatform.android).setHideOnClose(true);

      expect(calls, isEmpty);
    });

    test('a runner without the channel is not an error', () async {
      // An older build, or one whose runner was regenerated from the Flutter
      // template: closing the window then does what it always did.
      final MethodChannelLinuxWindow controller = window();

      await expectLater(controller.setHideOnClose(true), completes);
      await expectLater(controller.quit(), completes);
    });

    test('a refusal from the runner is not an error either', () async {
      handleWith((_) async => throw PlatformException(code: 'no_window'));
      final MethodChannelLinuxWindow controller = window();

      await expectLater(controller.showWindow(), completes);
    });
  });
}
