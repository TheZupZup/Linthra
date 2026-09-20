# Flatpak network-independent build audit

Issue: #442  
Parent: #376

Linthra's Flatpak is designed so the **build itself does not need network
access**. Network is used only before the sandboxed build, when
`flatpak-builder` fetches sources that are already declared in the manifest and
content-addressed where the source type supports it.

This distinction matters:

- **source-fetch phase:** network is allowed so `flatpak-builder` can download
  the exact URLs declared by the manifest;
- **build phase:** no undeclared download is permitted. Dart packages, Flutter
  artifacts, native archives and plugin inputs must already be present.

## Sources of truth

The hand-authored input is `flatpak/flatpak-flutter.yml`. The file actually
consumed by `flatpak-builder` is the generated
`flatpak/io.github.thezupzup.linthra.yml`.

`pubspec.lock` remains authoritative for Dart package versions. Running:

```bash
./scripts/regenerate_flatpak_sources.sh
```

uses the pinned `flatpak-flutter` generator to turn that lockfile and the
project's pinned Flutter version into committed source declarations under
`flatpak/generated/`.

The generator itself needs network access because its job is to discover and
record upstream archive URLs and hashes. That is a maintainer-time generation
step, not Flatpak build-time networking.

What each of those declarations is pinned by, how to refresh one, and which
inputs cannot be content-addressed at all is
[flatpak-source-pinning.md](./flatpak-source-pinning.md) (#443). This page is
about the other half: that what is declared is enough to build offline.

## Dart / Flutter

`flatpak/generated/sources/pubspec.json` contains one versioned pub.dev archive
for every hosted package in `pubspec.lock`, with a SHA-256 and a destination
inside the build's private `.pub-cache`. Matching hosted-hash entries are also
pre-created, as inline sources under `.pub-cache/hosted-hashes/pub.dev`: that is
where `flutter pub get --offline` reads them to validate a cached package, so a
correct hash staged anywhere else is dead weight. Remote `type: file` inputs, including native plugin inputs such as
SQLite and mimalloc, are required to carry their own SHA-256 as well.

The SDK module itself checks Flutter out from Git rather than from a hashed
archive, so the guard requires that source to carry a full `commit`, not just
the `tag` matching `.flutter-version`. A tag can be repointed upstream, which
would let the fetch phase pull different code and the build phase reuse it
without anything noticing.

The generated Flutter SDK module provides `setup-flutter.sh`, whose dependency
resolution command is:

```text
flutter pub get --offline
```

The generated application module then builds with:

```text
flutter build linux --release --no-pub
```

So neither dependency resolution nor the Flutter build can silently refresh a
package from pub.dev during the Flatpak build.

The authoritative template still says `flutter pub get --enforce-lockfile`;
the generator converts that into the offline setup step while preserving the
committed lockfile as the dependency set.

## Native sources

The generated manifest declares the native runtime chain explicitly. Current
modules include FFmpeg, libplacebo and its build helpers, libass, and mpv. Each
remote archive/file source that supports content hashing carries a SHA-256.
Generated Flutter SDK archives are checked by the same rule.

Two Flutter plugins deserve special attention because their upstream Linux
builds can otherwise fetch native code from CMake:

### sqlite3_flutter_libs

The plugin normally obtains the SQLite amalgamation with `FetchContent`.
Linthra's `linux/CMakeLists.txt` provides `LINTHRA_SQLITE3_SOURCE_DIR` and sets
`FETCHCONTENT_SOURCE_DIR_SQLITE3` before generated plugin CMake is included.
The Flatpak source generator also predeclares the exact SQLite archive used by
the locked plugin version.

Predeclaring it is only half the job: the archive has to land where
`FetchContent` looks for it, or an uncached download-disabled build still tries
to reach sqlite.org. That location is CMake's own download directory for the
declaration, under the Flutter release build directory:

```text
./build/linux/<arch>/release/_deps/sqlite3-subbuild/sqlite3-populate-prefix/src
```

The regression guard reads the archive URL and SHA-256 out of the committed
`sqlite3_flutter_libs` CMake patch (the input the locked plugin actually
builds against), then requires a generated source with that exact URL and hash
staged at that path for **every** architecture the *Flutter SDK module*
declares, currently `x86_64` and `aarch64`. That list deliberately comes from
the SDK module rather than from the native inputs being audited: derived from
the inputs themselves it would shrink whenever both architectures' entries
disappeared together, passing over the very gap it exists to catch. A
regenerated source set that keeps the hashed archive but moves, drops or
single-architectures its destination fails CI instead of failing much later
inside a sandboxed build.

### media_kit_libs_linux

The plugin can optionally fetch/build mimalloc. Linthra does not require that
allocator and forces:

```cmake
MIMALLOC_USE_STATIC_LIBS OFF
```

before generated plugin CMake is included. The generated source set also
contains the plugin's pinned mimalloc input, so a generator/plugin change cannot
quietly depend on a warm developer cache. Its destination is held to the same
per-architecture rule as SQLite's, against the release build directory the
plugin would download into.

## Automatic regression guard

`test/tooling/flatpak_offline_build_test.dart` runs with the normal Flutter test
suite. It checks that:

- the template keeps lockfile enforcement and a `--no-pub` build;
- the generated build uses the offline setup script;
- a network grant appears only in the top-level runtime `finish-args`, never in
  build options for the app or a generated module, in either the joined
  (`--share=network`) or the split (`--share`, then `network`) form that
  Flatpak's GLib option parser accepts;
- the generated files it audits are the ones the `linthra` module actually
  includes, so an orphaned generated file cannot pass for a staged one;
- every hosted package/version in `pubspec.lock` has a generated pub-cache
  archive, and an inline hosted-hash entry under
  `.pub-cache/hosted-hashes/pub.dev` where `pub get --offline` reads it;
- every remote archive/file source it audits has its **own** valid SHA-256,
  including generated Flutter SDK, SQLite and mimalloc inputs;
- every remote `git` source pins a full commit, not just a tag or branch;
- a later source's hash cannot accidentally satisfy an earlier source mapping,
  a mapping is recognised whatever order its keys appear in, and a trailing
  comment cannot hide a key's value;
- the SQLite pre-fetch seam and mimalloc-disable switch remain in CMake, and
  both native archives are staged at the per-architecture paths those builds
  actually read;
- the end-to-end smoke keeps `--download-only`, `--disable-cache` and
  `--disable-download` together, and still refuses to stage a host `build/`,
  `.dart_tool/` or `.pub-cache/` tree before it fetches anything.

### It fails closed on YAML it cannot read

flatpak-flutter emits the manifest in block style, and the checks above read it
that way. YAML can express the same data in flow style (`{a: b}`, `[a, b]`) or
through anchors and aliases, which those line-oriented checks would walk past
without noticing, turning a guard into a silent no-op.

So the guard treats any of those forms as a failure in itself rather than
something to skip, and says so with the offending line. A future manifest that
legitimately needs one of them should teach the guard that form first; until
then, an unreadable manifest fails instead of passing.

This is intentionally a structural CI guard. The end-to-end proof is the build
smoke below.

## End-to-end offline build smoke

Install the Flatpak build prerequisites from `docs/flatpak-development.md`, then
run from the repository root:

```bash
bash scripts/flatpak_offline_build_smoke.sh
```

The script performs two separate `flatpak-builder` invocations against the
**generated** manifest:

1. `--download-only` fetches the manifest-declared sources into
   flatpak-builder's source cache and exits;
2. the output build directory is discarded, then every module is rebuilt with
   both `--disable-cache` and `--disable-download`.

`--disable-cache` is important: it prevents a previous successful module build
from satisfying phase 2 without executing that module's build commands again.
It does **not** delete the downloaded source objects populated by phase 1.
`--disable-download` then requires those already-declared sources to be enough
for the full uncached rebuild.

The second phase therefore cannot ask flatpak-builder to retrieve a missing
source and cannot hide behind a warm module cache. The structural guard also
rejects a build-time network grant, so a hidden `pub get`, CMake
`FetchContent`, curl/wget, or similar undeclared fetch cannot borrow Linthra's
runtime network permission. Flatpak parses its options with GLib, which takes a
value either joined or as the following argument, so the guard rejects
`--share=network` and an adjacent `--share` / `network` pair alike.

A failure in phase 2 is useful: it means something required by the build was not
properly declared/prefetched, which is exactly what #442 is meant to catch.

### The staged source tree has to be clean

The app module's source is `type: dir, path: ..` with no skip list, so
`flatpak-builder` stages the whole checkout, including directories git ignores.
A host `build/` tree from a local `flutter build linux` carries CMake's
already-downloaded `FetchContent` archives and possibly a finished bundle, and a
repo-root `.pub-cache` carries packages pub could resolve from.

Those reach the sandbox as **source**, so neither `--disable-cache` (which only
stops module build results being restored) nor `--disable-download` (which only
stops declared sources being fetched) keeps them out. Phase 2 could then pass
with an undeclared dependency quietly satisfied from the host.

The script refuses to start when `build/`, `.dart_tool/` or `.pub-cache/` exist
at the repository root, and prints the exact `rm -rf` to clear them. It does not
delete anything itself. Remove them (or run from a fresh clone) and re-run.

The smoke deliberately keeps the normal `.flatpak-builder` **source cache**
between the two phases. That is not a developer pub cache or a module build
result: it is flatpak-builder's own source store populated from the manifest
during phase 1. The app module's `PUB_CACHE` points into
`/run/build/linthra/.pub-cache`, populated by declared sources for that build.

## Clean-machine validation

For the strongest local validation, start without Linthra's previous Flatpak
build state:

```bash
rm -rf build .dart_tool .pub-cache
rm -rf flatpak/.flatpak-builder flatpak/flatpak-builder-offline-smoke
bash scripts/flatpak_offline_build_smoke.sh
```

Deleting `.flatpak-builder` is intentionally expensive: the first phase must
redownload and the second must rebuild the entire FFmpeg/libplacebo/libass/mpv
chain. Do it for release/Flathub readiness testing, not for every edit.

Do **not** copy a host `~/.pub-cache` into the build tree. A successful smoke
must come only from the generated source declarations.

## Updating dependencies

When `pubspec.lock` or `.flutter-version` changes:

1. run `./scripts/regenerate_flatpak_sources.sh`;
2. review changes to the generated manifest and `flatpak/generated/`;
3. run normal CI/tests, including `flatpak_offline_build_test.dart`;
4. run `bash scripts/flatpak_offline_build_smoke.sh` when Flatpak is available;
5. for release/submission readiness, repeat once from a deleted
   `.flatpak-builder` cache.

Do not hand-edit generated source lists to make an offline failure disappear.
Fix the authoritative dependency/source input or the generation rule, then
regenerate so the result stays reviewable and reproducible.
