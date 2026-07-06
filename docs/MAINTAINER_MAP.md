# Linthra maintainer map

This document helps me understand Linthra as the maintainer.

## App entry point
- `lib/main.dart`: starts the app.

## Settings / About
- `lib/features/settings/`: settings screens.
- `lib/features/settings/about/`: About screen and What's New section.

## Release files
- `pubspec.yaml`: app version.
- `lib/core/app_info.dart`: in-app version.
- `docs/release-notes/`: GitHub release notes.
- `fastlane/metadata/android/en-US/changelogs/`: F-Droid / Android changelog.

## Android config
- `android/app/src/main/AndroidManifest.xml`: Android app config.
- `android/app/src/main/res/xml/network_security_config.xml`: HTTP/TLS trust config.

## TODO to map later
- Playback
- Android Auto
- Offline cache
- Jellyfin provider
- Navidrome/Subsonic provider
- Plex provider
- Sync

