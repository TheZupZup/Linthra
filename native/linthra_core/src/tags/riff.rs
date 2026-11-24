//! WAV (RIFF/WAVE) and AIFF (AIFF and AIFF-C): chunked files, little-endian
//! for RIFF and big-endian for AIFF, each chunk padded to an even length.
//!
//! Tags come from an embedded ID3v2 tag (the `id3 ` chunk taggers such as
//! Mp3tag and foobar2000 write) and else from the format's own text chunks:
//! RIFF's LIST/INFO, AIFF's NAME and AUTH. The length is WAV's audio bytes
//! over its byte rate, or AIFF's sample frames over its sample rate.

use std::io::{self, Read, Seek, SeekFrom};

use super::id3v2::{self, Id3v2};
use super::{
    dart, first, joined, picture, read_up_to, track_number, u32_be, u32_le, utf8_or_latin1,
    AudioTags,
};

/// The largest chunk read into memory for its tags.
const MAX_CHUNK_BYTES: u64 = 64 << 20;

/// The most chunks walked: every one moves the walk at least 8 bytes on, so
/// this only caps a file made of tiny chunks.
const MAX_CHUNKS: usize = 1 << 16;

pub fn claims_wav(head: &[u8]) -> bool {
    head.starts_with(b"RIFF") && head.get(8..12) == Some(b"WAVE")
}

pub fn claims_aiff(head: &[u8]) -> bool {
    head.starts_with(b"FORM") && matches!(head.get(8..12), Some(b"AIFF" | b"AIFC"))
}

/// What a walk over the chunks found.
#[derive(Default)]
struct Found {
    id3: Option<Id3v2>,
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    track: Option<i64>,
    duration_micros: Option<i64>,
}

pub fn read_wav<R: Read + Seek>(source: &mut R, with_cover: bool) -> io::Result<Option<AudioTags>> {
    let mut found = Found::default();
    let mut byte_rate = 0u64;
    let mut data_bytes = None;
    walk(source, false, |kind, payload_at, available, source| {
        match kind {
            b"fmt " => {
                let format = read_at(source, payload_at, available.min(16))?;
                if format.len() >= 12 {
                    byte_rate = u64::from(u32_le(&format, 8));
                }
            }
            b"data" => data_bytes = Some(available),
            b"LIST" => {
                let list = read_at(source, payload_at, available.min(MAX_CHUNK_BYTES))?;
                if list.starts_with(b"INFO") {
                    read_info(&list[4..], &mut found);
                }
            }
            b"id3 " | b"ID3 " => found.read_id3(source, payload_at, available, with_cover)?,
            _ => {}
        }
        Ok(())
    })?;
    if let Some(bytes) = data_bytes.filter(|_| byte_rate > 0) {
        found.duration_micros =
            i64::try_from(u128::from(bytes) * 1_000_000 / u128::from(byte_rate)).ok();
    }
    Ok(Some(found.into_tags()))
}

pub fn read_aiff<R: Read + Seek>(
    source: &mut R,
    with_cover: bool,
) -> io::Result<Option<AudioTags>> {
    let mut found = Found::default();
    walk(source, true, |kind, payload_at, available, source| {
        match kind {
            b"COMM" => {
                let comm = read_at(source, payload_at, available.min(18))?;
                if comm.len() >= 18 {
                    let frames = u32_be(&comm, 2);
                    let rate = extended80(&comm[8..18]);
                    if rate > 0.0 && rate.is_finite() {
                        found.duration_micros =
                            Some((f64::from(frames) * 1_000_000.0 / rate).round() as i64);
                    }
                }
            }
            b"NAME" => {
                found.title = text(&read_at(
                    source,
                    payload_at,
                    available.min(MAX_CHUNK_BYTES),
                )?)
            }
            b"AUTH" => {
                found.artist = text(&read_at(
                    source,
                    payload_at,
                    available.min(MAX_CHUNK_BYTES),
                )?)
            }
            b"ID3 " | b"id3 " => found.read_id3(source, payload_at, available, with_cover)?,
            _ => {}
        }
        Ok(())
    })?;
    Ok(Some(found.into_tags()))
}

/// Calls `visit` with each chunk after the 12-byte file header: its type,
/// where its payload starts, and how much of its payload the file holds.
fn walk<R: Read + Seek>(
    source: &mut R,
    big_endian: bool,
    mut visit: impl FnMut(&[u8; 4], u64, u64, &mut R) -> io::Result<()>,
) -> io::Result<()> {
    let length = source.seek(SeekFrom::End(0))?;
    let mut at = 12u64;
    for _ in 0..MAX_CHUNKS {
        if at + 8 > length {
            break;
        }
        let header = read_at(source, at, 8)?;
        let kind = [header[0], header[1], header[2], header[3]];
        let size = u64::from(if big_endian {
            u32_be(&header, 4)
        } else {
            u32_le(&header, 4)
        });
        let payload_at = at + 8;
        let available = size.min(length - payload_at);
        visit(&kind, payload_at, available, source)?;
        at = payload_at + size + (size & 1);
    }
    Ok(())
}

