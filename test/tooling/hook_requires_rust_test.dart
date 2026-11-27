// hook/build.dart where it can't build the Rust core: the build fails and
// says why, instead of producing an app without its backend.
import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';

import '../../hook/build.dart' as hook;

void main() {
  test('a target with no Rust core fails the build, saying why', () async {
    // Windows has no Rust triple in the hook, so this takes the "can't build
    // the Rust core here" path wherever the test runs.
    await expectLater(
      testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.windows,
        targetArchitecture: Architecture.x64,
        check: (BuildInput input, BuildOutput output) {
          fail('the hook built ${output.assets.code} without Rust');
        },
      ),
      throwsA(
        isA<Exception>().having(
          (Exception e) => '$e',
          'message',
          allOf(contains('cannot build the Rust core'), contains('windows')),
        ),
      ),
    );
  });
}
