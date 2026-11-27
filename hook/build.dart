// Builds native/linthra_core (Rust) as a shared library and hands it to
// Flutter as a code asset, so `flutter run`, `flutter build` and `flutter test`
// bundle it next to the app. lib/core/native/ calls it.
//
// The Rust core is required: the backend runs there and has no Dart copy. A
// build without Rust for the target (cargo/rustc not installed, no C linker,
// the target's standard library missing) fails here, saying what to install,
// rather than producing an app that can't start.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'rust_homes.dart';

/// The crate, relative to the package root.
const String _crateDir = 'native/linthra_core/';

/// The library name cargo gives the cdylib (`liblinthra_core.so`).
const String _libraryName = 'linthra_core';

/// The asset name lib/core/native/linthra_core_ffi.dart loads, as
/// `package:linthra/linthra_core`.
const String _assetName = 'linthra_core';

Future<void> main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    if (!input.config.buildCodeAssets) return;
    final CodeConfig code = input.config.code;
    final Uri crate = input.packageRoot.resolve(_crateDir);

    // Declared first, so that installing Rust later or editing the crate
    // re-runs the hook even after a run that failed.
    output.dependencies.addAll(_crateInputs(crate));

    final _RustTarget? target = _RustTarget.of(code);
    if (target == null) {
      _missing('Linthra builds its Rust core for Linux and Android only, not '
          '${code.targetOS.name}/${code.targetArchitecture.name}');
    }
    final String? cargo = _findTool('cargo');
    final String? rustc = _findTool('rustc');
    if (cargo == null || rustc == null) {
      _missing('cargo/rustc not found on PATH or in ~/.cargo/bin. Install '
          'Rust (https://rustup.rs), the version in .rust-version');
    }
    // Off Android, rustc links with the system's `cc`. An immutable desktop
    // (Fedora Kinoite, Silverblue) can have rustup in ~/.cargo but no
    // compiler outside a toolbox.
    if (target.androidClangPrefix == null && _findTool('cc') == null) {
      _missing('no C linker (cc) on PATH for ${target.triple}. Install gcc, '
          'or build inside a toolbox that has it');
    }
    final Map<String, String> homes = rustHomes(
      cargo: cargo,
      packageRoot: input.packageRoot,
      environment: Platform.environment,
    );
    if (!await _hasStandardLibrary(rustc, target.triple, homes)) {
      _missing('the Rust standard library for ${target.triple} is not '
          'installed (rustup target add ${target.triple})');
    }

    final Uri targetDir = input.outputDirectoryShared.resolve('cargo-target/');
    final ProcessResult result = await Process.run(
      cargo,
      <String>[
        'build',
        '--release',
        '--lib',
        // The crates are exactly the ones Cargo.lock names, with their
        // checksums. Where they are not cached yet cargo fetches them from
        // crates.io. The Flatpak builds with the network off: its CARGO_HOME
        // holds a config that replaces crates.io with the archives the
        // manifest pinned (flatpak/generated/sources/cargo.json), so nothing
        // is fetched there.
        '--locked',
        '--manifest-path',
        crate.resolve('Cargo.toml').toFilePath(),
        '--target',
        target.triple,
        '--target-dir',
        targetDir.toFilePath(),
      ],
      environment: <String, String>{
        ...homes,
        ...target.cargoEnvironment(code, homes['CARGO_HOME']),
      },
    );
    if (result.exitCode != 0) {
      throw Exception(
        'cargo build for ${target.triple} failed '
        '(exit ${result.exitCode}):\n${result.stderr}',
      );
    }

    final Uri library = targetDir.resolve(
      '${target.triple}/release/${code.targetOS.dylibFileName(_libraryName)}',
    );
    if (!File.fromUri(library).existsSync()) {
      throw Exception('cargo build succeeded but $library is missing');
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
  });
}

/// The files whose change must rebuild the library.
List<Uri> _crateInputs(Uri crate) {
  final List<Uri> inputs = <Uri>[
    crate.resolve('Cargo.toml'),
    crate.resolve('Cargo.lock'),
  ];
  final Directory sources = Directory.fromUri(crate.resolve('src/'));
  if (sources.existsSync()) {
    inputs.addAll(
      sources
          .listSync(recursive: true)
          .whereType<File>()
          .where((File file) => file.path.endsWith('.rs'))
          .map((File file) => file.uri),
    );
  }
  return inputs;
}

/// A Rust target triple, and how to link for it.
class _RustTarget {
  const _RustTarget(this.triple, {this.androidClangPrefix});

  final String triple;

