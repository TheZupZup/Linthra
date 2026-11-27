# F-Droid: building the Rust core

Linthra's Android builds carry the Rust core (`native/linthra_core`) as
`lib/<abi>/liblinthra_core.so`. The GitHub release workflows install the Rust
pinned in [`.rust-version`](../../../.rust-version) with the Android targets
(`.github/actions/setup-rust-android`), and
`scripts/check_apk_rust_core.py` fails a build whose APK lacks the library.

F-Droid checks its own build of each release against the signed APK, byte for
byte. So its recipe has to build the Rust core too, with the same rustc, or
the two APKs differ and F-Droid stops taking updates. That recipe lives in
[fdroiddata](https://gitlab.com/fdroid/fdroiddata), not in this repository;
this page is the change to make there, and `metadata/` holds a mirror of it.

## When

Now: every release since `.rust-version` landed (#969) ships the Rust core,
and an F-Droid build without Rust can't match it.

## The change, per build block

The mirror in [`metadata/io.github.thezupzup.linthra.yml`](../../../metadata/io.github.thezupzup.linthra.yml)
carries it in its last three `Builds` entries, the ones fdroiddata's update
bot copies for each new version. Per entry:

```yaml
    srclibs:
      - flutter@stable
      - rustup@1.29.3
    ndk: 28.2.13676358
    prebuild:
      # after the Flutter checkout, before `flutter pub get`
      - rustVersion=$(cat .rust-version)
      - '[[ $rustVersion ]]'
      - $$rustup$$/rustup-init.sh -y --profile minimal --default-toolchain $rustVersion
        --target aarch64-linux-android
      - 'printf ''\nhooks:\n  user_defines:\n    linthra:\n      require_rust: true\n'' >> pubspec.yaml'
    build:
      # inside $repo, around `flutter build apk`
      - source $HOME/.cargo/env
      - $$flutter$$/bin/flutter build apk ...
      - python3 scripts/check_apk_rust_core.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

| Block | `--target` |
| --- | --- |
| armeabi-v7a | `armv7-linux-androideabi` |
| arm64-v8a | `aarch64-linux-android` |
| x86_64 | `x86_64-linux-android` |

- **rustup** installs the Rust pinned in `.rust-version` with only that
  block's target, as `.github/actions/setup-rust-android` does for the
  release builds.
- **`ndk`** is the NDK the release build links with: `flutter.ndkVersion` of
  the Flutter in `.flutter-version` (3.47.5 ships 28.2.13676358;
  `android/app/build.gradle` uses it). Another NDK links another library, and
  the APKs no longer match. Check it again whenever `.flutter-version`
  changes.
- **`require_rust`** was the hook user-define that made `hook/build.dart`
  fail instead of skipping the Rust core. The hook now requires the core on
  every build, so the define changes nothing; it stays in the recipe for the
  versions built before that.
- **`check_apk_rust_core.py`** looks at the APK itself, the same check the
  release workflows run.

`hook/build.dart` finds cargo on the PATH, links with the NDK's clang and
builds with `--locked`: cargo fetches the crates
`native/linthra_core/Cargo.lock` pins, with their checksums, from crates.io
into `$HOME/.cargo`, outside the source tree, so `scandelete` needs no new
entry. The hook remaps that directory to `/cargo` in the library, so a
different `$HOME` on the build server doesn't change the APK.

## Reproducibility

- **Same rustc.** The recipe reads `.rust-version` from the commit it builds,
  the same file the GitHub workflows read, so the two can't drift apart.
- **Same path.** The recipe already moves the checkout to
  `/home/runner/work/Linthra/Linthra`, the path GitHub Actions builds in. Keep
  it: Rust writes source paths into the library.
- **Check it** with `fdroid build -l io.github.thezupzup.linthra` and compare
  against the signed APK, as in
  [arm64 / x86_64 reproducibility](reproducibility-arm64.md).
