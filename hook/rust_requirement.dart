// Whether a build may go without the Rust core, kept apart from build.dart so
// a test can hold it to both answers.

import 'dart:io';

/// The user-define that makes the Rust core required: in the app's
/// pubspec.yaml,
///
/// ```yaml
/// hooks:
///   user_defines:
///     linthra:
///       require_rust: true
/// ```
///
/// A user-define and not an environment variable: the hooks runner passes a
/// hook only a fixed set of variables (PATH, HOME, ANDROID_HOME, proxies and
/// a few more), so `LINTHRA_REQUIRE_RUST` never reaches it. The F-Droid
/// recipe sets it, so a build server without Rust fails here, saying why,
/// rather than producing an APK that can't match the signed one.
const String requireRustDefine = 'require_rust';

/// Whether [define], the value of [requireRustDefine], asks for the Rust
/// core: `true` only, so a typo can't quietly ask for nothing.
bool rustCoreRequired(Object? define) => define == true;

/// What happens when the Rust core can't be built for this target: the
/// build fails when it is [required], and goes on without it otherwise,
/// saying so on stderr.
void missingRustCore(String reason, {required bool required}) {
  if (required) {
    throw StateError(
      'linthra_core: the Rust core is required ($requireRustDefine) but '
      'cannot be built: $reason.',
    );
  }
  stderr.writeln('linthra_core: building without the Rust core: $reason.');
}
