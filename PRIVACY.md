# Linthra Privacy Policy

Last updated: 2026-09-29

Linthra is an open-source Android music player focused on local music and user-controlled self-hosted music libraries.

This policy explains what information Linthra handles, where it is stored, and how it is used.

## Summary

- Linthra does not sell user data.
- Linthra does not include ads.
- Linthra does not use third-party advertising trackers.
- Linthra does not operate a cloud account system for users.
- Linthra does not send personal data to TheZupZup or to a Linthra-owned server.
- Server connections such as Jellyfin, Plex, Subsonic/Navidrome, and Audiobookshelf are optional and are configured by the user.

## Data handled by the app

Depending on how the user chooses to use Linthra, the app may handle the following data on the user's device:

- Local music file information, such as song titles, album names, artists, duration, and artwork references.
- Playback state, queue information, favorites, playlists, and play history.
- Self-hosted server settings, such as server URL, selected library, and connection state.
- Authentication tokens or session details for user-configured music services such as Jellyfin, Plex, Subsonic/Navidrome, or Audiobookshelf.
- In the GitHub Sponsor APK only, and only if the user chooses to connect GitHub: a GitHub access token, used to check sponsorship.
- Diagnostic information generated locally when the user chooses to report a problem.

## Local music

When the user grants access to local music files or folders, Linthra reads those files to build and display the music library. Local files remain on the user's device unless the user explicitly uses a feature that connects to their own server or exports information.

## Self-hosted and third-party music servers

Linthra can connect to user-configured music services, including Jellyfin, Plex, Subsonic/Navidrome-compatible, and Audiobookshelf servers.

When the user connects one of these services, Linthra may send requests to that server to browse libraries, stream music, display artwork, and report playback state where supported by the server.

These connections are between the user's device and the server or service configured by the user. Linthra does not operate those servers. The privacy practices of those services are governed by the user's server configuration and the policies of the service provider.

## Other services Linthra contacts

Apart from the servers you configure, Linthra contacts two outside services, and only in these cases:

- **Plex sign-in (plex.tv).** If you choose "Connect with Plex", Linthra talks to plex.tv, Plex's account service, to create a sign-in code, wait for you to approve it on the Plex page that opens in your browser, and then list the servers and Plex Home users on your account. Nothing contacts plex.tv at startup or in the background. Signing in with a server address and token instead does not use plex.tv at all.
- **GitHub Sponsors check (GitHub Sponsor APK only).** The APK attached to GitHub Releases for sponsors can unlock supporter extras. If you choose "Connect GitHub", Linthra uses GitHub's device sign-in (github.com) and then asks GitHub's API (api.github.com) whether your account sponsors the project. Once you have signed in, that check runs again each time the app starts, until you disconnect. The F-Droid, Google Play, Flatpak and other builds do not contain this and never contact GitHub on their own.

Links in the app, such as the project page, the privacy policy or the prefilled bug report, open in your browser when you tap them. Linthra does not fetch them itself.

## Authentication and tokens

Authentication tokens and session information are stored locally on the user's device, in the platform's secure storage. Linthra uses music server tokens only to connect to the music servers configured by the user.

In the GitHub Sponsor APK, if the user connects GitHub, Linthra also stores the GitHub access token that GitHub issues for it. The token is limited to reading the user's GitHub profile (the `read:user` scope). Linthra sends it only to GitHub's API (api.github.com), only to check whether the account sponsors the project, and deletes it when the user disconnects GitHub. No other build stores a GitHub token.

Linthra is designed to avoid storing tokenized stream URLs in long-term storage, logs, diagnostics, or cache metadata.

## Data sharing

Linthra does not sell or share user data with advertisers or data brokers.

Linthra may communicate with user-configured music servers only when needed for app functionality, such as signing in, browsing a library, streaming tracks, fetching artwork, syncing metadata, or reporting playback state. The only other services it contacts are the ones listed under "Other services Linthra contacts" above, in the situations described there.

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

A second check lists every host name and IP address written into the code
Linthra ships, against a reviewed inventory that says what each one is for. A
new fixed destination, or a known one turning up somewhere new, fails the pull
request until a person reviews it. Today it finds three hosts Linthra's own code
connects to (plex.tv, github.com and api.github.com, as described above) and
nothing that is contacted without you doing something first:

```
python3 scripts/check_network_destinations.py
```

It only sees addresses written down in the source, not ones built at run time
or returned by a server. The details are in
[docs/network-destinations.md](docs/network-destinations.md), and
[PRIVACY_AUDIT.md](PRIVACY_AUDIT.md) lists every check, what is still checked
by hand, and the limits of both.

## Contact

For privacy questions or support, contact:

support@linthra.ca
