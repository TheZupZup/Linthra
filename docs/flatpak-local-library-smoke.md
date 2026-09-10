# Flatpak local-library sandbox smoke

Linthra's Flatpak ships **no filesystem permission at all**: no
`--filesystem=home`, no `--filesystem=host`, no XDG grant
([flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md)). Local music
works because the user hands over one folder and nothing else.

That is a good policy and a fragile one: it only holds if the narrow path
actually works end to end. This smoke proves it does, from inside the installed
sandbox (issue
[#447](https://github.com/TheZupZup/Linthra/issues/447)).

## What it proves

`scripts/flatpak_local_library_smoke.sh` installs the package, then runs
`tool/linux_local_library_smoke.dart` inside it in three modes.

**The folder the user chose works.**

| Assertion | Why it is not obvious |
| --- | --- |
| The folder scans | Without the grant it is not even visible from inside |
| Two tracks imported, one non-audio file skipped | A count that happens to match proves less than a skip that is counted |
| Title, artist, album and track number come from the file's own tags | The filename fallback would produce plausible-looking values from nothing |
| The WAV reports a real duration | Only the container can supply that |
| The MP3's embedded cover is extracted, cached and decodes | Artwork is a separate I/O path from tags, with its own cache |
| The cover is cached **outside** the music folder | A scan must never write into the library it was handed |
| A track plays, with the position actually advancing | A status flag flipping is not playback |

**Nothing else came with it.** Two probes sit beside the music folder in the
host's home directory: a sentinel file and a sibling directory holding a file.
Neither may be visible or readable from inside the sandbox. The harness then
re-checks both **on the host** afterwards, because "invisible" would mean
nothing if the smoke had simply deleted them.

That pair is the sharp end of the policy: granting one folder inside `$HOME`
must not hand over the rest of `$HOME`.

**A restart keeps working.** The scan runs again in a fresh process, because
the library has to survive a relaunch while the grant lasts.

**Losing access is recoverable, not destructive.** The last mode runs the same
package against the same folder path with no grant at all, which is what a
revoked portal document, an unplugged drive and a deleted folder all look like
from inside. Linthra must:

- classify it as `LocalScanError.folderUnavailable`, so the user is pointed at
  reselecting the folder rather than at an Android permission screen;
- carry a user-facing message;
- **keep** the tracks it had already indexed for that folder;
- refuse to persist the scan, so an unreadable folder can never be written down
  as "this library is empty now";
- and, when there is no catalog to fall back on, report `retentionUnavailable`
  and still refuse to persist.

## What stands in for the portal, and what does not

The grant is `flatpak run --filesystem=<folder>`: one folder, for the length of
one run, in no persistent override and in nothing the package declares. That is
the *scope* a document-portal selection produces, and everything downstream of
it is the real production path: the same scanner, metadata reader, artwork
cache and playback controller `LibraryController` wires up.

**It is not the chooser dialog.** A portal grant is minted by a person clicking
a button in `xdg-desktop-portal`, and no headless runner can click it. Nor does
it exercise the document portal's `/run/user/<uid>/doc/…` path rewriting.

Those stay a manual pass, and the audit in
[flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md#user-selected-library-check)
is still the checklist to follow before a release. What this smoke removes from
that checklist is everything *after* the click, which is the part that breaks
silently.

`flatpak override --filesystem=…` is never used, by this smoke or by that
manual pass. An override would test the override, not the package.

## The fixture library

Generated into a disposable directory under `$HOME` and deleted on exit:

```text
Fixture Artist/Fixture Album/01 - Opening Tone.wav   RIFF INFO tags, 3s of PCM
Fixture Artist/Fixture Album/02 - Cover Art.mp3      ID3v2.3 + an APIC cover
Fixture Artist/Fixture Album/notes.txt               not audio; must be skipped
```

Two formats because one file cannot answer both questions: a WAV really decodes
(so playback means something) but RIFF INFO has no picture field, while the MP3
carries the embedded cover.

The tag bytes come from `test/core/sources/local/audio_tag_fixtures.dart`, the
same byte-level builders the local-metadata unit tests use, imported rather
than copied, so there is one place to be wrong about a container format. It is
test support and deliberately stays out of `lib/`.

Nothing is committed as a binary, nothing is downloaded, and no credential or
network call is involved at any point.

## Running it

In CI this is a step of the `Sandbox smokes on the packaged app` job in
`.github/workflows/flatpak-build.yml`. It shares the derived manifest and the
build with the [audio smoke](./flatpak-audio-smoke.md); see that document for
why CI builds a manifest derived from the submission manifest, and what the
generator guarantees about it.

Locally:

```sh
python3 scripts/make_flatpak_smoke_manifest.py

cd flatpak
flatpak-builder --user --install-deps-from=flathub --install-deps-only \
  --force-clean flatpak-builder-sandbox-smoke \
  io.github.thezupzup.linthra.sandbox-smoke.yml

flatpak-builder --user --force-clean --disable-cache --disable-rofiles-fuse \
  --repo=repo-sandbox-smoke flatpak-builder-sandbox-smoke \
  io.github.thezupzup.linthra.sandbox-smoke.yml
flatpak build-update-repo repo-sandbox-smoke

bash ../scripts/flatpak_local_library_smoke.sh repo-sandbox-smoke
```

The harness refuses to run when Linthra is already installed, or when any user
or system override already grants filesystem access, since an override would decide
the isolation result before the test started. Everything it creates (the music
folder, the probes, the installed app and its data) is removed on exit.

Every mode is time-bounded (`LINTHRA_FLATPAK_SMOKE_TIMEOUT`, 300s by default)
and hitting the bound fails the run. The Dart side bounds each step it waits
on, but only once Dart is running, and a hung CI job serves no log at all
until it ends.

## Failure output is sanitized

A music folder path is private data. Both the harness and the Dart smoke
rewrite the home directory, the login name, `/home/<name>` paths and
`/run/user/<uid>` out of anything they print, because this output is what
people paste into issues.

## Related

- [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md), the permission
  policy this smoke defends, and the manual portal pass
- [flatpak-audio-smoke.md](./flatpak-audio-smoke.md), the sibling smoke, and
  the derived manifest both share
- [local-music.md](./local-music.md), the feature itself
