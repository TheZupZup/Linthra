# Android 17 (API 37)

Linthra targets Android 17 (API 37) from 0.2.10. `minSdk` is unchanged (24, from
Flutter), so every phone that ran 0.2.9 still gets updates.

This page says what that changed, what the app does about it, and what is left
to check by hand. Sources were read on 2026-10-09; links are at the end.

## Build

- `compileSdk` and `targetSdk` are set to 37 in `android/app/build.gradle`. The
  pinned Flutter (see `.flutter-version`) still defaults both to 36, which is
  what 0.2.9 shipped with.
- API 37 needs Android Gradle Plugin 9.1.1 or later. The build is on AGP 9.1.1,
  Gradle 9.3.1 and the Kotlin Gradle plugin 2.4.21, the first Kotlin line
  documented for that AGP and Gradle pair.
- `android/gradle.properties` sets `android.newDsl=false` and
  `android.builtInKotlin=false`. They are AGP 9's documented opt-outs, and the
  same two Flutter's own template and migrator write. Flutter's Gradle plugin
  and the F-Droid per-ABI versionCode hook still use the legacy variant API, and
  several plugins still apply `kotlin-android`. Google removes both opt-outs in
  AGP 10, so that move needs the hook ported to `androidComponents.onVariants`.
- CI reads `targetSdkVersion` and `minSdkVersion` back out of the built APK and
  App Bundle with the SDK's `aapt2` (`scripts/check_android_target_sdk.py`), on
  every PR and on every release build.

## Google Play

As of 2026-10-09, per Google's target API page (last updated 2026-10-01):

- **Required today:** since 2026-08-31, new apps and updates must target API 36
  or higher (an extension to 2026-11-01 could be requested). 0.2.9 meets that.
- **API 37** is not a Play requirement yet. Google has not published a date for
  it. Targeting 37 is ahead of the requirement, not a response to one.
- `mediaPlayback` foreground service: apps targeting 34+ declare their
  foreground service types under Policy > App content. Linthra's declaration is
  unchanged by this release.
- `ACCESS_LOCAL_NETWORK`: Google's docs do not list it among the permissions
  that need a Play Console declaration form. If the Console shows one after the
  upload, the answer is the rationale in the manifest comment.

What the developer does in Play Console for 0.2.10 (nothing here is automated):

1. Leave the 0.2.9 submission alone until its review finishes.
2. Upload the 0.2.10 AAB to closed testing first. Its versionCode is higher than
   0.2.9's, and the package name and upload key are the same.
3. Check App content > Foreground service permissions still lists media
   playback.
4. If Play asks about `ACCESS_LOCAL_NETWORK`, explain it is used only to reach a
   music server the user set up on their own network, asked when they connect
   to or play from it.
5. Data safety: nothing changes. The permission collects nothing and sends
   nothing anywhere new.

## Local network permission

For an app targeting 37, Android 17 blocks connections to the local network
(the private IPv4 ranges, carrier-grade NAT space, link-local, multicast, IPv6
unique-local and link-local addresses, on Wi-Fi or Ethernet) until the user
grants `ACCESS_LOCAL_NETWORK`. It covers every network stack, Dart sockets and
ExoPlayer included. Dart sockets can't raise the prompt, so a blocked TCP
connect just times out. A system picker can stand in for the permission when
discovering devices, but not for a server address the user typed, which is how
Linthra reaches Jellyfin, Navidrome, Plex and Audiobookshelf. So Linthra asks
for the permission:

- **Only for a local server.** The server's host is resolved first (DNS is
  exempt from the permission). A server on the internet, local files and
  downloads never involve it. A name that resolves to a LAN address at home
  counts as local, and so does a `.local` name.
- **Only after the user does something.** Test connection, Sign in, Connect,
  picking a Plex server, or playing from a local server while the app is on
  screen (at most once per app session). Never at launch, never from a sync,
  probe or prefetch, and never with the app off screen (Android Auto, a
  headset, the lock screen).
- **Fails fast and says why.** While it's missing, requests to a local server
  are refused at once instead of timing out, and the error says what to do. The
  Jellyfin library is held back the way it is when the server is unreachable,
  and comes back as soon as access is granted.
- **Not behind a VPN.** Android only guards Wi-Fi and Ethernet. With a VPN up,
  a private address may go through the tunnel (Tailscale's 100.64.0.0/10, a
  home LAN reached over WireGuard) and need no permission, so Linthra doesn't
  refuse it. A user action can still ask, since the VPN may leave the LAN
  outside the tunnel.
- **Settings > Connections** shows a "Local network access" card while a
  configured server is local and the permission is missing. It offers Allow,
  or Android settings once Android has stopped showing the dialog.
- Before Android 17, and on Linux, none of this runs. The Kotlin channel reports
  "not required" and nothing is looked up or asked.

