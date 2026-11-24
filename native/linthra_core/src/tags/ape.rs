//! APE tags (APEv1 and APEv2), found at the end of MP3, Monkey's Audio and
//! other files, and Monkey's Audio files themselves.
//!
//! An APE tag ends with a 32-byte footer (`APETAGEX`, version, size, item
//! count, flags); its items come before it, each a value size, flags, a key
//! ending in NUL, and the value. Keys are matched without regard to case,
//! spaces or underscores, since taggers write "Album Artist", "ALBUMARTIST"
//! and "album_artist" alike.

use std::io::{self, Read, Seek, SeekFrom};

use super::{first, joined, read_up_to, track_number, u32_le, AudioTags};

/// More items than this and the tag is corrupt: real ones carry tens.
const MAX_ITEMS: u32 = 1 << 16;
/// The largest tag read; a cover makes a few megabytes.
const MAX_TAG_BYTES: u64 = 64 << 20;

/// The fields of an APE tag Linthra keeps, and where the tag starts.
#[derive(Default)]
pub struct ApeTag {
    pub title: Option<Vec<String>>,
    pub artist: Option<Vec<String>>,
    pub album_artist: Option<Vec<String>>,
    pub album: Option<Vec<String>>,
    pub track: Option<String>,
    pub cover: Option<Vec<u8>>,
    /// The tag's first byte, its header's when it has one.
    pub start: u64,
}

/// The APE tag ending at `end`, or `None` when no footer sits right before
/// it, or the footer doesn't hold together.
pub fn read_tag<R: Read + Seek>(
    source: &mut R,
    end: u64,
    with_cover: bool,
) -> io::Result<Option<ApeTag>> {
    if end < 32 {
        return Ok(None);
    }
    source.seek(SeekFrom::Start(end - 32))?;
    let footer = read_up_to(source, 32)?;
    if footer.len() < 32 || !footer.starts_with(b"APETAGEX") {
        return Ok(None);
    }
    let version = u32_le(&footer, 8);
    let size = u64::from(u32_le(&footer, 12));
    let count = u32_le(&footer, 16);
    let flags = u32_le(&footer, 20);
    if !matches!(version, 1000 | 2000)
        || size < 32
        || size > end
        || size > MAX_TAG_BYTES
        || count > MAX_ITEMS
    {
        return Ok(None);
    }
    let items_start = end - size;
    source.seek(SeekFrom::Start(items_start))?;
    let items = read_up_to(source, size - 32)?;

    let has_header = flags & 0x8000_0000 != 0 && items_start >= 32;
    let mut tag = ApeTag {
        start: if has_header {
            items_start - 32
        } else {
            items_start
        },
        ..ApeTag::default()
    };
    let mut at = 0usize;
    for _ in 0..count {
        let Some(header) = items.get(at..at + 8) else {
            break;
        };
        let value_size = u32_le(header, 0) as usize;
        let item_flags = u32_le(header, 4);
        let key_start = at + 8;
        let Some(key_len) = items[key_start..].iter().position(|b| *b == 0) else {
            break;
        };
        let value_start = key_start + key_len + 1;
        let Some(value) = value_start
            .checked_add(value_size)
            .and_then(|value_end| items.get(value_start..value_end))
        else {
            break;
        };
        at = value_start + value_size;
        if key_len == 0 {
            break;
        }
        tag.take(
            &items[key_start..key_start + key_len],
            item_flags,
            value,
            with_cover,
        );
    }
    Ok(Some(tag))
}

