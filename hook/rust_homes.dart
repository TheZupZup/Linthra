// Where rustup and cargo keep their state, for the Rust tools hook/build.dart
// runs.
//
// The hooks runner hands a hook a fixed set of environment variables (PATH,
// HOME, proxies and a few more), so a RUSTUP_HOME or CARGO_HOME the build
// sets never arrives. Where rustup's defaults (~/.rustup, ~/.cargo) hold the
// toolchain that changes nothing. The Flatpak installs it under
// /var/lib/rustup and points cargo at vendored crates instead, and without
// both the hook found no standard library there and the Flatpak shipped
// without the Rust core. So both are worked out from what is on disk.
import 'dart:io';

/// RUSTUP_HOME and CARGO_HOME for [cargo] (the path the hook found it at),
/// building the package at [packageRoot]. Only the ones that differ from
/// rustup's defaults are given; [environment] wins where it has them.
Map<String, String> rustHomes({
  required String cargo,
  required Uri packageRoot,
  required Map<String, String> environment,
}) {
  final String? rustupHome = environment['RUSTUP_HOME'] ?? _rustupHome(cargo);
  final String? cargoHome =
      environment['CARGO_HOME'] ?? _vendoredCargoHome(packageRoot);
  return <String, String>{
    if (rustupHome != null) 'RUSTUP_HOME': rustupHome,
    if (cargoHome != null) 'CARGO_HOME': cargoHome,
  };
}

/// The directory [cargo] was installed into when it also holds rustup's
/// toolchains: rustup-init with CARGO_HOME and RUSTUP_HOME both set to one
/// directory, as the Flatpak's rustup module runs it. Null otherwise.
String? _rustupHome(String cargo) {
  final Directory bin = File(cargo).parent;
  if (bin.uri.pathSegments.where((String s) => s.isNotEmpty).last != 'bin') {
    return null;
  }
  final Directory home = bin.parent;
  if (!Directory('${home.path}/toolchains').existsSync()) return null;
  return home.path;
}

/// `cargo/` in the package when it holds a cargo config: where the Flatpak
/// manifest unpacks the vendored crates and the config that replaces
/// crates.io with them (flatpak/generated/sources/cargo.json). Null
/// otherwise.
String? _vendoredCargoHome(Uri packageRoot) {
  if (!File.fromUri(packageRoot.resolve('cargo/config.toml')).existsSync()) {
    return null;
  }
  return packageRoot.resolve('cargo').toFilePath();
}
