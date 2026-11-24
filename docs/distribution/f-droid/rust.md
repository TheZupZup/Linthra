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
this page is the change to make there.

## When

Before, or together with, the first release whose APKs carry the Rust core:
the first tag cut after `.rust-version` landed (#969). An F-Droid build of
that release without Rust no longer matches it.

## The change, per build block

In `metadata/io.github.thezupzup.linthra.yml`, for each `Builds` entry.

Add the rustup srclib next to Flutter. Use the tag fdroiddata's
`srclibs/rustup.yml` carries:

```yaml
    srclibs:
      - flutter@stable
      - rustup@<tag>
```

In `prebuild`, inside the repository and before `flutter pub get`, install the
pinned Rust with that block's target only:

```yaml
      - rustVersion=$(cat .rust-version)
      - '[[ $rustVersion ]]'
      - $$rustup$$/rustup-init.sh -y --profile minimal --default-toolchain $rustVersion
          --target aarch64-linux-android
      - source $HOME/.cargo/env
```

| Block | `--target` |
| --- | --- |
| armeabi-v7a | `armv7-linux-androideabi` |
| arm64-v8a | `aarch64-linux-android` |
| x86_64 | `x86_64-linux-android` |

In `build`, before `flutter build apk`, put cargo back on the PATH, since each
step starts a new shell:

```yaml
      - source $HOME/.cargo/env
```

Nothing else changes. `hook/build.dart` finds cargo on the PATH, links with
the NDK's clang and builds with `--offline --locked`. The crate has no
dependencies, so there is nothing to vendor and `scandelete` needs no new
entry.

## Reproducibility

- **Same rustc.** The recipe reads `.rust-version` from the commit it builds,
  the same file the GitHub workflows read, so the two can't drift apart.
- **Same path.** The recipe already moves the checkout to
  `/home/runner/work/Linthra/Linthra`, the path GitHub Actions builds in. Keep
  it: Rust writes source paths into the library.
- **Check it** with `fdroid build -l io.github.thezupzup.linthra` and compare
  against the signed APK, as in
  [arm64 / x86_64 reproducibility](reproducibility-arm64.md).

## After

Once F-Droid builds with Rust, every shipped build carries the Rust core, and
the Dart copies of the rules (the fallbacks in `lib/core/`) can go.
