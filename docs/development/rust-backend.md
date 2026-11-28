# Moving the backend to Rust

The goal: Dart and Flutter keep the UI, the Riverpod wiring and the platform plugins; everything else that Linthra decides, fetches, stores or parses runs in `native/linthra_core`.

This page is the plan and the rules for getting there. It changes as phases land.

## What moves, and what cannot

Moves to Rust, in this order:

1. **Local scan, end to end.** Walking the music folders, stat, CUE sheets, tags (already Rust), mapping to tracks, reconciling moves (already Rust). Android's MediaStore and SAF listings stay in Kotlin and are handed to Rust as input.
2. **Subsonic / Navidrome client.** HTTP, auth, paging, JSON. The template for the other servers.
3. **Jellyfin, Plex, Audiobookshelf clients.**
4. **Sync** of favourites and playlists.
5. **Downloads and cache**: `.part` files, resume, limits, Clear all.
6. **Database**: drift to rusqlite, with a migration that keeps every user's library. Last, because it is the riskiest for user data.
7. **Linux MPRIS and notifications** over D-Bus.

Stays in Dart or Kotlin, because the platform owns it:

- the audio engines: ExoPlayer on Android (through just_audio and audio_service, which also own the media session and Android Auto) and libmpv on Linux. The controller logic around them moves; the engines don't.
- Android SAF and MediaStore, secure token storage, the file picker, permissions, URL launching.

## Rules for every phase

- **The Rust core is required.** The hook fails a build without it and the app checks it at startup, so a rule lives in Rust only: no Dart copy is kept as a fallback.
- **Parity first.** A port is written against the Dart rules it replaces: the existing Dart tests run through Rust, and a test compares both on generated input. Before the Dart copy is deleted (in the same PR or the next), what it answered is recorded as fixed cases under `test/fixtures/`, so the Rust rule stays held to it. A change of behaviour is its own PR with its own reason, never a side effect of the port.
- **A panic has a Rust answer.** Every rule's entry point runs it through `fail_safe` (`src/ffi.rs`): a rule that panics gets a simple safe answer written in Rust (keep the order, refuse the input, do nothing), and the app goes on. Dart throws only when that panicked too.
- **Break it on purpose.** Each parity and fixed-case test is checked by mutating the Rust rule and watching the test fail.
- **CI's Rust.** Checks run on the toolchain pinned in `.rust-version`, not whatever is installed locally.

## Crates and the bridge

`linthra_core` was dependency-free. A backend that talks to servers and a database cannot stay that way, so it takes crates, under these conditions:

- Versions are pinned by `Cargo.lock` and every build uses `--locked`.
- Licences are checked against AGPL-3.0 and listed in `docs/audits/dependency-licenses.md`.
- **Offline builds keep working.** The Flatpak builds with the network off, so crate sources are listed for flatpak-builder (a generated `cargo-sources.json`, checked against `Cargo.lock` in CI). F-Droid builds from source and fetches them before the build.
- **TLS trusts the system.** A self-hosted server behind a private CA that the user installed on Android must keep working, so the HTTP client verifies with the platform's trust store, not a bundled root list. This is tested before any server client switches.
- Network destinations stay the ones `docs/audits/network-destinations.md` lists; moving a request to Rust changes who sends it, not where it goes.

Dart talks to the async parts through `flutter_rust_bridge` (generated async calls and streams). The synchronous calls that exist today keep their hand-written C ABI until a phase replaces them.

## Phase 0: the groundwork

Before the first phase moves:

- crate fetching in `hook/build.dart`, CI, the Flatpak (generated sources) and the F-Droid recipe;
- `flutter_rust_bridge` wired to the library the hook already builds, on Linux, Android and in `flutter test`;
- one small async call and one stream through it, with tests, to prove the path end to end.

## Progress

- Phase 0 landed in #991.
- Phase 1, the local scan, lands in steps. First the folder walk: `NativeAudioFileScanner` runs it in Rust and is the filesystem scanner `PlatformAudioFileScanner` uses. Then what the scan reads about each file: `NativeLocalFileStatReader` stamps every listed file in one call (a call per file costs more than the `stat`), decides whether a file it could not read is gone, and CUE sheets are read in Rust. Then mapping files to tracks: `LocalTrackMapper` names every track in Rust, files, Android documents and CUE tracks alike. Then the incremental scan's decisions: whether a file's indexed row is reused without reading it, and which row a read file gets (`src/scan/incremental.rs`, called per file by `LocalMusicSource._scanFiles`). What is left in Dart is the sequence around them, through the injected seams the scan's tests drive; it can move now that the fault tests no longer need `dart:io` underneath.
- Phase 2, the Subsonic client, lands in steps too. First what a server answers: the `subsonic-response` envelope, and the artists, albums, songs, playlists, favourites, OpenSubsonic extensions, lyrics and folders read out of it, all in Rust (`src/subsonic/`, through `subsonic_reply.dart`), with a JSON reader that reads as `jsonDecode` did. The requests still go out from Dart, through the platform's HTTP stack and trust store, until TLS through the system's trust store is proven in Rust.
- The Dart copies of every rule already in Rust were removed once the core became required, their answers kept as fixed cases. The `dart:io` folder walk and file stats went last: the scan's fault tests stage a pulled drive, a dead share and a move mid-walk around the Rust reads instead of through `IOOverrides`, and the Rust tests cover the stalls and failures a real disk can't stage.
