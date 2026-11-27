// hook/rust_homes.dart: RUSTUP_HOME and CARGO_HOME worked out from disk,
// because the hooks runner doesn't pass them to the hook.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../hook/rust_homes.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('linthra_homes_'));
  tearDown(() => temp.deleteSync(recursive: true));

  String touch(String path) {
    File('${temp.path}/$path').createSync(recursive: true);
    return '${temp.path}/$path';
  }

  Uri package() => Directory('${temp.path}/app').uri;

  test("the Flatpak's layout gives both homes", () {
    // rustup-init with CARGO_HOME = RUSTUP_HOME = /var/lib/rustup, and the
    // vendored crates' config unpacked into the app's cargo/.
    final String cargo = touch('rustup/bin/cargo');
    Directory('${temp.path}/rustup/toolchains').createSync();
    touch('app/cargo/config.toml');

    expect(
      rustHomes(
        cargo: cargo,
        packageRoot: package(),
        environment: const <String, String>{},
      ),
      <String, String>{
        'RUSTUP_HOME': '${temp.path}/rustup',
        'CARGO_HOME': '${temp.path}/app/cargo',
      },
    );
  });

  test("rustup's default layout gives neither", () {
    // ~/.cargo/bin/cargo, with the toolchains in ~/.rustup.
    final String cargo = touch('.cargo/bin/cargo');
    Directory('${temp.path}/.rustup/toolchains').createSync(recursive: true);
    Directory('${temp.path}/app').createSync();

    expect(
      rustHomes(
        cargo: cargo,
        packageRoot: package(),
        environment: const <String, String>{},
      ),
      isEmpty,
    );
  });

  test('a cargo/ without a config is not a cargo home', () {
    final String cargo = touch('usr/bin/cargo');
    Directory('${temp.path}/app/cargo').createSync(recursive: true);

    expect(
      rustHomes(
        cargo: cargo,
        packageRoot: package(),
        environment: const <String, String>{},
      ),
      isEmpty,
    );
  });

  test('homes the environment does carry win', () {
    final String cargo = touch('rustup/bin/cargo');
    Directory('${temp.path}/rustup/toolchains').createSync();
    touch('app/cargo/config.toml');

    expect(
      rustHomes(
        cargo: cargo,
        packageRoot: package(),
        environment: const <String, String>{
          'RUSTUP_HOME': '/r',
          'CARGO_HOME': '/c',
        },
      ),
      <String, String>{'RUSTUP_HOME': '/r', 'CARGO_HOME': '/c'},
    );
  });
}
