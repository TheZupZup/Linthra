# Flatpak source pinning

Issue: #443  
Parent: #376

Every external input to Linthra's Flatpak build resolves from an immutable
reference: a full Git commit, or a URL plus the SHA-256 of the bytes that URL
has to return. Rebuilding the same repository commit therefore fetches the same
inputs, and a change to any of them is a diff somebody reviewed.

This page is the "how and where" of those pins. The complementary audit,
[flatpak-offline-build.md](./flatpak-offline-build.md) (#442), covers the other
half: that each declared source is staged exactly where the sandboxed build
reads it, so the build needs no network of its own.

## Sources of truth

Only four files decide what the build fetches. Everything under
`flatpak/generated/` is derived from them and is never hand-edited.

| File | Decides |
| --- | --- |
| [`.flutter-version`](../.flutter-version) | The Flutter SDK tag, for the Flatpak and for every other build |
| [`pubspec.lock`](../pubspec.lock) | Every Dart package version and its SHA-256 |
| [`flatpak/flatpak-flutter.yml`](../flatpak/flatpak-flutter.yml) | The native chain (ffmpeg, libplacebo, libass, mpv), the runtime, the sandbox, the Flutter source |
| [`scripts/regenerate_flatpak_sources.sh`](../scripts/regenerate_flatpak_sources.sh) | Which `flatpak-flutter` produced the generated files (`TOOL_COMMIT`) |

And the derived files, all committed so a reviewer can read them:

| File | Generated from |
| --- | --- |
| `flatpak/io.github.thezupzup.linthra.yml` | the template, with the app module rewritten for an offline build |
| `flatpak/generated/modules/flutter-sdk-<version>.json` | `.flutter-version`: the Flutter checkout plus every Dart SDK and Linux engine artifact for it |
| `flatpak/generated/sources/pubspec.json` | `pubspec.lock` (and Flutter's own `flutter_tools` lockfile): one pinned pub.dev archive per package |
| `flatpak/generated/patches/` | the per-plugin fixes flatpak-flutter keeps for the locked plugin versions |

## What pins what

| Input | Pinned by | Notes |
| --- | --- | --- |
| Flutter SDK | `tag` **and** `commit` | The tag is what flatpak-flutter reads; the commit is what makes the checkout immutable. Both manifests and `.flutter-version` have to agree |
| Dart packages | pub.dev archive URL + SHA-256 | Taken from `pubspec.lock`, with a matching `hosted-hashes` entry so `pub get --offline` validates the cache |
| Flutter engine artifacts | `storage.googleapis.com` URL + SHA-256 | The engine hash is part of the URL, and every artifact in a module must carry the same one |
| Native archives (ffmpeg, libplacebo, jinja, markupsafe, glad, libass, mpv) | archive URL + SHA-256 | Release tags, never branch snapshots |
| Plugin downloads (SQLite amalgamation, mimalloc) | URL + SHA-256, pre-fetched into the path the plugin's CMake reads | The committed CMake patch adds the matching `URL_HASH`, so the build cannot accept different bytes even if it did reach the network |
| The app itself | the repository commit being built | A `type: dir` source, see below |
| `flatpak-flutter` | `TOOL_COMMIT`, a full commit | The generator decides every hash above, so which generator ran is part of the record |

A note on GitHub's generated tag tarballs (`/archive/refs/tags/…`): the SHA-256
is the pin, not the URL. GitHub has changed how it compresses those archives
before, and if that happens again the fetch fails on a hash mismatch rather
than quietly building different code. The fix is then a deliberate re-pin (or a
switch to an upstream release tarball for that module), reviewed like any other
source change.

## Inputs that cannot be pinned

Four inputs are not content-addressed, and cannot be. Each is listed here
because `scripts/check_flatpak_sources.py` compares this table against the
manifest in both directions: an input that stops being content-addressed
without a row fails, and a row for an input that is gone fails too.

| Input | Why an immutable pin is impossible | What bounds the risk |
| --- | --- | --- |
| `runtime:org.gnome.Platform` | A Flatpak runtime is a signed OSTree ref, resolved by branch at build and install time. `flatpak-builder` accepts a `runtime-commit`, but Flathub's build service updates runtimes in place precisely so published apps pick up platform security fixes; freezing one would keep Linthra on an unpatched GNOME/freedesktop stack | The branch is an exact released version, not a channel: no `master`, `stable` or `beta`. `scripts/check_flatpak_sources.py` rejects a non-numeric branch, and both manifests must name the same one. Contents are signed by the remote and verified by Flatpak |
| `sdk:org.gnome.Sdk` | The same OSTree ref reasoning, for the build-time half | Same branch pin, same check. It affects the build only: the compiler and headers, not what ships |
| `sdk-extension:org.freedesktop.Sdk.Extension.llvm20` | An SDK extension follows its SDK's branch, and has no per-commit form in a manifest | The LLVM major version is part of the extension name, so a compiler bump is a visible manifest change rather than a silent one, and it must match in both manifests |
| `dir:..` | The app's own checkout, staged by path rather than downloaded. A digest of it would be a digest of the tree that Git already names | It is the commit being built: `git` is the content pin. The offline build smoke additionally refuses to stage a host `build/`, `.dart_tool/` or `.pub-cache/` tree, so a developer's untracked artifacts cannot enter the build |

## Refreshing the pins

Regeneration is a normal, reviewable diff. Nothing here is automated into a
merge. The updater bots move `.flutter-version` or `pubspec.lock` and stop
there, and their branch guard
([`scripts/check_dependency_update_files.sh`](../scripts/check_dependency_update_files.sh))
keeps the derived pins off the bot's branch, so refreshing them is a human's
own PR. That is the same reasoning as everywhere else in
[dependency-updates.md](./dependency-updates.md): a bot moves one pin, a person
reviews what it implies.

```bash
./scripts/regenerate_flatpak_sources.sh
```

The script fetches `flatpak-flutter` at `TOOL_COMMIT` into `.tool/`, resolves
every source from the committed lockfile and Flutter pin, rewrites
`flatpak/io.github.thezupzup.linthra.yml` and `flatpak/generated/`, and then
runs the source check below on its own output. It needs network access, because
resolving a URL and hashing what it returns is the whole job; that is a
maintainer-time step, not build-time networking.

Then read the diff. A pin change you did not expect is the finding, not noise.

| What you changed | Also do |
| --- | --- |
| `.flutter-version` | Regenerate. Update the `commit` on the template's Flutter source to the one the new tag resolves to (`git ls-remote --tags https://github.com/flutter/flutter.git refs/tags/<version>`); the generated module records it too, and the check holds the two together |
| `pubspec.lock` | Regenerate. Expect one archive plus one hosted-hash entry per moved package. A moved plugin with a native download (`sqlite3_flutter_libs`, `media_kit_libs_linux`) also moves a generated patch, which is the case worth reading closely |
| A native module in the template | Regenerate, so the committed manifest matches the template. Verify the new SHA-256 yourself (`curl -L <url> \| sha256sum`) rather than trusting a bump |

## What CI checks

```bash
python3 scripts/check_flatpak_sources.py
python3 test/tooling/check_flatpak_sources_test.py
```

`scripts/check_flatpak_sources.py` runs on every PR, offline, with no Flutter
or Flatpak toolchain. It reads both manifests, every generated module and
source file they include, `pubspec.lock` and `.flutter-version`, and fails on:

- a remote `archive`/`file` source with no SHA-256, or only an MD5/SHA-1;
- a `git` source without a full commit, or tracking a branch;
- a URL that resolves at download time (`HEAD`, `refs/heads/…`, `latest`,
  `?branch=…`, a default-branch snapshot) or that is not HTTPS;
- a source type that carries no content pin (`svn`, `bzr`) or that downloads on
  the user's machine instead of the builder's (`extra-data`);
- a local `patch`/`file`/`dir` path that is absolute, escapes the checkout, or
  does not exist;
- a source type it does not recognise, rather than skipping it;
- the template and the generated manifest disagreeing about the runtime, the
  SDK, the sandbox or any native module;
- `.flutter-version`, the template's Flutter tag and commit, the generated
  module's tag and commit, and that module's filename not all agreeing;
- Flutter engine artifacts from more than one engine in one module;
- a locked Dart package missing from the generated sources, or carrying a
  different version or digest than `pubspec.lock` resolved;
- a generated per-plugin patch applied to a version other than the one it was
  written for, which is how a plugin bump silently reuses the previous
  version's native pins;
- a `FetchContent` URL a patch declares without a `URL_HASH`, or whose
  pre-fetched Flatpak source stages a different digest;
- a `TOOL_COMMIT` that is not a full commit;
- an unpinnable input with no row in the table above, or a row for an input
  that no longer exists.

Two existing checks cover the rest, and are not repeated here:

- `test/tooling/flatpak_offline_build_test.dart` (#442) proves every declared
  source lands where the offline build reads it, and that no module grants
  build-time network access.
- `scripts/flathub_builder_lint.py` (#449) runs Flathub's own linter, which has
  its own opinions about sources on submission.
