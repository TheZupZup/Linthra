# Linthra maintainer map

This document helps me understand Linthra as the maintainer.

## App entry point
- `lib/main.dart`: starts the app.

## Settings / About
- `lib/features/settings/`: contains settings screens.
- `lib/features/settings/about/`: contains the About screen and What's New section.

## Release files
- `pubspec.yaml`: defines the app version and package metadata.
- `lib/core/app_info.dart`: defines the in-app version.
- `docs/release-notes/`: contains GitHub release notes.
- `fastlane/metadata/android/en-US/changelogs/`: contains F-Droid / Android changelog files.

## Android config
- `android/app/src/main/AndroidManifest.xml`: Android app configuration.
- `android/app/src/main/res/xml/network_security_config.xml`: HTTP/TLS trust configuration.

## TODO to map later
- Playback
- Android Auto
- Offline cache
- Jellyfin provider
- Navidrome/Subsonic provider
- Plex provider
- Sync

## Maintainer notes

These notes are intentionally short. They are here to help future maintainers avoid risky changes without understanding the project first.

### Main layers
- `lib/app/`: startup, routing, and theme wiring.
- `lib/core/`: domain logic, interfaces, services, and provider sources.
- `lib/data/`: storage, Drift database, and repository implementations.
- `lib/features/`: user-facing screens and feature-specific UI.
- `lib/shared/`: reusable widgets and shared UI helpers.

### Storage wiring
Some repository providers in `lib/data/repositories/` default to in-memory implementations
and expose override constants for real storage. Examples:
- `favorites_repository_provider.dart`: default `InMemoryFavoritesStore`,
  real binding `sharedPreferencesFavoritesStoreOverride`.
- `playback_preferences_provider.dart`: default `InMemoryPlaybackPreferences`,
  real binding `sharedPreferencesPlaybackPreferencesOverride`.

The real bindings are applied through the override list in `lib/main.dart`.

When adding persistent storage, make sure the real store is wired there. Otherwise,
the app may appear to work during a session but lose that data after restart.

### Change with care
- `lib/core/services/linthra_audio_handler.dart`: foreground service, wake locks,
  and background playback.
- `lib/core/services/just_audio_playback_controller.dart`: playback control and
  audio-focus handling through `audio_session`.
- `lib/core/services/media_browser_tree.dart`: Android Auto browsing tree.
- Persisted URI schemes such as `jellyfin:`, `subsonic:`, and `plex:`.