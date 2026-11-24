//! An ID3v2.2, 2.3 or 2.4 tag's frames, by the specs (id3.org): the text
//! frames Linthra keeps, the length, and the attached pictures.
//!
//! Lenient where taggers are sloppy: a UTF-8 frame that isn't UTF-8 is read
//! as Latin-1 (a Windows tagger's "Café" written as `Caf\xe9`), a UTF-16 value
//! without a byte-order mark is read little-endian, and a v2.4 frame size that
//! isn't sync-safe (as iTunes writes them) is read as a plain number.
//! Compressed and encrypted frames are skipped, never guessed at.

use super::picture::Picture;
use super::u32_be;

/// What a tag says, each text field as the values its frame holds (v2.4
/// separates several with NUL).
#[derive(Default)]
pub struct Id3v2 {
    pub title: Option<Vec<String>>,
    pub artist: Option<Vec<String>>,
    pub album_artist: Option<Vec<String>>,
    pub album: Option<Vec<String>>,
    pub track: Option<Vec<String>>,
    pub length_ms: Option<Vec<String>>,
    pub pictures: Vec<Picture>,
}

/// Tag flag: the tag is unsynchronised.
const UNSYNC: u8 = 0x80;
/// Tag flag: an extended header follows (v2.3, v2.4); compression in v2.2.
const EXTENDED: u8 = 0x40;

/// Parses a tag's body (what follows its 10-byte header) of version `major`
/// with header `flags`. Frames it cannot read end the walk; what was read
/// before them is kept.
pub fn parse(major: u8, flags: u8, body: &[u8], with_cover: bool) -> Id3v2 {
    let mut tag = Id3v2::default();
    // v2.2's "compression" flag has no defined scheme: nothing to read.
    if major == 2 && flags & EXTENDED != 0 {
        return tag;
    }
    let owned;
    let data: &[u8] = if major < 4 && flags & UNSYNC != 0 {
        owned = resynchronise(body);
        &owned
    } else {
        body
    };

    let mut at = 0usize;
    if flags & EXTENDED != 0 && data.len() >= 4 {
        // v2.3 counts the extended header without its size field, v2.4 with.
        at = if major == 3 {
            4 + u32_be(data, 0) as usize
        } else {
            synchsafe(&data[..4]) as usize
        };
    }

    let (id_len, header_len) = if major == 2 { (3, 6) } else { (4, 10) };
    while at + header_len <= data.len() {
        let id = &data[at..at + id_len];
        // Padding, or bytes that are no frame: the frames are over.
        if !id
            .iter()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        {
            break;
        }
        let size_bytes = &data[at + id_len..at + id_len + if major == 2 { 3 } else { 4 }];
        let size = match major {
            2 => {
                (usize::from(size_bytes[0]) << 16)
                    | (usize::from(size_bytes[1]) << 8)
                    | usize::from(size_bytes[2])
            }
            3 => u32_be(size_bytes, 0) as usize,
            _ if size_bytes.iter().any(|b| b & 0x80 != 0) => u32_be(size_bytes, 0) as usize,
            _ => synchsafe(size_bytes) as usize,
        };
        let format = if major == 2 { 0 } else { data[at + 9] };
        let start = at + header_len;
        let Some(end) = start.checked_add(size).filter(|end| *end <= data.len()) else {
            break;
        };
        at = end;
        if let Some(payload) = frame_payload(major, flags, format, &data[start..end]) {
            tag.take(major, id, &payload, with_cover);
        }
    }
    tag
}

/// The frame's content once its format flags are undone, or `None` for a
/// frame that is compressed or encrypted.
fn frame_payload(major: u8, tag_flags: u8, format: u8, raw: &[u8]) -> Option<Vec<u8>> {
    let mut payload = raw;
    match major {
        3 => {
            if format & 0xC0 != 0 {
                return None; // compressed or encrypted
            }
            if format & 0x20 != 0 {
                payload = payload.get(1..)?; // group identifier
            }
            Some(payload.to_vec())
        }
        4 => {
            if format & 0x0C != 0 {
                return None; // compressed or encrypted
            }
            if format & 0x40 != 0 {
                payload = payload.get(1..)?; // group identifier
            }
            if format & 0x01 != 0 {
                payload = payload.get(4..)?; // data length indicator
            }
            if format & 0x02 != 0 || tag_flags & UNSYNC != 0 {
                Some(resynchronise(payload))
            } else {
                Some(payload.to_vec())
            }
        }
        _ => Some(payload.to_vec()),
    }
}

impl Id3v2 {
    /// Keeps a frame Linthra uses. The first of each kind wins: a tag holds
    /// one of each, and a second is a tagger's leftover.
    fn take(&mut self, major: u8, id: &[u8], payload: &[u8], with_cover: bool) {
        let slot = match id {
            b"TIT2" | b"TT2" => &mut self.title,
            b"TPE1" | b"TP1" => &mut self.artist,
            b"TPE2" | b"TP2" => &mut self.album_artist,
            b"TALB" | b"TAL" => &mut self.album,
            b"TRCK" | b"TRK" => &mut self.track,
            b"TLEN" | b"TLE" => &mut self.length_ms,
            b"APIC" | b"PIC" => {
                if with_cover {
                    if let Some(picture) = picture(major, payload) {
                        self.pictures.push(picture);
                    }
                }
                return;
            }
            _ => return,
        };
        if slot.is_none() {
            if let Some((&encoding, rest)) = payload.split_first() {
                *slot = Some(text_values(encoding, rest));
            }
        }
    }
}