impl ApeTag {
    fn take(&mut self, key: &[u8], flags: u32, value: &[u8], with_cover: bool) {
        let key: String = key
            .iter()
            .filter(|b| !matches!(b, b' ' | b'_'))
            .map(|b| char::from(b.to_ascii_uppercase()))
            .collect();
        match (flags >> 1) & 0x03 {
            // Text: UTF-8, several values separated by NUL.
            0 => {
                let text = String::from_utf8_lossy(value);
                let values: Vec<String> = text
                    .split('\0')
                    .filter(|v| !v.is_empty())
                    .map(str::to_owned)
                    .collect();
                let slot = match key.as_str() {
                    "TITLE" => &mut self.title,
                    "ARTIST" => &mut self.artist,
                    "ALBUMARTIST" => &mut self.album_artist,
                    "ALBUM" => &mut self.album,
                    "TRACK" | "TRACKNUMBER" => {
                        if self.track.is_none() {
                            self.track = values.into_iter().next();
                        }
                        return;
                    }
                    _ => return,
                };
                if slot.is_none() {
                    *slot = Some(values);
                }
            }
            // Binary: a cover is a file name, NUL, then the image.
            1 if with_cover && key == "COVERART(FRONT)" && self.cover.is_none() => {
                let image = match value.iter().position(|b| *b == 0) {
                    Some(nul) => &value[nul + 1..],
                    None => value,
                };
                if !image.is_empty() {
                    self.cover = Some(image.to_vec());
                }
            }
            _ => {}
        }
    }

    pub fn title(&self) -> Option<String> {
        first(&self.title)
    }

    pub fn artist(&self) -> Option<String> {
        joined(&self.artist)
    }

    pub fn album_artist(&self) -> Option<String> {
        joined(&self.album_artist)
    }

    pub fn album(&self) -> Option<String> {
        first(&self.album)
    }

    pub fn track_number(&self) -> Option<i64> {
        self.track.as_deref().and_then(track_number)
    }
}

/// Whether `head` opens a Monkey's Audio file.
pub fn claims_monkeys_audio(head: &[u8]) -> bool {
    head.starts_with(b"MAC ")
}

/// A Monkey's Audio file: its length from the header, its tags from the APE
/// tag at the end (or an ID3v1 tag after it).
pub fn read_monkeys_audio<R: Read + Seek>(
    source: &mut R,
    with_cover: bool,
) -> io::Result<Option<AudioTags>> {
    let length = source.seek(SeekFrom::End(0))?;
    source.seek(SeekFrom::Start(0))?;
    let head = read_up_to(source, 32)?;
    if head.len() < 32 {
        return Ok(None);
    }
    let version = u16::from_le_bytes([head[4], head[5]]);
    let (blocks_per_frame, final_blocks, total_frames, rate) = if version >= 3980 {
        // A descriptor first; the header follows at the size it gives.
        let header_at = u64::from(u32_le(&head, 8));
        source.seek(SeekFrom::Start(header_at))?;
        let header = read_up_to(source, 24)?;
        if header.len() < 24 {
            return Ok(None);
        }
        (
            u64::from(u32_le(&header, 4)),
            u64::from(u32_le(&header, 8)),
            u64::from(u32_le(&header, 12)),
            u64::from(u32_le(&header, 20)),
        )
    } else {
        let compression = u16::from_le_bytes([head[6], head[7]]);
        let blocks_per_frame = if version >= 3950 {
            73_728 * 4
        } else if version >= 3900 || (version >= 3800 && compression == 4000) {
            73_728
        } else {
            9_216
        };
        (
            blocks_per_frame,
            u64::from(u32_le(&head, 28)),
            u64::from(u32_le(&head, 24)),
            u64::from(u32_le(&head, 12)),
        )
    };
    let duration_micros = (total_frames > 0 && rate > 0)
        .then(|| {
            let samples = u128::from(total_frames - 1) * u128::from(blocks_per_frame)
                + u128::from(final_blocks);
            i64::try_from(samples * 1_000_000 / u128::from(rate)).ok()
        })
        .flatten();

    let v1 = super::mp3::id3v1(source, length)?;
    let end = length - if v1.is_some() { 128 } else { 0 };
    let ape = read_tag(source, end, with_cover)?.unwrap_or_default();
    let v1 = v1.unwrap_or_default();
    Ok(Some(AudioTags {
        title: ape.title().or(v1.title),
        artist: ape.artist().or(v1.artist),
        album_artist: ape.album_artist(),
        album: ape.album().or(v1.album),
        track_number: ape.track_number().or(v1.track),
        duration_micros: duration_micros.filter(|micros| *micros > 0),
        cover: ape.cover,
    }))
}
