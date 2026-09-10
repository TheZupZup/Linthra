import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String smoke;

  setUpAll(() {
    smoke = File('scripts/flatpak_launch_smoke.sh').readAsStringSync();
  });

  test('launch smoke installs only from the local CI repository', () {
    expect(smoke, contains(r'REMOTE_NAME="linthra-ci-smoke-$$"'));
    expect(smoke, contains('--no-gpg-verify'));
    expect(smoke, contains('flatpak --user install -y'));
    expect(smoke, isNot(contains('https://')));
  });

  // #618. The release path runs this same smoke a second time against the
  // standalone `.flatpak` it is about to attach to a Release, installed the way
  // a user installs it. A bundle carries the package itself, so that path adds
  // no remote and still no URL.
  test('launch smoke can install a standalone release bundle', () {
    expect(
        smoke, contains(r'flatpak --user install -y --bundle "$BUNDLE_PATH"'));
    expect(smoke, contains('Flatpak bundle not found'));
    expect(smoke, contains(r'INSTALL_SOURCE="${1:-repo-ci}"'));
  });

  test('launch smoke preserves pre-existing Linthra installations', () {
    expect(smoke, contains(r'flatpak --user info "$APP_ID"'));
    expect(smoke, contains(r'flatpak --system info "$APP_ID"'));
    expect(smoke, contains(r'$APP_ID is already installed'));
  });

  test('launch smoke starts the packaged app and waits for a real window', () {
    expect(smoke, contains(r'flatpak run "$APP_ID"'));
    expect(smoke, contains('xwininfo -root -tree'));
    expect(smoke, contains('WINDOW_TITLE="Linthra"'));
    expect(smoke, contains('xvfb-run --auto-servernum'));
    expect(smoke, contains('dbus-run-session'));
  });

  // #554. A window is not enough: it has to be a window the desktop recognises
  // as Linthra. Under Xvfb the sandbox takes its --socket=fallback-x11 path, so
  // both of these are readable as X properties on the packaged app.
  test('launch smoke holds the packaged window to the application id', () {
    expect(smoke, contains('xprop is not installed'));
    expect(smoke, contains(r'wait_for_property "$window_id" WM_CLASS'));
    expect(
      smoke,
      contains(r'expected="WM_CLASS(STRING) = \"$APP_ID\", \"$APP_ID\""'),
    );
  });

  test('launch smoke requires the packaged window to carry its icon', () {
    expect(smoke, contains(r'wait_for_property "$window_id" _NET_WM_ICON'));
    expect(smoke, contains('carries no _NET_WM_ICON'));
  });

  // The window enters the X tree before GTK has finished realizing it: the
  // title and WM_CLASS come from gdk_window_new(), while the icon is set at the
  // end of gtk_window_realize() after the icon-theme lookup. Reading a property
  // once raced that gap and failed the Flatpak build on main, so every property
  // read has to poll to the same deadline as the window itself.
  test('launch smoke waits for window properties instead of sampling once', () {
    expect(smoke, contains('wait_for_property()'));
    expect(smoke, contains(r'xprop -id "$1" "$2"'));
    expect(smoke, contains(r'local deadline=$((SECONDS + TIMEOUT_SECONDS))'));
    expect(smoke, contains(r'(( SECONDS < deadline )) || break'));
  });

  test('launch smoke re-checks identity after a close and reopen', () {
    expect(smoke, contains('launch_and_check "first launch"'));
    expect(smoke, contains('launch_and_check "reopen after close"'));
  });

  test('launch smoke cleans up app and temporary remote', () {
    expect(smoke, contains(r'flatpak kill "$APP_ID"'));
    expect(smoke, contains(r'flatpak --user uninstall -y "$APP_ID"'));
    expect(smoke, contains(r'flatpak --user remote-delete "$REMOTE_NAME"'));
    expect(smoke, contains('trap cleanup EXIT'));
  });

  test('launch smoke has no external download command', () {
    expect(smoke, isNot(contains('curl ')));
    expect(smoke, isNot(contains('wget ')));
  });
}
