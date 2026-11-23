# Distribution

How Linthra gets from a tagged commit to people's devices: building and
signing releases, and publishing them on each store.

## Releases

| Document | What it covers |
| --- | --- |
| [Release process](release-process.md) | Versioning, tagging and GitHub Releases, step by step |
| [Release signing](release-signing.md) | The Android signing key and how CI uses it |
| [Verifying a release's artifacts](release-artifact-verification.md) | Checking that published files are the ones CI built |
| [Store listing assets](listing-assets.md) | Icons, feature graphic and screenshots for the stores |
| [Reddit release announcements](reddit-release-announcements.md) | The automated release post |

## Google Play

| Document | What it covers |
| --- | --- |
| [Publishing](google-play/publishing.md) | How builds reach the closed-testing track |
| [Readiness checklist](google-play/readiness.md) | What has to be true before a production release |
| [Store listing](google-play/listing.md) | The listing text, keywords and screenshot order |
| [Data Safety](google-play/data-safety.md) | Answers for the Data Safety form |
| [Review notes](google-play/review-notes.md) | What reviewers need to access the app |

## F-Droid

| Document | What it covers |
| --- | --- |
| [Readiness checklist](f-droid/readiness.md) | F-Droid's requirements and where Linthra stands |
| [Build recipe](f-droid/build-recipe.md) | The metadata recipe and reproducible-build notes |
| [Submission package](f-droid/submission.md) | What goes into the fdroiddata merge request |
| [arm64 / x86_64 reproducibility](f-droid/reproducibility-arm64.md) | Per-ABI reproducibility and the F-Droid-signed fallback |

## Flatpak and Flathub

| Document | What it covers |
| --- | --- |
| [Development on Fedora Atomic](flatpak/development.md) | Building, installing and running the Flatpak locally |
| [CI validation](flatpak/ci.md) | What the Flatpak build job proves, and reproducing it |
| [Network-independent build](flatpak/offline-build.md) | Why the sandboxed build needs no network |
| [Source pinning](flatpak/source-pinning.md) | How every build input is pinned, and refreshing them |
| [Audio playback smoke](flatpak/audio-smoke.md) | Checking real playback inside the sandbox |
| [Local-library sandbox smoke](flatpak/local-library-smoke.md) | Checking folder access inside the sandbox |
| [Flathub update process](flatpak/flathub-update-process.md) | From an upstream release to a Flathub update |
| [Flathub builder lint](flatpak/flathub-builder-lint.md) | Running Flathub's linter and its exceptions |
| [Flathub screenshots](flatpak/flathub-screenshots.md) | Sizes, naming and the metainfo block |
