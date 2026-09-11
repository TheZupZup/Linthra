# Flathub screenshots

Flathub listings are judged on their screenshots, and `flatpak-builder-lint`
refuses a submission without them: it reports `metainfo-missing-screenshots`,
and once they are referenced it also checks
`appstream-screenshots-not-mirrored-in-ostree`, meaning every URL has to be
reachable at build time so Flathub can mirror it into the OSTree.

Both findings are open against Linthra today, deliberately. This page is what
is needed to close them (issues
[#437](https://github.com/TheZupZup/Linthra/issues/437) and
[#450](https://github.com/TheZupZup/Linthra/issues/450)).

## Why these are not captured in CI

They could be, and it would be the wrong call. A headless runner draws through
software EGL with no GPU, no desktop font configuration and no compositor, so
the captures come out looking like a broken app rather than a real one. A
listing screenshot is the one asset where "technically the shipped UI" is not
good enough.

So these come from a real GNOME or KDE session, on a machine with the Flatpak
installed.

## What to capture

Only features that are actually validated on Linux. The point of #450 is that
the listing must not promise things nobody has run.

| Shot | View | Why it belongs |
| --- | --- | --- |
| 1 (default) | **Library** with a scanned local folder | The one thing the Flatpak is for, and the one covered end to end by the sandbox smokes |
| 2 | **Now Playing** with artwork and the transport | Playback is validated on the packaged libmpv (#446) |
| 3 | **Folders** showing a chosen music folder | Makes the narrow permission model visible: the user picks a folder, nothing else is reachable |
| 4 | **Settings**, output device section | Genuinely desktop-specific, and it shows libmpv enumerated real devices |

Leave out anything server-backed (Jellyfin, Navidrome/Subsonic, Plex) and the
Downloads view. Server playback from the installed Flatpak has not been
validated once, so it must not appear in the listing until it has. Same for
Android-only features.

## Rules for the content on screen

From #437, and they matter:

- **No private information.** No server hostnames or IP addresses, no
  usernames, no tokens, no personal filesystem paths in a visible breadcrumb or
  title bar.
- **Sample library, real files.** Use a folder of music you are happy to show.
  Album and artist names are visible and permanent once published.
- **One window size for the whole set**, so the images do not jump in the
  carousel. `1180x780` is the app's own default (`kDefaultWindowWidth` and
  `kDefaultWindowHeight` in `linux/runner/my_application.cc`), and it is a
  sensible choice: it is what a first-run user actually sees.
- **One theme for the whole set.** Pick light or dark and stay there.
- **No window shadow or desktop wallpaper** around the app if you can avoid it.
  Capture the window itself, not the screen.

Take them at 100% display scale unless you are deliberately showing HiDPI. The
scaling matrix in [hidpi-and-scaling.md](./hidpi-and-scaling.md) covers whether
the UI holds up; screenshots are not the place to prove that.

## Where the files go

Put the PNGs in `docs/screenshots/`, named for what they show:

```
docs/screenshots/library.png
docs/screenshots/now-playing.png
docs/screenshots/folders.png
docs/screenshots/settings-audio-output.png
```

PNG, no alpha channel. Keep them under about 1 MB each; they are committed to
the repository and mirrored by Flathub on every build.

## Referencing them

Add this to `linux/packaging/io.github.thezupzup.linthra.metainfo.xml`, after
`<content_rating/>` and before `<releases>`:

```xml
<screenshots>
  <screenshot type="default">
    <caption>Your music library, scanned from a folder you chose</caption>
    <image>https://raw.githubusercontent.com/TheZupZup/Linthra/v0.2.6/docs/screenshots/library.png</image>
  </screenshot>
  <screenshot>
    <caption>Now playing, with artwork read from the file's own tags</caption>
    <image>https://raw.githubusercontent.com/TheZupZup/Linthra/v0.2.6/docs/screenshots/now-playing.png</image>
  </screenshot>
  <screenshot>
    <caption>Pick the folders Linthra may read. It gets nothing else.</caption>
    <image>https://raw.githubusercontent.com/TheZupZup/Linthra/v0.2.6/docs/screenshots/folders.png</image>
  </screenshot>
  <screenshot>
    <caption>Choose which audio output to play through</caption>
    <image>https://raw.githubusercontent.com/TheZupZup/Linthra/v0.2.6/docs/screenshots/settings-audio-output.png</image>
  </screenshot>
</screenshots>
```

**Pin the URL to a tag, not to a branch.** `raw.githubusercontent.com/.../main/...`
would let a later commit silently change the images behind a published listing.
A tag cannot move, so the listing shows what was reviewed. Bump the tag in
these URLs when the screenshots are refreshed, not otherwise.

Captions are worth writing properly: software centres show them under each
image, and they are the only prose most people read.

## Verifying

```sh
appstreamcli validate --pedantic linux/packaging/io.github.thezupzup.linthra.metainfo.xml
python3 scripts/check_release_metadata_sync.py
```

`appstreamcli` checks the markup. It does not check that the URLs resolve, and
that is the half that fails a submission, so also run the real linter, which is
the authority here:

```sh
python3 scripts/flathub_builder_lint.py appstream <built-repo>
```

CI runs it on every Flatpak build; see
[flathub-builder-lint.md](./flathub-builder-lint.md). The tag has to exist and
the files have to be pushed to it before
`appstream-screenshots-not-mirrored-in-ostree` can pass, so the order is: land
the PNGs, tag the release, then update the URLs.

## Refreshing later

Retake the whole set rather than one image. A carousel where three shots are
from one release and one is from another looks worse than four slightly dated
ones, and the theme and window size will not match.

## Related

- [flathub-builder-lint.md](./flathub-builder-lint.md), the linter that gates this
- [hidpi-and-scaling.md](./hidpi-and-scaling.md), whether the UI holds up at other scales
- [flathub-update-process.md](./flathub-update-process.md), publishing a new version
