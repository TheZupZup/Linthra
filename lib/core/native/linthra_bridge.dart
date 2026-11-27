import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'frb_generated.dart';
import 'linthra_core.dart';

/// The async side of the Rust core, through flutter_rust_bridge
/// (native/linthra_core/src/api/, bindings in lib/core/native/).
///
/// It shares the library hook/build.dart builds with the hand-written calls
/// in linthra_core_ffi.dart: [ready] lets [LinthraCore] load it first, then
/// opens it again by name, which the library's SONAME resolves to the copy
/// already loaded. Without the Rust core it stays false and callers keep
/// their Dart paths, as everywhere else.
abstract final class LinthraBridgeLoader {
  static Future<bool>? _ready;

  /// Whether the bridge is up, starting it on first use.
  static Future<bool> ready() => _ready ??= _start();

  static Future<bool> _start() async {
    if (!LinthraCore.isAvailable) return false;
    try {
      await LinthraBridge.init(
        externalLibrary: ExternalLibrary.open('liblinthra_core.so'),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
