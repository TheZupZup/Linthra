import 'dart:ffi';

/// Asks the dynamic loader to open [soname], and reports what it said when it
/// would not.
///
/// Returns null when the library opened. This is the same call media_kit makes
/// to find libmpv (`DynamicLibrary.open`), and the same probe
/// `scripts/verify_linux.sh` does from Python before it runs the audio smoke,
/// so the app's verdict about the runtime matches the one a contributor gets
/// from the verification script.
///
/// It is only ever reached *after* the backend has already failed to come up,
/// for one reason: media_kit swallows each individual open failure and reports
/// one fixed "cannot find libmpv" for all of them, which cannot tell a libmpv
/// that is absent from one that is present and refused. This can, because it
/// reads the loader's own message.
///
/// Opening a library that does load is harmless (the loader reference counts,
/// and media_kit is about to open the same one), and nothing is looked up
/// through the handle: this asks whether the library loads and nothing else.
String? probeNativeLibrary(String soname) {
  try {
    DynamicLibrary.open(soname);
    return null;
  } catch (error) {
    return error.toString();
  }
}