impl Found {
    /// An embedded ID3v2 tag. The first one wins.
    fn read_id3<R: Read + Seek>(
        &mut self,
        source: &mut R,
        at: u64,
        available: u64,
        with_cover: bool,
    ) -> io::Result<()> {
        if self.id3.is_some() {
            return Ok(());
        }
        let bytes = read_at(source, at, available.min(MAX_CHUNK_BYTES))?;
        if bytes.len() >= 10
            && bytes.starts_with(b"ID3")
            && (2..=4).contains(&bytes[3])
            && bytes[6..10].iter().all(|b| b & 0x80 == 0)
        {
            let size = id3v2::synchsafe(&bytes[6..10]) as usize;
            let body = &bytes[10..bytes.len().min(10 + size)];
            self.id3 = Some(id3v2::parse(bytes[3], bytes[5], body, with_cover));
        }
        Ok(())
    }

    /// The ID3v2 tag's fields, else the format's own.
    fn into_tags(self) -> AudioTags {
        let id3 = self.id3.unwrap_or_default();
        let id3_track = id3
            .track
            .as_ref()
            .and_then(|values| values.first())
            .and_then(|value| track_number(value));
        AudioTags {
            title: first(&id3.title).or(self.title),
            artist: joined(&id3.artist).or(self.artist),
            album_artist: joined(&id3.album_artist),
            album: first(&id3.album).or(self.album),
            track_number: id3_track.or(self.track),
            duration_micros: self.duration_micros.filter(|micros| *micros > 0),
            cover: picture::cover(id3.pictures),
        }
    }
}

/// RIFF's INFO list: sub-chunks of NUL-terminated text, each padded to an
/// even length. INAM is the title, IART the artist, IPRD the album, and
/// ITRK (or IPRT) the track.
fn read_info(mut list: &[u8], found: &mut Found) {
    while list.len() >= 8 {
        let kind = &list[..4];
        let size = u32_le(list, 4) as usize;
        let Some(value) = list.get(8..8 + size) else {
            break;
        };
        let value = text(value);
        match kind {
            b"INAM" => found.title = found.title.take().or(value),
            b"IART" => found.artist = found.artist.take().or(value),
            b"IPRD" => found.album = found.album.take().or(value),
            b"ITRK" | b"IPRT" => {
                found.track = found
                    .track
                    .or_else(|| value.as_deref().and_then(track_number));
            }
            _ => {}
        }
        list = list.get(8 + size + (size & 1)..).unwrap_or_default();
    }
}

/// A text chunk's value: NULs dropped, UTF-8 or else Latin-1, trimmed; none
/// when blank.
fn text(bytes: &[u8]) -> Option<String> {
    let bytes: Vec<u8> = bytes.iter().copied().filter(|b| *b != 0).collect();
    let text = utf8_or_latin1(&bytes);
    let text = dart::trim(&text);
    (!text.is_empty()).then(|| text.to_owned())
}

/// An IEEE 754 80-bit extended float, as AIFF writes its sample rate: a sign
/// and 15-bit exponent, then a 64-bit mantissa with its integer bit.
fn extended80(bytes: &[u8]) -> f64 {
    let exponent = i32::from(u16::from_be_bytes([bytes[0], bytes[1]]) & 0x7FFF);
    let mantissa = u64::from_be_bytes(bytes[2..10].try_into().unwrap());
    if exponent == 0 && mantissa == 0 {
        return 0.0;
    }
    let value = mantissa as f64 * 2f64.powi(exponent - 16_383 - 63);
    if bytes[0] & 0x80 != 0 {
        -value
    } else {
        value
    }
}

fn read_at<R: Read + Seek>(source: &mut R, at: u64, n: u64) -> io::Result<Vec<u8>> {
    source.seek(SeekFrom::Start(at))?;
    read_up_to(source, n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_80_bit_sample_rates() {
        // 44100 and 48000 as AIFF writers store them.
        assert_eq!(
            extended80(&[0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]),
            44_100.0
        );
        assert_eq!(
            extended80(&[0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0]),
            48_000.0
        );
        assert_eq!(extended80(&[0; 10]), 0.0);
    }

    #[test]
    fn info_text_drops_nuls_and_falls_back_to_latin1() {
        assert_eq!(text(b"Caf\xe9\0").as_deref(), Some("Café"));
        assert_eq!(text(b" \0 ").as_deref(), None);
    }
}
