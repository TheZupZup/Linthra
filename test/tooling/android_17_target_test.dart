import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the Android 17 (API 37) build contract: what Linthra targets, the
/// toolchain that can build it, and the permission set it declares for it.
///
/// These read the source files, not a built artifact. The built APK and AAB
/// are checked in CI by scripts/check_android_target_sdk.sh.
String _read(String path) => File(path).readAsStringSync();

List<int> _version(String text) =>
    text.split('.').map(int.parse).toList(growable: false);

bool _atLeast(List<int> v, List<int> min) {
  for (int i = 0; i < min.length; i++) {
    final int part = i < v.length ? v[i] : 0;
    if (part != min[i]) return part > min[i];
  }
  return true;
}

void main() {
  final String appGradle = _read('android/app/build.gradle');
  final String settings = _read('android/settings.gradle');
  final String properties = _read('android/gradle.properties');
  final String manifest = _read('android/app/src/main/AndroidManifest.xml');

  group('target and compile SDK', () {
    test('both are API 37, set explicitly rather than inherited', () {
      // The pinned Flutter still defaults both to 36, which is what kept the
      // build on API 36 while it read flutter.targetSdkVersion.
      expect(appGradle,
          contains(RegExp(r'^\s*compileSdk = 37$', multiLine: true)));
      expect(
          appGradle, contains(RegExp(r'^\s*targetSdk = 37$', multiLine: true)));
      expect(appGradle, isNot(contains('flutter.targetSdkVersion')));
      expect(appGradle, isNot(contains('flutter.compileSdkVersion')));
    });

    test('minSdk is untouched, so no device is dropped', () {
      expect(appGradle, contains('minSdk = flutter.minSdkVersion'));
    });

    test('the Android Gradle Plugin can build API 37', () {
      final String agp =
          RegExp(r'id\s+"com\.android\.application"\s+version\s+"([^"]+)"')
              .firstMatch(settings)!
              .group(1)!;
      expect(_atLeast(_version(agp), <int>[9, 1, 1]), isTrue,
          reason: 'AGP $agp predates API 37 support (9.1.1)');
    });

    test('the AGP 9 opt-outs Flutter needs are set explicitly', () {
      expect(properties,
          contains(RegExp(r'^android\.newDsl=false$', multiLine: true)));
      expect(properties,
          contains(RegExp(r'^android\.builtInKotlin=false$', multiLine: true)));
    });

    test('plugins pinned to an older compileSdk are raised to the app\'s', () {
      // AGP 9 checks each library module against what its AndroidX
      // dependencies need; bonsoir_android 5.x still compiles against 33.
      final String root = _read('android/build.gradle');
      expect(root, contains('sub.plugins.withId("com.android.library")'));
      expect(root, contains('androidComponents.finalizeDsl'));
      expect(root, contains('rootProject.project(":app").android.compileSdk'));
    });

    test('the Kotlin options use compilerOptions, not kotlinOptions', () {
      // Kotlin Gradle plugin 2.3+ rejects kotlinOptions.
      expect(appGradle, isNot(contains(RegExp(r'kotlinOptions\s*\{'))));
      expect(appGradle, contains('compilerOptions'));
    });
  });

  group('declared permissions', () {
    final Set<String> declared = RegExp(
            r'<uses-permission\s+android:name="android\.permission\.([A-Z_]+)"')
        .allMatches(manifest)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();

    test('are exactly the reviewed set', () {
      expect(declared, <String>{
        'FOREGROUND_SERVICE',
        'FOREGROUND_SERVICE_MEDIA_PLAYBACK',
        'WAKE_LOCK',
        'POST_NOTIFICATIONS',
        'READ_MEDIA_AUDIO',
        'READ_EXTERNAL_STORAGE',
        'INTERNET',
        'ACCESS_NETWORK_STATE',
        'ACCESS_LOCAL_NETWORK',
        'CHANGE_WIFI_MULTICAST_STATE',
      });
    });

    test('include no shortcut around Android 17\'s rules', () {
      // Background audio needs a foreground service, not alarms or battery
      // exemptions; local servers need ACCESS_LOCAL_NETWORK, not location or
      // the broader Wi-Fi scanning permission.
      for (final String shortcut in <String>[
        'SCHEDULE_EXACT_ALARM',
        'USE_EXACT_ALARM',
        'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        'SYSTEM_ALERT_WINDOW',
        'ACCESS_FINE_LOCATION',
        'ACCESS_COARSE_LOCATION',
        'ACCESS_BACKGROUND_LOCATION',
        'NEARBY_WIFI_DEVICES',
        'MANAGE_EXTERNAL_STORAGE',
        'QUERY_ALL_PACKAGES',
        'FOREGROUND_SERVICE_SPECIAL_USE',
      ]) {
        expect(manifest, isNot(contains('android.permission.$shortcut')),
            reason: shortcut);
      }
    });

    test('the playback service stays a mediaPlayback foreground service', () {
      expect(
        manifest,
        contains(RegExp(
            r'android:name="com\.ryanheise\.audioservice\.AudioService"\s+'
            r'android:foregroundServiceType="mediaPlayback"')),
      );
    });
  });

  group('the local network permission channel', () {
    final String channel = _read('android/app/src/main/kotlin/io/github/'
        'thezupzup/linthra/LocalNetworkPermissionChannel.kt');
    final String activity = _read(
        'android/app/src/main/kotlin/io/github/thezupzup/linthra/MainActivity.kt');

    test('only applies on Android 17+ for an app targeting 37', () {
      expect(channel, contains('Build.VERSION.SDK_INT >= ANDROID_17'));
      expect(channel, contains('targetSdkVersion >= ANDROID_17'));
      expect(channel, contains('private const val ANDROID_17 = 37'));
      expect(channel, contains('"android.permission.ACCESS_LOCAL_NETWORK"'));
    });

    test('asks only when Dart asks, never while being set up', () {
      final String configure = RegExp(r'fun configure\([\s\S]*?\n    \}')
          .firstMatch(channel)!
          .group(0)!;
      expect(configure, isNot(contains('requestPermissions')));
      expect(RegExp('requestPermissions').allMatches(channel), hasLength(1));
      expect(activity, contains('localNetworkPermissionChannel.configure('));
      expect(
          activity,
          contains(
              'localNetworkPermissionChannel.onRequestPermissionsResult('));
    });
  });
}
