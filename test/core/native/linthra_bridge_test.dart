import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/api/core.dart';
import 'package:linthra/core/native/linthra_bridge.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// The flutter_rust_bridge path works end to end on the library the hook
/// builds: an async call and a stream. Every backend phase rides on this.
void main() {
  group('Rust bridge', () {
    test('starts on the library the hook built', () async {
      expect(await LinthraBridgeLoader.ready(), isTrue);
    });

    test('answers an async call with the same ABI as the C calls', () async {
      await LinthraBridgeLoader.ready();
      expect(await bridgeAbiVersion(), LinthraCore.abiVersion);
    });

    test('streams values and closes', () async {
      await LinthraBridgeLoader.ready();
      expect(await bridgeCount(to: 5).toList(), <int>[1, 2, 3, 4, 5]);
    });
  });
}
