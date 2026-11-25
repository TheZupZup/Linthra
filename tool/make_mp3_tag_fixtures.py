"""Writes the MP3 fixtures in test/fixtures/tags/, which mp3_cases.txt there
describes.

Each file is built byte by byte from the ID3v2.2/2.3/2.4, ID3v1 and MPEG
audio specs, so a reader can be held to what the specs say rather than to
what one library happens to do. Run it from the repository root after
changing a case, then update mp3_cases.txt by hand:

    python3 tool/make_mp3_tag_fixtures.py
"""

from __future__ import annotations

import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "tags"
COVER = bytes([1, 2, 3, 4, 5])
BACK = bytes([9, 9])

# MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, no padding: 417-byte frames.
MPEG1_HEADER = bytes([0xFF, 0xFB, 0x90, 0x00])
MPEG1_FRAME = 417
MPEG1_SIDE_INFO = 32  # stereo
# MPEG-2 Layer III, 64 kbit/s, 22.05 kHz: 208-byte frames.
MPEG2_HEADER = bytes([0xFF, 0xF3, 0x80, 0x00])
MPEG2_FRAME = 208
MPEG2_SIDE_INFO = 17  # stereo


def synchsafe(value: int) -> bytes:
    return bytes((value >> shift) & 0x7F for shift in (21, 14, 7, 0))


def audio(count: int, header: bytes = MPEG1_HEADER, size: int = MPEG1_FRAME) -> bytes:
    """`count` silent frames: a header, then zeros to the frame's length."""
    return (header + bytes(size - len(header))) * count


def info_frame(
    marker: bytes,
    frames: int,
    header: bytes = MPEG1_HEADER,
    size: int = MPEG1_FRAME,
    side_info: int = MPEG1_SIDE_INFO,
) -> bytes:
    """A Xing or Info frame: the header, side info, the marker, the flags
    (frame count present), then the frame count."""
    body = header + bytes(side_info) + marker + struct.pack(">II", 1, frames)
    return body + bytes(size - len(body))


def vbri_frame(frames: int) -> bytes:
    """A Fraunhofer VBRI frame: its header 32 bytes after the frame header."""
    body = (
        MPEG1_HEADER + bytes(32) + b"VBRI" + struct.pack(">HHHII", 1, 0, 75, 0, frames)
    )
    return body + bytes(MPEG1_FRAME - len(body))


def text(encoding: int, value: bytes) -> bytes:
    return bytes([encoding]) + value


def latin1(value: str) -> bytes:
    return text(0, value.encode("latin-1"))


def frame23(frame_id: str, payload: bytes, flags: bytes = b"\0\0") -> bytes:
    return frame_id.encode() + struct.pack(">I", len(payload)) + flags + payload


def frame24(frame_id: str, payload: bytes, flags: bytes = b"\0\0") -> bytes:
    return frame_id.encode() + synchsafe(len(payload)) + flags + payload


def frame22(frame_id: str, payload: bytes) -> bytes:
    return frame_id.encode() + struct.pack(">I", len(payload))[1:] + payload


def apic(
    picture_type: int, data: bytes, description: bytes = b"\0", encoding: int = 0
) -> bytes:
    return (
        bytes([encoding]) + b"image/png\0" + bytes([picture_type]) + description + data
    )


def tag(major: int, frames: bytes, flags: int = 0, padding: int = 16) -> bytes:
    body = frames + bytes(padding)
    return b"ID3" + bytes([major, 0, flags]) + synchsafe(len(body)) + body


def unsynchronise(data: bytes) -> bytes:
    """Inserts a zero after every 0xFF followed by 0xE0 or more, or by zero."""
    out = bytearray()
    for i, byte in enumerate(data):
        out.append(byte)
        if byte == 0xFF and (
            i + 1 == len(data) or data[i + 1] >= 0xE0 or data[i + 1] == 0
        ):
            out.append(0)
    return bytes(out)


def id3v1(title: bytes, artist: bytes, album: bytes, track: int = 0) -> bytes:
    def field(value: bytes, size: int) -> bytes:
        return value[:size].ljust(size, b"\0")

    comment = field(b"", 28) + bytes([0, track]) if track else field(b"", 30)
    return (
        b"TAG"
        + field(title, 30)
        + field(artist, 30)
        + field(album, 30)
        + b"1999"
        + comment
        + bytes([255])
    )


