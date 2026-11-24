"""Writes the WAV, AIFF and APE fixtures in test/fixtures/tags/, which
lossless_cases.txt there describes.

Built chunk by chunk from the RIFF/WAVE, AIFF/AIFF-C, APEv2 and Monkey's
Audio layouts. Run it from the repository root after changing a case, then
update lossless_cases.txt by hand:

    python3 tool/make_lossless_tag_fixtures.py
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "tags"
COVER = bytes([1, 2, 3, 4, 5])

# MPEG-1 Layer III, 128 kbit/s, 44.1 kHz: 417-byte frames.
MPEG1_FRAME = bytes([0xFF, 0xFB, 0x90, 0x00]) + bytes(413)


def riff_chunk(kind: bytes, payload: bytes) -> bytes:
    pad = b"\0" if len(payload) % 2 else b""
    return kind + struct.pack("<I", len(payload)) + payload + pad


def aiff_chunk(kind: bytes, payload: bytes) -> bytes:
    pad = b"\0" if len(payload) % 2 else b""
    return kind + struct.pack(">I", len(payload)) + payload + pad


def wav(chunks: bytes) -> bytes:
    return b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks


def fmt(rate: int, channels: int, bits: int) -> bytes:
    align = channels * bits // 8
    return riff_chunk(
        b"fmt ", struct.pack("<HHIIHH", 1, channels, rate, rate * align, align, bits)
    )


def info(**fields: bytes) -> bytes:
    body = b"".join(
        riff_chunk(key.encode(), value + b"\0") for key, value in fields.items()
    )
    return riff_chunk(b"LIST", b"INFO" + body)


def synchsafe(value: int) -> bytes:
    return bytes((value >> shift) & 0x7F for shift in (21, 14, 7, 0))


def id3v23(*frames: bytes) -> bytes:
    body = b"".join(frames)
    return b"ID3\x03\0\0" + synchsafe(len(body)) + body


def frame(frame_id: str, payload: bytes) -> bytes:
    return frame_id.encode() + struct.pack(">I", len(payload)) + b"\0\0" + payload


def latin1(value: str) -> bytes:
    return b"\0" + value.encode("latin-1")


def apic(data: bytes) -> bytes:
    return b"\0image/png\0\x03\0" + data


def extended80(value: float) -> bytes:
    """An IEEE 754 80-bit extended float, as AIFF stores its sample rate."""
    mantissa, exponent = math.frexp(value)
    return struct.pack(">HQ", exponent - 1 + 16383, int(mantissa * (1 << 64)))


def aiff(form: bytes, chunks: bytes) -> bytes:
    return b"FORM" + struct.pack(">I", 4 + len(chunks)) + form + chunks


def comm(
    channels: int, frames: int, bits: int, rate: float, aifc: bool = False
) -> bytes:
    body = struct.pack(">hIh", channels, frames, bits) + extended80(rate)
    if aifc:
        body += b"NONE" + b"\x0enot compressed\0"
    return aiff_chunk(b"COMM", body)


def ssnd() -> bytes:
    return aiff_chunk(b"SSND", struct.pack(">II", 0, 0) + bytes(16))


def ape_tag(items: list[tuple[str, bytes, int]], with_header: bool = True) -> bytes:
    """An APEv2 tag: optional header, the items, then the footer. Each item is
    its value's size, its flags (bits 1-2: 0 text, 1 binary), its key and
    a NUL, then the value."""
    body = b"".join(
        struct.pack("<II", len(value), flags) + key.encode() + b"\0" + value
        for key, value, flags in items
    )
    size = len(body) + 32
    flags = 0x80000000 if with_header else 0

    def header_or_footer(is_header: bool) -> bytes:
        bit = 0x20000000 if is_header else 0
        return (
            b"APETAGEX"
            + struct.pack("<IIII", 2000, size, len(items), flags | bit)
            + bytes(8)
        )

    return (
        (header_or_footer(True) if with_header else b"")
        + body
        + header_or_footer(False)
    )


def text_item(key: str, value: str) -> tuple[str, bytes, int]:
    return (key, value.encode(), 0)


def id3v1(title: bytes) -> bytes:
    return (
        b"TAG"
        + title.ljust(30, b"\0")
        + bytes(30)
        + bytes(30)
        + b"2001"
        + bytes(30)
        + b"\xff"
    )


def mac_new(total_frames: int, final_blocks: int, rate: int) -> bytes:
    """Monkey's Audio 3.98+: a 52-byte descriptor, then the header."""
    descriptor = (
        b"MAC " + struct.pack("<HHIIIIIII", 3990, 0, 52, 24, 0, 0, 0, 0, 0) + bytes(16)
    )
    header = struct.pack(
        "<HHIIIHHI", 2000, 0, 73728 * 4, final_blocks, total_frames, 16, 2, rate
    )
    return descriptor + header + bytes(32)


