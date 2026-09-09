import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/host_platform.dart';
import 'desktop_window_controller.dart';

/// The [DesktopWindowController] backed by Linthra's own Linux runner channel
/// (`linux/runner/window_lifecycle_channel.cc`), for issue #401.
///
/// Two directions on one channel:
///
///  * Dart -> runner: what the next close should do ([setHideOnClose]), bring
///    the window back ([showWindow]), and end the process ([quit]).
///  * runner -> Dart: the window was hidden by a close, or presented again,
///    including by a *second launch* of an already-running Linthra, which the
///    single-instance runner turns into "raise the window I already have"
///    rather than a duplicate process.
///
/// Every call is best-effort. A build whose runner predates the channel (or
/// any non-Linux host) answers [MissingPluginException], which is treated as
/// "this window cannot be managed": closing it then does what it always did,
/// which is exactly the safe fallback.
class MethodChannelLinuxWindow implements DesktopWindowController {
  MethodChannelLinuxWindow({
    HostPlatform? host,
    MethodChannel channel = _defaultChannel,
  })  : _host = host,
        _channel = channel {
    _channel.setMethodCallHandler(_handleRunnerCall);
  }

  /// Mirrors `kChannelName` in `linux/runner/window_lifecycle_channel.cc`;
  /// `scripts/check_linux_runner.py` holds the two to the same string.
  static const String channelName =
      'io.github.thezupzup.linthra/linux_window_lifecycle';

  /// Mirrors `kSetHideOnCloseMethod` in the runner.
  static const String setHideOnCloseMethod = 'setHideOnClose';

  /// Mirrors `kShowWindowMethod` in the runner.
  static const String showWindowMethod = 'showWindow';

  /// Mirrors `kQuitMethod` in the runner.
  static const String quitMethod = 'quit';

  /// Mirrors `kWindowHiddenMethod` in the runner, sent when a close hid the
  /// window instead of destroying it.
  static const String windowHiddenMethod = 'windowHidden';

  /// Mirrors `kWindowShownMethod` in the runner, sent when the window is
  /// presented again.
  static const String windowShownMethod = 'windowShown';

  /// Mirrors `kHideOnCloseArgument` in the runner.
  static const String hideOnCloseArgument = 'hideOnClose';

  static const MethodChannel _defaultChannel = MethodChannel(channelName);

  final HostPlatform? _host;
  final MethodChannel _channel;

  final StreamController<DesktopWindowVisibility> _visibility =
      StreamController<DesktopWindowVisibility>.broadcast();

  bool get _isLinux => (_host ?? HostPlatform.current) == HostPlatform.linux;

  @override
  Stream<DesktopWindowVisibility> get visibility => _visibility.stream;

  @override
  Future<void> setHideOnClose(bool hideOnClose) {
    return _invoke(
      setHideOnCloseMethod,
      <String, Object?>{hideOnCloseArgument: hideOnClose},
    );
  }

  @override
  Future<void> showWindow() => _invoke(showWindowMethod);

  @override
  Future<void> quit() => _invoke(quitMethod);

  /// Stops listening to the runner. The channel itself is process-wide, so the
  /// handler is cleared rather than left pointing at a disposed controller.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _visibility.close();
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!_isLinux) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // A runner without the channel. Nothing to manage, nothing to report:
      // the window keeps its default close behaviour.
    } on PlatformException {
      // The runner refused (no window yet, or it is already going away).
      // Never fatal: this only ever adjusts window behaviour.
    }
  }

  Future<void> _handleRunnerCall(MethodCall call) async {
    switch (call.method) {
      case windowHiddenMethod:
        _emit(DesktopWindowVisibility.hidden);
      case windowShownMethod:
        _emit(DesktopWindowVisibility.shown);
    }
  }

  void _emit(DesktopWindowVisibility value) {
    if (_visibility.isClosed) return;
    _visibility.add(value);
  }
}
