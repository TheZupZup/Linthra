# Linthra Privacy Policy

Last updated: 2026-09-17

Linthra is an open-source Android music player focused on local music and user-controlled self-hosted music libraries.

This policy explains what information Linthra handles, where it is stored, and how it is used.

## Summary

- Linthra does not sell user data.
- Linthra does not include ads.
- Linthra does not use third-party advertising trackers.
- Linthra does not operate a cloud account system for users.
- Linthra does not send personal data to TheZupZup or to a Linthra-owned server.
- Server connections such as Jellyfin, Plex, and Subsonic/Navidrome are optional and are configured by the user.

## Data handled by the app

Depending on how the user chooses to use Linthra, the app may handle the following data on the user's device:

- Local music file information, such as song titles, album names, artists, duration, and artwork references.
- Playback state, queue information, favorites, playlists, and play history.
- Self-hosted server settings, such as server URL, selected library, and connection state.
- Authentication tokens or session details for user-configured music services such as Jellyfin, Plex, or Subsonic/Navidrome.
- Diagnostic information generated locally when the user chooses to report a problem.

## Local music

When the user grants access to local music files or folders, Linthra reads those files to build and display the music library. Local files remain on the user's device unless the user explicitly uses a feature that connects to their own server or exports information.

## Self-hosted and third-party music servers

Linthra can connect to user-configured music services, including Jellyfin, Plex, and Subsonic/Navidrome-compatible servers.

When the user connects one of these services, Linthra may send requests to that server to browse libraries, stream music, display artwork, and report playback state where supported by the server.

These connections are between the user's device and the server or service configured by the user. Linthra does not operate those servers. The privacy practices of those services are governed by the user's server configuration and the policies of the service provider.

## Authentication and tokens

Authentication tokens and session information are stored locally on the user's device. Linthra uses them only to connect to the music servers configured by the user.

Linthra is designed to avoid storing tokenized stream URLs in long-term storage, logs, diagnostics, or cache metadata.

## Data sharing

Linthra does not sell or share user data with advertisers or data brokers.

Linthra may communicate with user-configured music servers only when needed for app functionality, such as signing in, browsing a library, streaming tracks, fetching artwork, syncing metadata, or reporting playback state.

## Data storage and deletion

Most Linthra data is stored locally on the user's device. The user can remove app data by using Android system settings to clear Linthra's storage or uninstall the app.

When a user disconnects a music service inside Linthra, the related local session information is removed or made inactive according to the app's current implementation.

## Network security

Linthra supports connections to user-provided server URLs. Users are encouraged to use HTTPS whenever possible. If a user configures a server using an unencrypted HTTP connection, data sent to that server may not be encrypted in transit.

## Children

Linthra is not designed specifically for children. The app is intended for users who manage their own music library or self-hosted music services.

## Open source

Linthra is open-source. Its source code is available at:

https://github.com/TheZupZup/Linthra

## Checking this yourself

Some of this policy is checked automatically, so you do not have to take the
project's word for it.

Every pull request runs an audit of the dependency files Linthra ships from —
the resolved Dart/Flutter packages, the archives the Linux build fetches, the
plugins linked into the Linux binary, the Android Gradle files and the Rust
lockfiles — against a written list of known advertising, analytics, attribution,
telemetry and third-party crash-reporting SDKs. The current result is:

- Advertising SDKs: none
- Analytics SDKs: none
- Attribution / install-tracking SDKs: none
- Automatic third-party crash reporting: none
- Telemetry, session-replay and APM SDKs: none

You can reproduce it from a checkout with no toolchain and no network access:

```
python3 scripts/check_tracker_dependencies.py
```

That check proves a narrow thing: no *named* tracking SDK is in the dependency
graph. It does not prove that Linthra cannot track users, and it says nothing
about Linthra's own network code. What it covers, what it does not, and how a
future finding gets reviewed are written down in
[docs/tracker-dependency-audit.md](docs/tracker-dependency-audit.md).

## Contact

For privacy questions or support, contact:

support@linthra.ca