  /// The NDK's per-target clang wrapper prefix (`aarch64-linux-android` for
  /// `aarch64-linux-android21-clang`), or null off Android.
  final String? androidClangPrefix;

  static _RustTarget? of(CodeConfig code) {
    final Architecture arch = code.targetArchitecture;
    if (code.targetOS == OS.linux) {
      if (arch == Architecture.x64) {
        return const _RustTarget('x86_64-unknown-linux-gnu');
      }
      if (arch == Architecture.arm64) {
        return const _RustTarget('aarch64-unknown-linux-gnu');
      }
      return null;
    }
    if (code.targetOS == OS.android) {
      if (arch == Architecture.arm64) {
        return const _RustTarget(
          'aarch64-linux-android',
          androidClangPrefix: 'aarch64-linux-android',
        );
      }
      if (arch == Architecture.arm) {
        return const _RustTarget(
          'armv7-linux-androideabi',
          androidClangPrefix: 'armv7a-linux-androideabi',
        );
      }
      if (arch == Architecture.x64) {
        return const _RustTarget(
          'x86_64-linux-android',
          androidClangPrefix: 'x86_64-linux-android',
        );
      }
      if (arch == Architecture.ia32) {
        return const _RustTarget(
          'i686-linux-android',
          androidClangPrefix: 'i686-linux-android',
        );
      }
      return null;
    }
    return null;
  }

  /// Extra environment for cargo.
  ///
  /// Everywhere: the crates' sources sit under cargo's home directory, whose
  /// path ends up in the library (in panic locations). It is remapped to
  /// `/cargo` so the library does not depend on whose home built it: F-Droid
  /// rebuilds the APK and compares it byte for byte with the one GitHub built.
  ///
  /// On Android, also links with the NDK's clang wrapper for the app's
  /// minimum API level, and aligns segments for 16 KB pages (required for
  /// apps targeting Android 15+ on such devices).
  Map<String, String> cargoEnvironment(CodeConfig code, String? cargoHome) {
    final String key = triple.toUpperCase().replaceAll('-', '_');
    final String remap =
        '--remap-path-prefix=${cargoHome ?? _defaultCargoHome()}=/cargo';
    final String? prefix = androidClangPrefix;
    if (prefix == null) {
      return <String, String>{'CARGO_TARGET_${key}_RUSTFLAGS': remap};
    }
    final CCompilerConfig? compiler = code.cCompiler;
    if (compiler == null) {
      throw Exception('Flutter passed no NDK compiler for $triple');
    }
    final String ndkBin = File.fromUri(compiler.compiler).parent.path;
    final String api = '${code.android.targetNdkApi}';
    final String clang = '$ndkBin/$prefix$api-clang';
    // cc-rs, which crates with C in them (dart-sys) build it with, reads
    // CC_<target> and AR_<target>; without them it guesses a GCC-style name
    // (`arm-linux-androideabi-clang`) the NDK doesn't ship.
    final String ccKey = triple.replaceAll('-', '_');
    return <String, String>{
      'CARGO_TARGET_${key}_LINKER': clang,
      'CARGO_TARGET_${key}_RUSTFLAGS':
          '-C link-arg=-Wl,-z,max-page-size=16384 $remap',
      'CC_$ccKey': clang,
      'AR_$ccKey': File.fromUri(compiler.archiver).path,
    };
  }
}

/// Cargo's home directory when nothing sets it.
String _defaultCargoHome() {
  final Map<String, String> env = Platform.environment;
  return env['CARGO_HOME'] ?? '${env['HOME'] ?? ''}/.cargo';
}

/// [name]'s path from PATH, then from cargo's default install location.
String? _findTool(String name) {
  final Map<String, String> env = Platform.environment;
  final List<String> directories = <String>[
    ...?env['PATH']?.split(':'),
    if (env['CARGO_HOME'] case final String cargoHome) '$cargoHome/bin',
    if (env['HOME'] case final String home) '$home/.cargo/bin',
  ];
  for (final String directory in directories) {
    if (directory.isEmpty) continue;
    final File candidate = File('$directory/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

/// Whether rustc has the standard library for [triple]: its target libdir
/// exists only once the target is installed.
Future<bool> _hasStandardLibrary(
  String rustc,
  String triple,
  Map<String, String> homes,
) async {
  final ProcessResult result = await Process.run(
    rustc,
    <String>['--print', 'target-libdir', '--target', triple],
    environment: homes,
  );
  if (result.exitCode != 0) return false;
  final String libdir = (result.stdout as String).trim();
  return libdir.isNotEmpty && Directory(libdir).existsSync();
}

Never _missing(String reason) {
  throw Exception('linthra_core: cannot build the Rust core: $reason.');
}
