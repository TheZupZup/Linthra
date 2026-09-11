# Verifying a release's artifacts

A green CI run says the *tree* was in the state we think it was. It does not say
the file a user installs was built from that tree. For an ordinary release that
gap is theoretical. For a security maintenance release it is the whole point: the
release exists to put a safeguard on people's phones, so "the safeguard is in the
distributed binary" has to be checked against the binary.

This page is how that check is run, what it is worth, and the record of the
releases it has been run on. The safeguard in question is the Cast security
containment — casting is withheld from shipped builds while a reported security
issue is resolved. See [cast.md](cast.md#temporary-containment); the report
itself stays in the private advisory.

## The check

`scripts/verify_release_containment.py` reads an APK, an AAB, the Linux
tarball, or the Linux `.flatpak` bundle, pulls out every compiled Dart payload
inside it (`libapp.so`, one per ABI on Android), and searches those bytes for:

- **the containment message**, exactly as `CastContainment.userMessage` spells it
  in the checkout the script runs from. It is a compile-time constant reached
  only through the contained production wiring, so it is compiled into the
  snapshot while containment holds and folded away when it does not;
- **`UnavailableCastService`**, the service the contained wiring binds; and
- **the absence** of `DefaultCastService`, `ChromecastCastTransport`, and the
  Cast protocol namespaces the live transport talks. Nothing constructs them
  while containment holds, so tree shaking drops them.

A `.flatpak` is an OSTree static delta rather than an archive, so the payloads
are read by unpacking the bundle with the extractor in
`scripts/flatpak_bundle.py` — one way of opening a bundle, shared with the
packaging checks. It needs `flatpak` and `ostree` on the machine running it,
installs nothing, and touches no Flatpak installation; a missing tool is an
error, not a skipped check.

It prints each artifact's SHA-256, and `--json` writes the same record to a file.

Run it on a published release like this:

```sh
gh release download v0.2.6 --repo TheZupZup/Linthra --dir /tmp/linthra-v0.2.6
python3 scripts/verify_release_containment.py \
  --json /tmp/linthra-v0.2.6/containment.json \
  /tmp/linthra-v0.2.6/*.apk /tmp/linthra-v0.2.6/*.aab /tmp/linthra-v0.2.6/*.tar.gz
```

From `v0.2.7` on a Release also carries a `.flatpak` bundle; add
`/tmp/linthra-<tag>/*.flatpak` to that command to check it too.

Run it from a checkout of the commit the release was built from: the expected
message is read from that checkout's `cast_containment.dart`, so checking an old
release from today's `main` compares against today's copy.

### What it proves, and what it does not

It is a byte search over a compiled snapshot. What a green run really says is
"this artifact was built from a tree whose containment constants were still
reachable, and it carries none of the live-cast strings we know to look for". It
cannot see a bypass that leaves every string in place, anything outside the Dart
snapshot (platform channels, native libraries, a plugin's own Java/Kotlin), or
whether an absent string is absent because the code is gone or because this build
stored it differently.

The behavioural evidence is still the test suite —
`test/app/production_cast_containment_test.dart` drives the real production
wiring per platform, and `test/core/services/cast/cast_containment_test.dart`
calls the transport directly — at the commit the artifact is built from. What
this script adds is the one thing those cannot give: it looks at the file that is
actually distributed, so a release built from some other tree, or an artifact
swapped after the fact, does not pass quietly.

It fails closed. An artifact with no readable Dart payload, an unknown file type,
an unreadable archive, or a message it cannot parse out of the Dart source all
exit non-zero rather than reporting a pass.

## Where it runs

| When | Where | What it checks |
| --- | --- | --- |
| Every PR and push | `ci.yml` ▸ *Cast containment markers* | The verifier's own unit tests (`test/tooling/verify_release_containment_test.py`), on synthetic artifacts, so a change that stops it catching an uncontained build is caught here. |
| Every release build | `android-release-build.yml` ▸ *Verify the built artifacts carry the Cast containment* | The APK/AAB in `dist/`, before they are uploaded anywhere. |
| Every Linux release build | `linux-desktop-build.yml` ▸ *Verify the archive carries the Cast containment* | The `.tar.gz`, before it is attached to the Release — the Release is already public by then, so an artifact that fails the check must never become downloadable from it. |
| Every Flatpak release build | `flatpak-build.yml` ▸ *Verify the bundle carries the Cast containment* | The `.flatpak` bundle, before it is attached to the Release, for the same reason. The bundle is also checked against its own manifest first (`scripts/flatpak_bundle.py verify`) — see [release-process.md §4b](./release-process.md#4b-linux-flatpak-bundle-dispatched-alongside-the-android-and-linux-builds). |

All three release builds check out the tag they are building, so the script
itself comes from a second, script-only checkout of the revision the workflow is
running from, and `--containment-source` points it at the *built* tree's
`cast_containment.dart`. That way rebuilding an existing release is still
verified, against that release's own message, even though its tree predates the
verifier. The one case with nothing to check is a tag from before the
containment existed at all: there the step says so and continues, because those
artifacts never carried a message to look for.
| Stable publication | `publish-stable-release.yml` ▸ *Verify the published artifacts carry the Cast containment* | The assets downloaded back from the published GitHub Release, with every SHA-256 written into the job summary. |

The source-level tripwire (`scripts/check_cast_containment.py`, also in `ci.yml`)
is unchanged and still the first line: it greps the tree for the markers of the
three containment layers. This is its artifact-level twin, not its replacement.

## Record: `v0.2.6` (security maintenance release)

The containment landed in `fix(cast): disable casting in production pending a
security fix (#572, #573)` (PR #577) and shipped in `v0.2.6`, which also carried
the Linux and Android work already on `main`. No feature work was added to the
release for its own sake.

| Field | Value |
| --- | --- |
| Tag | `v0.2.6` |
| Commit | `f1d61f982b87665a95a447b47b49aa7fbf8aa046` |
| Version | `0.2.6+206999` (`pubspec.yaml`, mirrored by `AppInfo._devVersionName`) |
| Published | 2026-09-08 |
| Release notes | [docs/release-notes/v0.2.6.md](release-notes/v0.2.6.md) |

Every published asset was downloaded from the Release and verified with the
script above. Digests are of the assets as published:

| Asset | Bytes | SHA-256 |
| --- | --- | --- |
| `linthra-v0.2.6-release-signed.apk` | 69433151 | `3926bc77dc48a9ade7ed8d23c0f51c6072ae6c71e2a10baec3195a92667cfc6d` |
| `linthra-v0.2.6-release-signed.aab` | 66113660 | `97616d6b49fd43b2a856773ce496f24c4c461f37c8dc6dcd4dc7a98fe9ea707d` |
| `linthra-v0.2.6-arm64-v8a-release-signed.apk` | 24680721 | `a842079d61a4762c8cf02ea9f25005d11c562c3c7cfc074ebdf56e4fc4487c6a` |
| `linthra-v0.2.6-armeabi-v7a-release-signed.apk` | 22549117 | `8b7646b879a802bbab40ce3effd044c149e8b1a973aff73da3ba707d25f325e5` |
| `linthra-v0.2.6-x86_64-release-signed.apk` | 26244309 | `b8e80a7761952ea6d450e814c1940b187b288907ff6306ea4797ba799f3a6015` |
| `Linthra-v0.2.6-linux-x64.tar.gz` | 13243680 | `bd27149460c17effb7cc94182a9fe7f4cbdcac7335231c1f20e891ee15571f50` |

Payloads checked: `lib/{arm64-v8a,armeabi-v7a,x86_64}/libapp.so` in the universal
APK, the matching single payload in each per-ABI APK, `base/lib/<abi>/libapp.so`
in the AAB, and `Linthra-v0.2.6-linux-x64/lib/libapp.so` in the Linux bundle.
Every one carries the containment message and `UnavailableCastService`, and none
carries a live-cast marker.

### Distribution channels

| Channel | State |
| --- | --- |
| GitHub Release | Published, assets verified above. |
| F-Droid | F-Droid builds `v0.2.6` from source on its own infrastructure and signs with its own key, picked up automatically (`UpdateCheckMode: Tags` + `AutoUpdateMode: Version`; `metadata/io.github.thezupzup.linthra.yml` names `0.2.6` / `2069993`). It is on F-Droid's build cycle, not ours, so confirm the published version on f-droid.org rather than assuming the tag is enough. An F-Droid APK is built from the same tagged source as the verified GitHub asset, but is a different binary — verify it there by version, not by the digests above. |
| Google Play (closed testing) | Only ever receives the release-signed AAB from a tagged build, and only a non-production track (`google-play-publishing.md`). |

The user-facing message, the disclosure timing, and any credential-rotation
guidance are coordinated in the private advisory. Nothing in this repository
claims that exploitation or credential theft occurred; there is no evidence of
either, and saying otherwise without it would be its own harm.

## When containment is lifted

The reviewed restoration ([#575](https://github.com/TheZupZup/Linthra/issues/575))
changes `CastContainment`, the production wiring, the transport guards and
`scripts/check_cast_containment.py` in one pull request. It must update this
verifier too — its markers describe a contained build, so after restoration they
describe nothing. That edit is one of the signals a reviewer should look for, the
same way the tripwire's is. Until then, an artifact that does not verify is not
published.