def mac_old(total_frames: int, final_blocks: int, rate: int) -> bytes:
    """Monkey's Audio before 3.98: one header right after the magic."""
    return (
        b"MAC "
        + struct.pack(
            "<HHHHIIIII", 3950, 2000, 0, 2, rate, 0, 0, total_frames, final_blocks
        )
        + bytes(32)
    )


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}

    files["wav_info.wav"] = wav(
        fmt(8000, 1, 8)
        + info(INAM=b"Wave", IART=b"Wav Artist", IPRD=b"Wav Album", ITRK=b"4")
        + riff_chunk(b"data", bytes(16000))
    )

    files["wav_id3.wav"] = wav(
        fmt(8000, 1, 8)
        + info(INAM=b"From Info", IART=b"Info Artist")
        + riff_chunk(b"data", bytes(8000))
        + riff_chunk(
            b"id3 ",
            id3v23(
                frame("TIT2", latin1("From ID3")),
                frame("TPE2", latin1("AA")),
                frame("APIC", apic(COVER)),
            ),
        )
    )

    files["wav_info_encodings.wav"] = wav(
        fmt(8000, 1, 8)
        + info(INAM="Café".encode(), IART=b"Caf\xe9")
        + riff_chunk(b"data", bytes(8000))
    )

    files["wav_odd_chunk.wav"] = wav(
        fmt(8000, 1, 8)
        + riff_chunk(b"junk", b"12345")
        + info(INAM=b"After junk")
        + riff_chunk(b"data", bytes(4000))
    )

    # A download cut short: `data` claims a second, the file holds half.
    files["wav_cut_short.wav"] = (
        wav(fmt(8000, 1, 8) + info(INAM=b"Cut"))
        + b"data"
        + struct.pack("<I", 8000)
        + bytes(4000)
    )

    files["aiff_basic.aiff"] = aiff(
        b"AIFF",
        comm(1, 44100 * 2, 16, 44100.0)
        + aiff_chunk(b"NAME", b"Aiff")
        + aiff_chunk(b"AUTH", b"Apple")
        + ssnd(),
    )

    files["aifc_id3.aifc"] = aiff(
        b"AIFC",
        comm(2, 48000 * 3, 16, 48000.0, aifc=True)
        + ssnd()
        + aiff_chunk(
            b"ID3 ",
            id3v23(
                frame("TIT2", latin1("Aifc ID3")),
                frame("TALB", latin1("Album")),
                frame("APIC", apic(COVER)),
            ),
        ),
    )

    files["aiff_22050.aiff"] = aiff(
        b"AIFF", comm(1, 33075, 8, 22050.0) + aiff_chunk(b"NAME", b"Half rate") + ssnd()
    )

    files["mp3_with_ape.mp3"] = (
        MPEG1_FRAME * 4
        + ape_tag(
            [
                text_item("Title", "Ape Title"),
                text_item("Artist", "Ape Artist"),
                text_item("Album Artist", "Ape AA"),
                text_item("Track", "5/9"),
                ("Cover Art (Front)", b"cover.png\0" + COVER, 2),
            ]
        )
        + id3v1(b"V1 title")
    )

    files["mp3_id3_and_ape.mp3"] = (
        id3v23(frame("TIT2", latin1("ID3 wins")))
        + MPEG1_FRAME * 2
        + ape_tag(
            [text_item("TITLE", "Ape"), text_item("album", "From Ape")],
            with_header=False,
        )
    )

    files["monkeys_new.ape"] = mac_new(2, 44100, 44100) + ape_tag(
        [text_item("Title", "Monkey")]
    )

    files["monkeys_old.ape"] = mac_old(1, 44100, 44100)

    # A footer whose size runs past the file: no APE tag, the rest still read.
    bad_footer = b"APETAGEX" + struct.pack("<IIII", 2000, 1 << 30, 1, 0) + bytes(8)
    files["ape_bad_footer.mp3"] = (
        id3v23(frame("TIT2", latin1("Still read"))) + MPEG1_FRAME * 2 + bad_footer
    )

    return files


def main() -> None:
    for name, contents in build().items():
        (HERE / name).write_bytes(contents)


if __name__ == "__main__":
    main()
