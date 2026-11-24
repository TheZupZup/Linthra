//! FLAC: `fLaC`, then metadata blocks, each a header byte (the top bit marks
//! the last block, the low seven its type), a 24-bit big-endian length, then
//! that many bytes.

use std::io::{self, Read, Seek, SeekFrom};

use super::{picture, read_up_to, vorbis_comments, VorbisTags};

const STREAM_INFO: u8 = 0;
const VORBIS_COMMENT: u8 = 4;
const PICTURE: u8 = 6;

pub fn is_flac(magic: &[u8]) -> bool {
    magic.starts_with(b"fLaC")
}

/// Walks the metadata blocks from just after the magic: STREAMINFO for the
/// length, VORBIS_COMMENT for the fields, and, when `with_cover`, PICTUREs
/// until the front cover. Everything else is seeked past; without a cover to
/// find, the walk stops at the comments.
pub fn read<R: Read + Seek>(source: &mut R, with_cover: bool) -> io::Result<Option<VorbisTags>> {
    let mut duration_micros = None;
    let mut fields = None;
    let mut cover: Option<picture::Picture> = None;
    loop {
        let header = read_up_to(source, 4)?;
        if header.len() < 4 {
            break; // cut short
        }
        let is_last = header[0] & 0x80 != 0;
        let kind = header[0] & 0x7F;
        let length =
            (u64::from(header[1]) << 16) | (u64::from(header[2]) << 8) | u64::from(header[3]);
        let next = source.stream_position()? + length;

        if kind == STREAM_INFO {
            duration_micros = stream_info_micros(&read_up_to(source, length)?);
        } else if kind == VORBIS_COMMENT {
            if fields.is_none() {
                let block = read_up_to(source, length)?;
                fields = vorbis_comments::parse(&block, length, true);
                if fields.is_none() {
                    return Ok(None);
                }
            }
            if !with_cover {
                break;
            }
        } else if kind == PICTURE
            && with_cover
            && cover.as_ref().map(|c| c.kind) != Some(picture::FRONT_COVER)
        {
            if let Some(found) = picture::parse(&read_up_to(source, length)?) {
                if cover.is_none() || found.kind == picture::FRONT_COVER {
                    cover = Some(found);
                }
            }
        }
        if is_last {
            break;
        }
        source.seek(SeekFrom::Start(next))?;
    }
    Ok(fields.map(|fields| VorbisTags {
        fields,
        duration_micros,
        cover: cover.map(|c| c.data),
    }))
}

/// The length a STREAMINFO block gives: total samples over the sample rate.
/// `None` for a block that isn't 34 bytes, or that doesn't know the length.
fn stream_info_micros(block: &[u8]) -> Option<i64> {
    if block.len() != 34 {
        return None;
    }
    // 20 bits of sample rate, 3 of channels, 5 of bits per sample, then 36
    // bits of total samples, from byte 10.
    let b = |i: usize| i64::from(block[10 + i]);
    let rate = (b(0) << 12) | (b(1) << 4) | (b(2) >> 4);
    let samples = ((b(3) & 0x0F) << 32) | (b(4) << 24) | (b(5) << 16) | (b(6) << 8) | b(7);
    if rate == 0 || samples == 0 {
        return None;
    }
    Some(samples * 1_000_000 / rate)
}
