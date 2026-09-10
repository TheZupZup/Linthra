# HiDPI and fractional scaling

Issue: [#457](https://github.com/TheZupZup/Linthra/issues/457)

Linux desktops scale in two independent ways, and they do different things to a
layout. Almost every "it looks broken at 150%" report is really one of these
two, so it is worth being precise about which:

**Display scaling** raises the device pixel ratio, which *shrinks* the logical
size of the same physical window. A 1920×1080 monitor at 150% hands the app
1280×720 logical pixels. Nothing gets relatively bigger, there is simply less
room, so a window that was `expanded` at 100% can be `medium` at 150% and
`compact` at 200%. This is what changes which layout you get.

**Text scaling** (GNOME's `text-scaling-factor`, KDE's "Force font DPI") leaves
the logical size alone and makes every glyph bigger inside it. This is what
overflows rows and clips buttons.

Real desktops combine them: GNOME's fractional scaling on X11 is implemented
partly through text scaling, KDE lets you set both independently, and a user on
a HiDPI laptop plus an external 1080p monitor gets different numbers per screen.

## What is automated

`test/app/hidpi_scaling_test.dart` pumps the Library, Album detail, Artist
detail and Now Playing screens across a matrix of both axes:

| Display | Device pixel ratio | Logical size |
| --- | --- | --- |
| 1080p at 100% | 1.0 | 1920×1080 |
| 1080p at 125% | 1.25 | 1536×864 |
| 1080p at 150% | 1.5 | 1280×720 |
| 1080p at 175% | 1.75 | 1097×617 |
| 4K at 200% | 2.0 | 1920×1080 |
| 3:2 laptop at 150% | 1.5 | 1504×1003 |
| Ultrawide at 100% | 1.0 | 3440×1440 |
| Ultrawide at 125% | 1.25 | 2752×1152 |
| The runner's minimum window at 200% | 2.0 | 420×600 |

Every one of those is pumped at text scale 1.0, 1.3 (GNOME's Large Text) and
2.0, and each case asserts:

- **no overflow**: any `RenderFlex` overflow or layout exception fails the test
  naming the screen and the scale;
- **primary actions stay legible and tappable**: the Play button's own label is
  never truncated, its height stays at or above `kMinInteractiveDimension`, and
  it is tapped, which hit-tests at its visual centre and so fails if the painted
  control and the box that receives the click have drifted apart;
- **the runner's floor really is a floor**: the minimum window size is read out
  of `linux/runner/my_application.cc` rather than repeated, and every screen is
  rendered at it, at three pixel ratios and three text scales. Display scaling
  only ever makes the logical window smaller, so the floor is the worst case;
- **ultrawide caps rather than stretches**: above `maxPaneLayoutWidth` no
  content column is allowed past `maxContentWidth`, because the failure mode at
  3440 px is not overflow, it is a track row with its title and its duration a
  screen apart.

`test/shared/widgets/artwork_decode_test.dart` covers the other half:

- the decode bound follows the *device* pixels a cover will occupy, rounded up,
  so a 48 px avatar asks for 64 px at 100% and 96 px at 200%;
- it rounds up to a multiple of `artworkDecodeQuantum` (32). The requested
  extent is part of the `ResizeImage` cache key and `AlbumArtwork` derives it
  from its own box, so an exact extent would mint a fresh decode for every
  width a resizable window is dragged through. Bucketing caps that at 32
  decodes across the whole range instead of hundreds, at a cost of at most 31
  pixels of over-decode, and never rounds down;
- it caps at `maxArtworkDecodeExtent` (1024, the same bound Linthra's local
  artwork cache applies), so a full-screen cover on a 4K panel at 200% cannot
  ask for a 2160 px decode;
- it never upscales, and falls back to full size for an unmeasured box;
- and the surfaces that draw covers really pass one.

That last point is the change #457 actually needed. Before it, every cover
decoded at its source resolution regardless of the box it was drawn into: a
1024 px cover in a 48 px avatar cost the same memory and CPU as showing it
full-screen, once per visible row, and every point of scale factor made it
worse rather than better. The bound lives on `artworkImageProvider`, the app's
single artwork seam, so no surface can forget it. The Now Playing backdrop is
the one exception that uses a constant: it is behind a 40 px gaussian blur, so
decoding it above 256 px buys nothing at all.

## What still needs a person

Widget tests run against Flutter's own layout, not against a compositor. They
cannot tell you whether GNOME actually handed the app the pixel ratio you think
it did, whether a Wayland fractional scale looks soft because the compositor is
downscaling a 2x buffer, or whether a font renders differently under KDE's
FreeType settings.

Before a release, on both desktops:

**GNOME (Wayland and X11)**

1. Settings → Displays → Scale: check 100%, 125%, 150%, 175%, 200% in turn.
   Fractional scales need "Fractional Scaling" enabled under Wayland.
2. At each: open Library, an album, an artist and Now Playing. Look for clipped
   labels, controls pushed off the edge, and artwork that looks soft rather than
   sharp.
3. Settings → Accessibility → Large Text on, then repeat at 100% and 150%.
4. Drag the window down to its minimum. It must stop at a usable size, and the
   layout must still work there.

**KDE Plasma**

1. Display Configuration → Global scale: same five values.
2. Fonts → Force font DPI at 96 and 120, on top of 100% and 150% scaling.
3. The same four screens, plus a resize down to the minimum.

**Both**

- A window dragged between a HiDPI laptop panel and an external 1080p monitor
  must re-render sharply on the second screen, not stay blurry.
- On an ultrawide, the content must stay centred and capped rather than
  stretching a track row across the whole panel.

Anything found there is a bug worth a fixture in the matrix above, so the next
release does not need a person to find it again.

## Related

- `lib/shared/layout/adaptive_layout.dart`, the size classes and content caps
- [manual-test-checklist.md](./manual-test-checklist.md), the wider manual pass
- [linux-desktop.md](./linux-desktop.md), the Linux build and its runner
