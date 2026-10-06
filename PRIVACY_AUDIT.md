# Linthra privacy audit

[PRIVACY.md](PRIVACY.md) says Linthra carries no advertising, analytics or
crash-reporting SDKs, and does not send your data to the project or to anyone
you did not choose. This page is about how much of that you can check without
taking our word for it.

Please read this first: **none of the checks below prove that Linthra cannot
track anyone.** Each one shows a specific, narrow property, and each has limits
written next to it. Put together, they make a quiet regression hard to land
without somebody noticing. That is the goal, and it is the only claim this page
makes.

The work is tracked in [#504](https://github.com/TheZupZup/Linthra/issues/504).

## Current status

```text
Advertising SDKs in the dependency graph:           none
Analytics SDKs in the dependency graph:             none
Attribution / install-tracking SDKs:                none
Automatic third-party crash reporting:              none
Telemetry, session-replay and APM SDKs:             none
Fixed hosts contacted with no user action:          none
Fixed hosts contacted after a one-time opt-in:      api.github.com (GitHub Sponsor APK only)
Android merged-manifest surface check:              not automated yet
Privacy report for the release APK:                 not automated yet
Runtime outbound-network smoke test:                not automated yet
```

The first six lines come from checks that run on every pull request. The last
three are the parts of #504 still to do.

## Automated checks

Each of these runs in CI, and each can be run from a checkout with no network
access and no Flutter or Android toolchain.

| What it shows | When it runs | Reproduce it | Details |
| --- | --- | --- | --- |
| No known advertising, analytics, attribution, telemetry or crash-reporting SDK is in the dependency files Linthra ships from (pub, Gradle, vendored modules, Cargo) | Every pull request | `python3 scripts/check_tracker_dependencies.py` | [tracker-dependency-audit.md](docs/tracker-dependency-audit.md) |
| Every host name and IP address written into the shipped source is reviewed, with what it is for, and only in the files it was reviewed in | Every pull request | `python3 scripts/check_network_destinations.py` | [network-destinations.md](docs/network-destinations.md) |
| No committed keys, tokens or private data, and no real server URLs or home paths in diagnostics fixtures | Every pull request | `./scripts/check_secrets.sh` | [development.md](docs/development.md#privacy-guardrails) |
| Every Flatpak sandbox permission has a written reason, and nothing broader than listed is granted | Every pull request | `python3 scripts/check_flatpak_permissions.py` | [flatpak-permissions.md](docs/flatpak-permissions.md) |
| New network-capable code, and changes to Android permissions or the network security config, need an owner's review | Every pull request | `python3 scripts/check_pr_security_surface.py --base <sha> --head <sha> --report out.md` | [pr-security-guard.md](docs/pr-security-guard.md) |
| Release APKs, AABs, the Linux tarball and the Flatpak bundle are checked after they are built, and their SHA-256 is recorded | Every release | `python3 scripts/verify_release_containment.py <downloaded release files>` | [release-artifact-verification.md](docs/release-artifact-verification.md) |

The last row checks the built artifacts for the Cast security containment, not
for privacy as such. It is listed because it is the one check that already reads
the binary users install, and the planned APK privacy report builds on it.

## Checked by hand

These were reviewed by reading the source on 2026-09-29: `main` at `de23474`
plus the changes in the pull request that added this page. They are not
automated, so they are only as current as that review.

- **Nothing is contacted at startup on a clean install.** With no server
  configured, the app bootstrap starts local services only. The background
  work that does use the network (artwork prewarm, precaching, playback
  reporting, resuming an unfinished Navidrome/Subsonic library sync, the
  Jellyfin availability check and control socket) only runs against a server
  you have configured.
- **The Android platform code has no networking of its own.** The Kotlin in
  `android/app/src/main/kotlin` reads connectivity state (metered or not) and
  does nothing else with the network. Playback goes through Media3, which
  plays the URLs it is given.
- **The native libraries have no networking.** `native/` (Rust and C++)
  declares no network crates or libraries and makes no network calls.
- **Casting sends nothing.** Casting is switched off in shipped builds (see
  [cast.md](docs/cast.md)), so there is no Cast discovery or Cast traffic at
  all. The release artifact check above confirms the Cast code is absent from
  the compiled app.
- **Links are links.** The project, privacy policy, sponsor and bug report links
  open in your browser when tapped, and the support address opens a draft in
  your mail app. Nothing is submitted or sent for you.

## Still to do in #504

- **Android permissions and exported components.** The permission tables in
  [fdroid-readiness.md](docs/fdroid-readiness.md) and
  [play-store-readiness.md](docs/play-store-readiness.md) are written by hand.
  They now match the manifest (including `READ_MEDIA_AUDIO` and
  `READ_EXTERNAL_STORAGE` with `maxSdkVersion="32"`), but nothing stops them
  drifting again. The plan is to check the final merged manifest, including
  what plugins add, against a reviewed baseline, and keep those tables in step
  with it.
- **A privacy report for the exact APK you install.** SHA-256, package and
  version, signing certificate fingerprint, effective permissions, native
  libraries, SDK indicators and host strings, generated from the release APK
  itself and attached to the GitHub Release.
- **A runtime network smoke test.** Run the app in a controlled network with
  no server configured and confirm it contacts nothing, then with a local test
  server configured and confirm it contacts only that server.

This page will be updated as each of those lands.

## Limits, in one place

- The dependency check finds SDKs **by name**. A tracker nobody has named, or
  one written from scratch, is not on the list.
- The destination check finds hosts **written in the source**. A host built at
  run time, decoded from something, or returned by a server is invisible to it,
  and it does not read pub packages that are not vendored.
- Nothing here observes the app's real traffic yet. Until the runtime smoke test
  exists, "nothing is contacted at startup" is a source review, not a
  measurement.
- F-Droid and Google Play distribute builds they make or re-sign themselves.
  The release checks read the artifacts built by this repository's workflows.
- A check only covers what it reads. Each linked page says exactly what that is.

If you find something these checks miss, please open an issue, or for anything
security-sensitive, follow [SECURITY.md](SECURITY.md).
