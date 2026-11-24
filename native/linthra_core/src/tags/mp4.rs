//! MP4 audio (M4A, ALAC): ISO/IEC 14496-12 boxes, with the iTunes tags in
//! `moov/udta/meta/ilst` (or `moov/meta/ilst`) and the length in `moov/mvhd`.
//!
//! Box sizes are trusted only as far as they go: a size of 0 runs to the end
//! of its parent (what an interrupted encode leaves in `mdat`), a size of 1
//! is followed by a 64-bit one, and a box that claims more than its parent
//! holds is read as far as the parent goes. Every box moves the walk at least
//! eight bytes on, so it always ends.

use std::io::{self, Read, Seek, SeekFrom};

use super::{first, joined, read_up_to, track_number, u32_be, AudioTags};

/// The largest `moov` read into memory. A long file's sample tables and a
/// big cover make a few megabytes; anything past this is not tags.
const MAX_MOOV_BYTES: u64 = 64 << 20;

/// The most top-level boxes walked looking for `moov`.
const MAX_TOP_LEVEL_BOXES: usize = 1 << 16;

/// Whether `head` (a file's first bytes) opens with an `ftyp` box.
pub fn claims(head: &[u8]) -> bool {
    head.get(4..8) == Some(b"ftyp")
}

pub fn read<R: Read + Seek>(source: &mut R, with_cover: bool) -> io::Result<Option<AudioTags>> {
    let length = source.seek(SeekFrom::End(0))?;
    let mut at = 0u64;
    let mut moov = None;
    for _ in 0..MAX_TOP_LEVEL_BOXES {
        if at + 8 > length {
            break;
        }
        source.seek(SeekFrom::Start(at))?;
        let header = read_up_to(source, 16)?;
        let Some((kind, header_len, size)) = box_header(&header, length - at) else {
            break;
        };
        if &kind == b"moov" {
            let payload = size - header_len;
            if payload <= MAX_MOOV_BYTES {
                source.seek(SeekFrom::Start(at + header_len))?;
                moov = Some(read_up_to(source, payload)?);
            }
            break;
        }
        at += size;
    }
    // An MP4 with no tags to find, such as one whose encode never finished:
    // read, and nothing in it.
    let Some(moov) = moov else {
        return Ok(Some(AudioTags::default()));
    };

    let mut items = Items::default();
    let mut duration_micros = None;
    for (kind, payload) in children(&moov) {
        match &kind {
            b"mvhd" => duration_micros = mvhd_micros(payload),
            b"udta" => {
                for (kind, payload) in children(payload) {
                    if &kind == b"meta" {
                        items.read_meta(payload, with_cover);
                    }
                }
            }
            b"meta" => items.read_meta(payload, with_cover),
            _ => {}
        }
    }

    let track = items
        .track
        .filter(|n| *n > 0)
        .or_else(|| items.cddb_track.as_deref().and_then(track_number));
    Ok(Some(AudioTags {
        title: first(&items.title),
        artist: joined(&items.artist),
        album_artist: joined(&items.album_artist),
        album: first(&items.album),
        track_number: track,
        duration_micros: duration_micros.filter(|micros| *micros > 0),
        cover: items.cover,
    }))
}

/// A box header in `bytes`, with `remaining` bytes from its start to the end
/// of what holds it: its type, its header's length and its size, clamped to
/// `remaining`. `None` when there is no header to read.
fn box_header(bytes: &[u8], remaining: u64) -> Option<([u8; 4], u64, u64)> {
    if bytes.len() < 8 || remaining < 8 {
        return None;
    }
    let kind = [bytes[4], bytes[5], bytes[6], bytes[7]];
    let (header_len, size) = match u32_be(bytes, 0) {
        0 => (8, remaining),
        1 => {
            let large = u64::from_be_bytes(bytes.get(8..16)?.try_into().ok()?);
            if large < 16 {
                return None;
            }
            (16, large)
        }
        size if size < 8 => return None,
        size => (8, u64::from(size)),
    };
    Some((kind, header_len, size.min(remaining)))
}

/// The boxes inside `data`, each with its payload.
fn children(data: &[u8]) -> impl Iterator<Item = ([u8; 4], &[u8])> {
    let mut at = 0usize;
    std::iter::from_fn(move || {
        let rest = data.get(at..)?;
        let (kind, header_len, size) = box_header(rest, rest.len() as u64)?;
        let (header_len, size) = (header_len as usize, size as usize);
        if size < header_len {
            return None;
        }
        at += size;
        Some((kind, &rest[header_len..size]))
    })
}

/// The movie's length from an `mvhd` payload: its duration over its
/// timescale, in microseconds.
fn mvhd_micros(payload: &[u8]) -> Option<i64> {
    let (timescale, duration) = match payload.first()? {
        1 if payload.len() >= 32 => (
            u32_be(payload, 20),
            u64::from_be_bytes(payload[24..32].try_into().ok()?),
        ),
        0 if payload.len() >= 20 => (u32_be(payload, 12), u64::from(u32_be(payload, 16))),
        _ => return None,
    };
    if timescale == 0 {
        return None;
    }
    i64::try_from(u128::from(duration) * 1_000_000 / u128::from(timescale)).ok()
}

