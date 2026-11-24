//! Reads the tags of FLAC, Ogg Vorbis, Opus and MP3 files: title, artists,
//! album, track number, length and cover.
//!
//! MP3 follows the ID3v2, ID3v1 and MPEG audio specs ([mp3]), held to
//! `test/fixtures/tags/mp3_cases.txt`. FLAC, Ogg and Opus give the same reading
//! as the Dart one that follows the spec
//! (`lib/core/sources/local/vorbis_tags_in_the_clear.dart` plus
//! `FilesystemLocalMetadataReader.vorbisMetadata`), and held to it by the
//! files and expectations in `test/fixtures/tags/`. Where Rust and Dart differ
//! by default (what `trim` removes, what `\s` matches, upper-casing, base64),
//! this follows Dart, in [dart].
//!
//! Total about what the file holds: anything that isn't one of these formats,
//! or whose comments don't hold together, reads as `None`. Not about reading
//! it: an I/O error is returned, never read around, since a read that could
//! not finish says nothing about the tags.

mod dart;
mod flac;
mod id3v2;
mod mp3;
mod mpeg;
mod ogg;
mod picture;
#[cfg(test)]
mod shared_cases_test;
mod vorbis_comments;

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

/// Comments keyed by upper-cased field name, values in file order.
pub type Fields = HashMap<String, Vec<String>>;

/// What a file's tags say. Every field is `None` when the file has no usable
/// value for it: blank text and a zero track number or length count as none.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AudioTags {
    pub title: Option<String>,
    /// Every ARTIST, joined with ", ": a repeated field is a joint credit.
    pub artist: Option<String>,
    /// Every ALBUMARTIST (or ALBUM_ARTIST when there is none), joined.
    pub album_artist: Option<String>,
    pub album: Option<String>,
    pub track_number: Option<i64>,
    pub duration_micros: Option<i64>,
    /// The front cover, or the first picture when none is marked as one.
    pub cover: Option<Vec<u8>>,
}

/// The raw read, before the fields become [AudioTags].
struct VorbisTags {
    fields: Fields,
    duration_micros: Option<i64>,
    cover: Option<Vec<u8>>,
}

/// Reads the file at `path`. The cover is only looked for when `with_cover`.
pub fn read_file(path: &Path, with_cover: bool) -> io::Result<Option<AudioTags>> {
    read(&mut File::open(path)?, with_cover)
}

/// Reads tags from `source`, from its start.
pub fn read<R: Read + Seek>(source: &mut R, with_cover: bool) -> io::Result<Option<AudioTags>> {
    source.seek(SeekFrom::Start(0))?;
    let magic = read_up_to(source, 4)?;
    if flac::is_flac(&magic) {
        return Ok(flac::read(source, with_cover)?.map(AudioTags::from_vorbis));
    }
    if ogg::is_page(&magic, 0) {
        return Ok(ogg::read(source, with_cover)?.map(AudioTags::from_vorbis));
    }
    if mp3::claims(&magic) {
        return mp3::read(source, with_cover);
    }
    Ok(None)
}

impl AudioTags {
    fn from_vorbis(raw: VorbisTags) -> Self {
        let fields = &raw.fields;
        let artists = non_blank(fields.get("ARTIST"));
        let mut album_artists = non_blank(fields.get("ALBUMARTIST"));
        if album_artists.is_empty() {
            album_artists = non_blank(fields.get("ALBUM_ARTIST"));
        }
        let joined = |values: Vec<String>| (!values.is_empty()).then(|| values.join(", "));
        AudioTags {
            title: non_blank(fields.get("TITLE")).into_iter().next(),
            artist: joined(artists),
            album_artist: joined(album_artists),
            album: non_blank(fields.get("ALBUM")).into_iter().next(),
            track_number: fields
                .get("TRACKNUMBER")
                .and_then(|values| values.first())
                .and_then(|value| dart::leading_number(value))
                .filter(|number| *number > 0),
            duration_micros: raw.duration_micros.filter(|micros| *micros > 0),
            cover: raw.cover,
        }
    }
}

/// The values, trimmed the way Dart trims, with the blank ones left out.
fn non_blank(values: Option<&Vec<String>>) -> Vec<String> {
    values
        .into_iter()
        .flatten()
        .map(|value| dart::trim(value))
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Up to `n` bytes from `source`: fewer only at the end of the file.
fn read_up_to<R: Read>(source: &mut R, n: u64) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    source.take(n).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn u32_le(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn u32_be(bytes: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}
