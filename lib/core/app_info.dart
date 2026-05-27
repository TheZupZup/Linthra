/// Static, build-time app metadata.
abstract final class AppInfo {
  static const String name = 'Linthra';
  static const String tagline = 'Your music, beautifully yours.';

  /// Dev/local default `versionName`, mirroring the `x.y.z(-suffix)` part of
  /// `pubspec.yaml`'s `version` (the `+versionCode` is Android-only and not
  /// shown here). Used as the fallback when no release override is supplied —
  /// i.e. for local `flutter run`/`flutter build` and the test suite.
  ///
  /// `pubspec.yaml` is the source of truth for dev builds; this constant must
  /// match its `versionName`. `test/core/app_info_version_test.dart` fails CI if
  /// the two ever drift, so bump both together (see docs/release-process.md §1).
  static const String _devVersionName = '0.1.0-alpha.15';

  /// The release `versionName` injected by the release workflow via
  /// `--dart-define=LINTHRA_VERSION_NAME=<tag-derived version>`. Empty on local
  /// and CI-test builds (no dart-define), which is how [version] knows to fall
  /// back to [_devVersionName]. On a tagged release build it is the exact
  /// tag-derived version (see tool/version_from_tag.dart), so the in-app version
  /// always matches the released APK/AAB.
  static const String _definedVersionName =
      String.fromEnvironment('LINTHRA_VERSION_NAME');

  /// The effective app `versionName` shown in Settings/About, embedded in the
  /// diagnostics / "Report a bug" output, and sent to Jellyfin as the client
  /// version. Reads the release override when present, else the dev fallback —
  /// the same value Android's build metadata uses on a tagged build.
  static String get version =>
      resolveVersion(_definedVersionName, _devVersionName);

  /// Pure selection rule behind [version]: prefer the release-injected
  /// [defined] value, falling back to [devFallback] when it is empty (no
  /// dart-define). Exposed so the override/fallback behavior is unit-testable
  /// without recompiling the suite with a dart-define.
  static String resolveVersion(String defined, String devFallback) =>
      defined.isEmpty ? devFallback : defined;
}