Cast discovery is unaffected for now because Cast is contained in shipped
builds. Bringing it back will need the same permission, or the system output
switcher.

## Background audio

Android 17 silences audio from an app with no visible activity and no running
foreground service, and refuses its audio focus requests. For apps targeting
37, the foreground service also has to have while-in-use rights, meaning it was
started while the app was visible or from a notification, widget or media key.
Linthra starts its `mediaPlayback` service through `audio_service` when playback
starts. Three paths could start audio from the background without that:

- **Focus regain after a call.** The session used to drop its foreground hold
  a moment before the resume asked for audio focus, so the resume asked from
  the background. The hold now lasts until the engine plays again.
- **Hold expiry.** If focus hadn't come back after five minutes, the hold
  ended, but a later regain still resumed. That resume would start audio with
  no foreground service, so the resume now ends with the hold (Google's
  guidance), and the user presses Play. A regain that already came back and is
  still loading or rebuffering when the five minutes run out keeps its resume.
- **Jellyfin remote control.** A Play or skip from another device while
  Linthra is paused in the background is ignored. A remote can still pause,
  stop, seek and drive playback that's already running, and can start it while
  Linthra is on screen.

Notification, lock screen, headset, Bluetooth and Android Auto controls are
media keys or system bindings, which Android treats as the user's own action.

## Other Android 17 changes, checked

- **Certificate transparency** is on by default at API 37, but not for
  connections that trust user-added CAs. Linthra's network security config
  trusts the user store, so private-CA servers keep working. TLS validation is
  unchanged.
- **Cleartext:** `usesCleartextTraffic` is being deprecated. Linthra already
  uses a network security config.
- **Large screens:** at 37 apps can no longer opt out of resizing on 600dp+
  displays. Linthra never opted out.
- **Predictive back:** the `enableOnBackInvokedCallback="false"` opt-out is
  still documented. Its behaviour at 37 needs a device check (below).
- **Native libraries** loaded with `System.load()` must be read-only. Linthra
  loads none that way; its libraries come from the APK.
- **Edge-to-edge** has been enforced since targeting 36. Nothing new at 37.

## Testing on a device

None of this has been run on an Android 17 device or emulator yet. The
environment that prepared it couldn't download the Android SDK. Before a
release, on an Android 17 device or emulator:

```sh
# Local network: revoke it (Android restarts the app), or grant it without the
# dialog. A fresh install starts from "never asked".
adb shell pm revoke io.github.thezupzup.linthra android.permission.ACCESS_LOCAL_NETWORK
adb shell pm grant io.github.thezupzup.linthra android.permission.ACCESS_LOCAL_NETWORK

# Background audio: make violations throw instead of failing silently.
adb shell cmd audio set-enable-hardening throw
adb logcat | grep AudioHardening
```

Then check:

- Play from a LAN server, lock the phone, and keep listening for 10+ minutes.
- With Tailscale (or another VPN) up and local network access denied, stream
  from a server on its 100.x address.
- During playback, take a call, end it, and confirm playback resumes.
- Pause from the notification, then resume from a Bluetooth headset.
- From Android Auto, start playback from a cold start.
- Revoke local network access during playback, reopen the app, and confirm it
  asks again.
- Check Back on every tab and in dialogs.

On an older phone (Android 14 to 16), confirm nothing asks for local network
access and streaming from a LAN server works as before.

## Known limits

- A server whose only address is a global IPv6 address on the same subnet is
  local to Android but not to Linthra's address check, so Linthra won't ask
  for it and the connection fails as unreachable. Granting access in Android
  settings fixes it.
- A VPN is spotted by its interface name (`tun`, `wg`, `ipsec`, `ppp`). With
  one up and local network access off, a LAN server reached outside the tunnel
  is tried and times out instead of failing fast.
- When Android Auto or a headset starts Linthra with no activity, the
  permission can't be read. Requests to a local server are then tried as
  before and time out if access is off, until the app is opened once.
- Resuming from a Bluetooth headset after a long pause relies on
  `audio_service` bringing its service back to the foreground, as before.

## Sources

- https://developer.android.com/google/play/requirements/target-sdk
- https://developer.android.com/about/versions/17/behavior-changes-17
- https://developer.android.com/about/versions/17/behavior-changes-all
- https://developer.android.com/about/versions/17/changes/bg-audio
- https://developer.android.com/privacy-and-security/local-network-permission
- https://developer.android.com/privacy-and-security/local-network-definition
- https://developer.android.com/privacy-and-security/security-config
- https://developer.android.com/develop/background-work/services/fgs/service-types
- https://developer.android.com/build/releases/agp-9-1-0-release-notes
- https://developer.android.com/build/releases/agp-9-0-0-release-notes
- https://kotlinlang.org/docs/gradle-configure-project.html
