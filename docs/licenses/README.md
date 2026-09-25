# Historical license texts

This directory preserves license texts that Linthra releases were **actually
published under**, so that the terms attached to those releases stay available
after the project's active license changes.

Nothing in this directory is Linthra's current license.

| File | Applies to | Status |
| --- | --- | --- |
| [`MPL-2.0.txt`](./MPL-2.0.txt) | Every Linthra release and source tag published **before** the AGPL relicensing commit, up to and including **v0.2.4** | Historical — preserved verbatim, do not edit |

## Current license

Linthra's current and future license is **AGPL-3.0-or-later**. The active text
is the unmodified GNU Affero General Public License version 3 in the top-level
[`LICENSE`](../../LICENSE) file.

See [`../license-transition.md`](../license-transition.md) for the completed
transition record and [`../relicensing-consent.md`](../relicensing-consent.md)
for the contributor-consent record.

## Why the old text is kept

Releases published under MPL-2.0 remain under MPL-2.0. Relicensing the project
going forward does not, and cannot, retroactively change the terms that a user
already received with an earlier release. Anyone who obtained Linthra v0.2.4 or
earlier keeps the MPL-2.0 rights they were granted at that time, and needs the
license text to exercise them.

`MPL-2.0.txt` is therefore an immutable historical record. It is the exact
byte-for-byte content of the repository's top-level `LICENSE` file as it stood
immediately before the relicensing commit (SHA-256
`3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04`).

## Third-party licenses are unaffected

Vendored third-party code keeps its own upstream license and is **not** covered
by Linthra's relicensing. In particular
[`third_party/just_audio_media_kit/LICENSE`](../../third_party/just_audio_media_kit/LICENSE)
(the Unlicense) is upstream's own notice and must be preserved as-is, as are
[`third_party/just_audio/LICENSE`](../../third_party/just_audio/LICENSE) (MIT,
with ExoPlayer's Apache-2.0 notice),
[`third_party/media3_decoder_flac/LICENSE`](../../third_party/media3_decoder_flac/LICENSE)
(Apache-2.0) and
[`third_party/libflac/COPYING.Xiph`](../../third_party/libflac/COPYING.Xiph)
(BSD-3-Clause).
