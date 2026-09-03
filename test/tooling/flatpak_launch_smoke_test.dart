import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String smoke;

  setUpAll(() {
    smoke = File('scripts/flatpak_launch_smoke.sh').readAsStringSync();
  });

  test('launch smoke installs only from the local CI repository', () {
    expect(smoke, contains('REMOTE_NAME="linthra-ci-smoke-$$"'));
    expect(smoke, contains('--no-gpg-verify'));
    expect(smoke, contains('flatpak --user install -y'));
    expect(smoke, isNot(contains('https://')));
  });

  test('launch smoke preserves pre-existing Linthra installations', () {
    expect(smoke, contains('flatpak --user info "$APP_ID"'));
    expect(smoke, contains('flatpak --system info "$APP_ID"'));
    expect(smoke, contains('$APP_ID is already installed'));
  });

  test('launch smoke starts the packaged app and waits for a real window', () {
    expect(smoke, contains('flatpak run "$APP_ID"'));
    expect(smoke, contains('xwininfo -root -tree'));
    expect(smoke, contains('WINDOW_TITLE="Linthra"'));
    expect(smoke, contains('xvfb-run --auto-servernum'));
    expect(smoke, contains('dbus-run-session'));
  });

  test('launch smoke cleans up app and temporary remote', () {
    expect(smoke, contains('flatpak kill "$APP_ID"'));
    expect(smoke, contains('flatpak --user uninstall -y "$APP_ID"'));
    expect(smoke, contains('flatpak --user remote-delete "$REMOTE_NAME"'));
    expect(smoke, contains('trap cleanup EXIT'));
  });

  test('launch smoke has no external download command', () {
    expect(smoke, isNot(contains('curl ')));
    expect(smoke, isNot(contains('wget ')));
  });
}
