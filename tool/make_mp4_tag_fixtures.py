"""Writes the MP4 (M4A) fixtures in test/fixtures/tags/, which mp4_cases.txt
there describes.

Each file is built box by box from ISO/IEC 14496-12 and the iTunes metadata
layout (moov/udta/meta/ilst, each item holding `data` boxes), so a reader is
held to those rather than to one library. Run it from the repository root
after changing a case, then update mp4_cases.txt by hand:

    python3 tool/make_mp4_tag_fixtures.py
"""

from __future__ import annotations

import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "tags"
COVER = bytes([1, 2, 3, 4, 5])

UTF8 = 1
UTF16 = 2
INTEGER = 0
PNG = 14


def box(kind: bytes, payload: bytes = b"") -> bytes:
    return struct.pack(">I", 8 + len(payload)) + kind + payload


def full_box(kind: bytes, payload: bytes, version: int = 0) -> bytes:
    return box(kind, bytes([version, 0, 0, 0]) + payload)


def data(value: bytes, kind: int = UTF8) -> bytes:
    """A `data` box: type indicator (version 0 and a well-known type),
    locale, then the value."""
    return box(b"data", struct.pack(">II", kind, 0) + value)


def item(kind: bytes, *values: bytes) -> bytes:
    return box(kind, b"".join(values))


def text(kind: bytes, value: str) -> bytes:
    return item(kind, data(value.encode()))


def track(number: int, total: int) -> bytes:
    return item(b"trkn", data(struct.pack(">HHHH", 0, number, total, 0), INTEGER))


def freeform(name: str, value: str) -> bytes:
    return box(
        b"----",
        full_box(b"mean", b"com.apple.iTunes")
        + full_box(b"name", name.encode())
        + data(value.encode()),
    )


def mvhd(timescale: int, duration: int, version: int = 0) -> bytes:
    if version == 1:
        times = struct.pack(">QQIQ", 0, 0, timescale, duration)
    else:
        times = struct.pack(">IIII", 0, 0, timescale, duration)
    return full_box(b"mvhd", times + bytes(80), version)


def ilst_meta(items: bytes, versioned: bool = True) -> bytes:
    hdlr = full_box(b"hdlr", bytes(4) + b"mdir" + bytes(12) + b"\0")
    body = hdlr + box(b"ilst", items)
    return full_box(b"meta", body) if versioned else box(b"meta", body)


def moov(
    items: bytes,
    timescale: int = 44100,
    duration: int = 44100 * 3,
    version: int = 0,
    versioned_meta: bool = True,
) -> bytes:
    return box(
        b"moov",
        mvhd(timescale, duration, version)
        + box(b"udta", ilst_meta(items, versioned_meta)),
    )


FTYP = box(b"ftyp", b"M4A \0\0\0\0M4A mp42isom")
MDAT = box(b"mdat", bytes(64))


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}

    files["m4a_basic.m4a"] = (
        FTYP
        + moov(
            text(b"\xa9nam", "Hello")
            + text(b"\xa9ART", "Alice")
            + text(b"aART", "Various Artists")
            + text(b"\xa9alb", "Album")
            + track(3, 12)
            + item(b"covr", data(COVER, PNG))
        )
        + MDAT
    )

    # QuickTime writes `meta` without the version and flags of a full box.
    files["m4a_meta_without_version.m4a"] = (
        FTYP + moov(text(b"\xa9nam", "Quick"), versioned_meta=False) + MDAT
    )

    files["m4a_mvhd_v1.m4a"] = (
        FTYP
        + moov(text(b"\xa9nam", "Long"), timescale=1000, duration=61000, version=1)
        + MDAT
    )

    # #855: a vinyl rip's CDDB track number of A1.
    files["m4a_cddb_vinyl.m4a"] = (
        FTYP
        + moov(text(b"\xa9nam", "Vinyl") + freeform("iTunes_CDDB_TrackNumber", "A1"))
        + MDAT
    )

    files["m4a_cddb_track.m4a"] = (
        FTYP
        + moov(
            text(b"\xa9nam", "Cddb")
            + track(0, 0)
            + freeform("iTunes_CDDB_TrackNumber", "7")
        )
        + MDAT
    )

    files["m4a_invalid_utf8.m4a"] = (
        FTYP + moov(item(b"\xa9nam", data(b"Caf\xe9"))) + MDAT
    )

    files["m4a_utf16.m4a"] = (
        FTYP + moov(item(b"\xa9nam", data("Été".encode("utf-16-be"), UTF16))) + MDAT
    )

    files["m4a_two_artists.m4a"] = (
        FTYP + moov(item(b"\xa9ART", data(b"A"), data(b"  "), data(b"B"))) + MDAT
    )

    # Audio first, then the tags: what most encoders write.
    files["m4a_moov_last.m4a"] = FTYP + MDAT + moov(text(b"\xa9nam", "Last"))

    # A 64-bit box size (size 1, then the size in 8 bytes) before the tags.
    large = struct.pack(">I", 1) + b"mdat" + struct.pack(">Q", 16 + 32) + bytes(32)
    files["m4a_largesize.m4a"] = FTYP + large + moov(text(b"\xa9nam", "Large"))

    # An interrupted encode: `mdat` still sized 0, "runs to the end".
    files["m4a_mdat_size_zero.m4a"] = (
        FTYP
        + moov(text(b"\xa9nam", "Unfinished"))
        + struct.pack(">I", 0)
        + b"mdat"
        + bytes(40)
    )

    files["m4a_no_moov.m4a"] = FTYP + struct.pack(">I", 0) + b"mdat" + bytes(40)

    files["m4a_blank_values.m4a"] = (
        FTYP
        + moov(text(b"\xa9nam", "   ") + text(b"\xa9alb", "Kept"), duration=0)
        + MDAT
    )

    return files


def main() -> None:
    for name, contents in build().items():
        (HERE / name).write_bytes(contents)


if __name__ == "__main__":
    main()