/// The iTunes items Linthra keeps; the first of each kind wins.
#[derive(Default)]
struct Items {
    title: Option<Vec<String>>,
    artist: Option<Vec<String>>,
    album_artist: Option<Vec<String>>,
    album: Option<Vec<String>>,
    track: Option<i64>,
    cddb_track: Option<String>,
    cover: Option<Vec<u8>>,
}

impl Items {
    /// A `meta` box's `ilst`. `meta` is a full box (version and flags first),
    /// except as QuickTime writes it, where its first child follows at once.
    fn read_meta(&mut self, payload: &[u8], with_cover: bool) {
        let boxes = if payload.get(4..8) == Some(b"hdlr") {
            payload
        } else {
            payload.get(4..).unwrap_or_default()
        };
        for (kind, ilst) in children(boxes) {
            if &kind == b"ilst" {
                for (kind, item) in children(ilst) {
                    self.take(&kind, item, with_cover);
                }
            }
        }
    }

    fn take(&mut self, kind: &[u8; 4], item: &[u8], with_cover: bool) {
        let slot = match kind {
            b"\xa9nam" => &mut self.title,
            b"\xa9ART" => &mut self.artist,
            b"aART" => &mut self.album_artist,
            b"\xa9alb" => &mut self.album,
            b"trkn" => {
                if self.track.is_none() {
                    // Two reserved bytes, the track, the total.
                    self.track = values(item)
                        .next()
                        .filter(|(_, value)| value.len() >= 4)
                        .map(|(_, value)| i64::from(u16::from_be_bytes([value[2], value[3]])));
                }
                return;
            }
            b"covr" => {
                if with_cover && self.cover.is_none() {
                    self.cover = values(item)
                        .map(|(_, value)| value)
                        .find(|value| !value.is_empty())
                        .map(<[u8]>::to_vec);
                }
                return;
            }
            b"----" => {
                self.take_freeform(item);
                return;
            }
            _ => return,
        };
        if slot.is_none() {
            *slot = Some(
                values(item)
                    .map(|(kind, value)| text(kind, value))
                    .collect(),
            );
        }
    }

    /// A freeform item: `mean`, `name`, then the `data`. Only the CDDB
    /// track number is kept, for files with no `trkn`.
    fn take_freeform(&mut self, item: &[u8]) {
        let mut name = None;
        for (kind, payload) in children(item) {
            match &kind {
                b"name" => name = payload.get(4..),
                b"data"
                    if name == Some(b"iTunes_CDDB_TrackNumber".as_slice())
                        && self.cddb_track.is_none()
                        && payload.len() >= 8 =>
                {
                    self.cddb_track = Some(text(u32_be(payload, 0) & 0x00FF_FFFF, &payload[8..]));
                }
                _ => {}
            }
        }
    }
}

/// An item's `data` boxes: each one's well-known type, and its value.
fn values(item: &[u8]) -> impl Iterator<Item = (u32, &[u8])> {
    children(item)
        .filter(|(kind, payload)| kind == b"data" && payload.len() >= 8)
        .map(|(_, payload)| (u32_be(payload, 0) & 0x00FF_FFFF, &payload[8..]))
}

/// A text value of well-known type `kind`: UTF-16BE for type 2, else UTF-8,
/// read as Latin-1 when it isn't UTF-8.
fn text(kind: u32, value: &[u8]) -> String {
    if kind == 2 {
        let units: Vec<u16> = value
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&pair| u16::from_be_bytes(pair))
            .collect();
        return String::from_utf16_lossy(&units);
    }
    match std::str::from_utf8(value) {
        Ok(text) => text.to_owned(),
        Err(_) => value.iter().map(|b| char::from(*b)).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_box_sizes_as_the_spec_writes_them() {
        assert_eq!(box_header(b"\0\0\0\x10moov", 100), Some((*b"moov", 8, 16)));
        // 0: runs to the end of what holds it.
        assert_eq!(box_header(b"\0\0\0\0mdat", 100), Some((*b"mdat", 8, 100)));
        // 1: a 64-bit size follows.
        let large = [&[0, 0, 0, 1][..], b"mdat", &40u64.to_be_bytes()].concat();
        assert_eq!(box_header(&large, 100), Some((*b"mdat", 16, 40)));
        // Too small to be a box.
        assert_eq!(box_header(b"\0\0\0\x04free", 100), None);
        // Claims more than there is: only what there is.
        assert_eq!(box_header(b"\0\0\x10\0free", 20), Some((*b"free", 8, 20)));
    }

    #[test]
    fn walks_children_without_looping() {
        let data = [b"\0\0\0\x08free".as_slice(), b"\0\0\0\0skip", &[0; 4]].concat();
        let kinds: Vec<_> = children(&data).map(|(kind, _)| kind).collect();
        assert_eq!(kinds, [*b"free", *b"skip"]);
    }

    #[test]
    fn reads_a_length_from_either_mvhd_version() {
        let mut v0 = vec![0u8; 20];
        v0[12..16].copy_from_slice(&1000u32.to_be_bytes());
        v0[16..20].copy_from_slice(&2500u32.to_be_bytes());
        assert_eq!(mvhd_micros(&v0), Some(2_500_000));
        v0[12..16].copy_from_slice(&0u32.to_be_bytes());
        assert_eq!(mvhd_micros(&v0), None);
        assert_eq!(mvhd_micros(&[1, 0, 0]), None);
    }
}