def utf16(value: str, big_endian: bool = False) -> bytes:
    return value.encode("utf-16-be" if big_endian else "utf-16-le")


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}

    files["id3v23_basic.mp3"] = (
        tag(
            3,
            frame23("TIT2", latin1("Hello"))
            + frame23("TPE1", latin1("Alice"))
            + frame23("TPE2", latin1("Various Artists"))
            + frame23("TALB", latin1("Album"))
            + frame23("TRCK", latin1("3/12"))
            + frame23("APIC", apic(3, COVER)),
        )
        + info_frame(b"Xing", 100)
        + audio(3)
    )

    # #855: a UTF-8 frame holding Latin-1 bytes.
    files["id3v24_invalid_utf8.mp3"] = tag(
        4,
        frame24("TIT2", text(3, b"Caf\xe9"))
        + frame24("TPE1", text(3, "Björk".encode()))
        + frame24("TPE2", text(3, b"Caf\xe9 Society")),
    ) + audio(4)

    files["id3v24_multi_values.mp3"] = tag(
        4,
        frame24("TIT2", text(3, b"  \0Real title\0"))
        + frame24("TPE1", text(3, b"Alice\0Bob\0 \0"))
        + frame24("TALB", text(3, b"First\0Second")),
    ) + audio(2)

    files["id3v23_utf16.mp3"] = tag(
        3,
        frame23("TIT2", text(1, b"\xff\xfe" + utf16("Été")))
        + frame23("TPE1", text(1, b"\xfe\xff" + utf16("Ünï", big_endian=True)))
        + frame23("TALB", text(2, utf16("Ålbum", big_endian=True) + b"\0\0"))
        + frame23(
            "APIC", apic(4, BACK, b"\xff\xfe" + utf16("back") + b"\0\0", encoding=1)
        )
        + frame23(
            "APIC", apic(3, COVER, b"\xff\xfe" + utf16("front") + b"\0\0", encoding=1)
        ),
    ) + audio(2)

    files["id3v22.mp3"] = tag(
        2,
        frame22("TT2", latin1("Old"))
        + frame22("TP1", latin1("Two Two"))
        + frame22("TAL", latin1("Vintage"))
        + frame22("TRK", latin1("9"))
        + frame22("PIC", b"\0PNG\0\0" + COVER),
    ) + audio(2)

    unsynced = unsynchronise(
        frame23("TIT2", text(0, b"\xff\xe0Z")) + frame23("TPE1", latin1("Sync"))
    )
    files["id3v23_unsync.mp3"] = tag(3, unsynced, flags=0x80) + audio(2)

    files["id3v23_extended_header.mp3"] = tag(
        3,
        struct.pack(">IHI", 6, 0, 0) + frame23("TIT2", latin1("Extended")),
        flags=0x40,
    ) + audio(2)

    files["id3v24_frame_flags.mp3"] = tag(
        4,
        # Data length indicator: four sync-safe bytes before the text.
        frame24("TIT2", synchsafe(6) + latin1("Sized"), flags=b"\0\x01")
        # Compressed: nothing a reader without zlib can use, so skipped.
        + frame24("TPE1", b"\0\0\0\x05xxxxx", flags=b"\0\x08")
        # Grouped: one group byte before the text.
        + frame24("TALB", b"\x07" + latin1("Grouped"), flags=b"\0\x40"),
    ) + audio(2)

    # iTunes writes v2.4 frame sizes as plain big-endian: 0xC8 is not
    # sync-safe, and read as one it would land mid-frame.
    long_title = latin1("L" * 199)
    files["id3v24_plain_sizes.mp3"] = tag(
        4,
        b"TIT2"
        + struct.pack(">I", len(long_title))
        + b"\0\0"
        + long_title
        + b"TPE1"
        + struct.pack(">I", 6)
        + b"\0\0"
        + latin1("After"),
    ) + audio(2)

    # #855: only an ID3v1 tag, its title Latin-1 and NUL-padded.
    files["id3v1_only.mp3"] = audio(20) + id3v1(b"Caf\xe9", b"Old Rip", b"", track=7)

    files["id3v23_with_v1.mp3"] = (
        tag(3, frame23("TIT2", latin1("From v2")))
        + audio(20)
        + id3v1(b"From v1", b"Artist v1", b"Album v1", track=2)
    )

    files["id3v23_tlen.mp3"] = tag(
        3, frame23("TIT2", latin1("Timed")) + frame23("TLEN", latin1("5000"))
    ) + audio(10)

    files["id3v23_vbri.mp3"] = (
        tag(3, frame23("TIT2", latin1("Vbri"))) + vbri_frame(200) + audio(2)
    )

    files["id3v23_info.mp3"] = (
        tag(3, frame23("TIT2", latin1("Info"))) + info_frame(b"Info", 50) + audio(2)
    )

    files["mpeg2_xing.mp3"] = (
        tag(3, frame23("TIT2", latin1("Mpeg2")))
        + info_frame(b"Xing", 100, MPEG2_HEADER, MPEG2_FRAME, MPEG2_SIDE_INFO)
        + audio(2, MPEG2_HEADER, MPEG2_FRAME)
    )

    files["id3v23_blank_values.mp3"] = tag(
        3,
        frame23("TIT2", latin1("   "))
        + frame23("TRCK", latin1("A1"))
        + frame23("TPE1", latin1("Present")),
    ) + audio(2)

    files["id3v23_no_audio.mp3"] = tag(3, frame23("TIT2", latin1("Tag only")))

    files["leading_junk.mp3"] = (
        tag(3, frame23("TIT2", latin1("Junk first"))) + bytes(300) + audio(4)
    )

    # An empty APE tag at the end: a tag, not audio, so the length leaves it
    # out.
    ape_footer = b"APETAGEX" + struct.pack("<IIII", 2000, 32, 0, 0) + bytes(8)
    files["ape_tagged.mp3"] = audio(4) + ape_footer

    files["id3_before_flac.mp3"] = (
        tag(3, frame23("TIT2", latin1("X"))) + b"fLaC" + bytes(64)
    )

    files["id3v25.mp3"] = tag(5, frame23("TIT2", latin1("Future"))) + audio(2)

    files["no_mpeg.bin"] = bytes(range(256)) * 4

    return files


def main() -> None:
    for name, data in build().items():
        (HERE / name).write_bytes(data)


if __name__ == "__main__":
    main()