/// The values of a text frame's body in `encoding`, split at the terminator,
/// trailing empty ones dropped.
pub fn text_values(encoding: u8, bytes: &[u8]) -> Vec<String> {
    let mut values: Vec<String> = match encoding {
        0 => bytes.split(|b| *b == 0).map(latin1).collect(),
        3 => bytes.split(|b| *b == 0).map(utf8_or_latin1).collect(),
        1 | 2 => utf16_values(bytes, encoding == 2),
        _ => Vec::new(),
    };
    while values.last().is_some_and(String::is_empty) {
        values.pop();
    }
    values
}

fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|b| char::from(*b)).collect()
}

fn utf8_or_latin1(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_owned(),
        Err(_) => latin1(bytes),
    }
}

/// UTF-16 values separated by a NUL code unit. Each may open with a
/// byte-order mark; without one, a value is big-endian when `big_endian`
/// (encoding 2) and little-endian otherwise.
fn utf16_values(bytes: &[u8], big_endian: bool) -> Vec<String> {
    let mut values = Vec::new();
    for unit_bytes in split_utf16(bytes) {
        let (mut big, mut body) = (big_endian, unit_bytes);
        if body.starts_with(&[0xFF, 0xFE]) {
            big = false;
            body = &body[2..];
        } else if body.starts_with(&[0xFE, 0xFF]) {
            big = true;
            body = &body[2..];
        }
        let units: Vec<u16> = body
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&pair| {
                if big {
                    u16::from_be_bytes(pair)
                } else {
                    u16::from_le_bytes(pair)
                }
            })
            .collect();
        values.push(String::from_utf16_lossy(&units));
    }
    values
}

/// `bytes` split at each `00 00` on a two-byte boundary.
fn split_utf16(bytes: &[u8]) -> Vec<&[u8]> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut at = 0;
    while at + 1 < bytes.len() {
        if bytes[at] == 0 && bytes[at + 1] == 0 {
            parts.push(&bytes[start..at]);
            start = at + 2;
        }
        at += 2;
    }
    parts.push(&bytes[start..]);
    parts
}

/// An APIC (v2.3, v2.4) or PIC (v2.2) frame's picture: encoding, then the
/// MIME type (or v2.2's three-letter format), the picture type, a
/// description in the encoding, and the image.
fn picture(major: u8, payload: &[u8]) -> Option<Picture> {
    let (&encoding, rest) = payload.split_first()?;
    let rest = if major == 2 {
        rest.get(3..)?
    } else {
        let mime_end = rest.iter().position(|b| *b == 0)?;
        &rest[mime_end + 1..]
    };
    let (&kind, description_and_data) = rest.split_first()?;
    let data_start = if encoding == 1 || encoding == 2 {
        let mut at = 0;
        loop {
            if at + 1 >= description_and_data.len() {
                return None;
            }
            if description_and_data[at] == 0 && description_and_data[at + 1] == 0 {
                break at + 2;
            }
            at += 2;
        }
    } else {
        description_and_data.iter().position(|b| *b == 0)? + 1
    };
    let data = &description_and_data[data_start..];
    (!data.is_empty()).then(|| Picture {
        kind: u32::from(kind),
        data: data.to_vec(),
    })
}

/// A sync-safe integer: four bytes of seven bits each.
pub fn synchsafe(bytes: &[u8]) -> u32 {
    bytes
        .iter()
        .take(4)
        .fold(0, |value, b| (value << 7) | u32::from(b & 0x7F))
}

/// Undoes unsynchronisation: the zero inserted after every 0xFF.
fn resynchronise(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut previous_ff = false;
    for &byte in bytes {
        if !(previous_ff && byte == 0) {
            out.push(byte);
        }
        previous_ff = byte == 0xFF;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_each_text_encoding() {
        assert_eq!(text_values(0, b"Caf\xe9\0"), ["Café"]);
        assert_eq!(text_values(3, "Café".as_bytes()), ["Café"]);
        assert_eq!(text_values(3, b"Caf\xe9"), ["Café"]);
        assert_eq!(text_values(1, b"\xff\xfeA\0B\0"), ["AB"]);
        assert_eq!(text_values(1, b"\xfe\xff\0A\0B"), ["AB"]);
        assert_eq!(text_values(1, b"A\0"), ["A"]);
        assert_eq!(text_values(2, b"\0A\0B\0\0"), ["AB"]);
        assert_eq!(text_values(9, b"A"), Vec::<String>::new());
    }

    #[test]
    fn splits_several_values() {
        assert_eq!(text_values(3, b"Alice\0Bob\0"), ["Alice", "Bob"]);
        assert_eq!(text_values(1, b"\xff\xfeA\0\0\0\xff\xfeB\0"), ["A", "B"]);
    }

    #[test]
    fn an_odd_utf16_value_keeps_what_pairs_up() {
        assert_eq!(text_values(1, b"\xff\xfeA\0B"), ["A"]);
    }

    #[test]
    fn undoes_unsynchronisation() {
        assert_eq!(
            resynchronise(&[0xFF, 0x00, 0xE0, 0x00, 0xFF, 0x00]),
            [0xFF, 0xE0, 0x00, 0xFF]
        );
    }

    #[test]
    fn a_picture_without_image_bytes_is_none() {
        assert!(picture(3, b"\0image/png\0\x03\0").is_none());
        assert!(picture(3, b"\0image/png").is_none());
        assert!(picture(2, b"\0PN").is_none());
    }
}
