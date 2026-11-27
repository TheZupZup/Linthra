// hook/build.dart without Rust for a target: a contributor's build goes on
// without the Rust core, a build that asks for it (the F-Droid recipe's
// `require_rust` user-define) fails and says why.
import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';

import '../../hook/build.dart' as hook;
import '../../hook/rust_requirement.dart';

/// The hook run for Windows, a target it has no Rust triple for, so it
/// takes the "can't build the Rust core here" path wherever the test runs.
Future<List<CodeAsset>> _runWithout({Map<String, Object?>? defines}) async {
  final List<CodeAsset> built = <CodeAsset>[];
  await testCodeBuildHook(
    mainMethod: hook.main,
    targetOS: OS.windows,
    targetArchitecture: Architecture.x64,
    userDefines: defines == null
        ? null
        : PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              defines: defines,
              basePath: Uri.directory('/'),
            ),
          ),
    check: (BuildInput input, BuildOutput output) {
      built.addAll(output.assets.code);
    },
  );
  return built;
}

void main() {
  test('a build that does not ask for Rust goes on without it', () async {
    expect(await _runWithout(), isEmpty);
    expect(
      await _runWithout(defines: <String, Object?>{'require_rust': false}),
      isEmpty,
    );
  });

  test('a build that asks for Rust fails, saying why', () async {
    await expectLater(
      _runWithout(defines: <String, Object?>{'require_rust': true}),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          allOf(contains('require_rust'), contains('windows')),
        ),
      ),
    );
  });

  test('only a real true asks for it', () {
    expect(rustCoreRequired(true), isTrue);
    for (final Object? value in <Object?>[null, false, 'true', 1, 'yes']) {
      expect(rustCoreRequired(value), isFalse, reason: '$value');
    }
  });
}
