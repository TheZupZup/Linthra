//! Ogg Vorbis and Opus: the identification and comment headers are the first
//! two packets of the first logical stream; the length comes from the last
//! page's granule position.

use std::io::{self, Read, Seek, SeekFrom};

use super::{dart, picture, read_up_to, u32_le, vorbis_comments, VorbisTags};

/// The largest a page can be: its 27-byte header, 255 lacing values, and 255
/// segments of 255 bytes.
const MAX_PAGE_BYTES: u64 = 27 + 255 + 255 * 255;

/// A bound on one header packet, so a lacing table that never closes its
/// packet can't read the whole file into memory.
const MAX_PACKET_BYTES: usize = 32 << 20;

/// Whether a page starts at `at` in `bytes`: `OggS`, then version 0 when the
/// bytes go that far.
pub fn is_page(bytes: &[u8], at: usize) -> bool {
    at + 4 <= bytes.len()
        && &bytes[at..at + 4] == b"OggS"
        && (at + 4 == bytes.len() || bytes[at + 4] == 0)
}

pub fn read<R: Read + Seek>(source: &mut R, with_cover: bool) -> io::Result<Option<VorbisTags>> {
    source.seek(SeekFrom::Start(0))?;
    let mut packets = Packets::new(source);
    let Some(identification) = packets.next()? else {
        return Ok(None);
    };

    // The comment header's prefix, the rate the granule counts in, and the
    // samples the stream opens with that are not part of the audio.
    let (prefix, rate, pre_skip): (&[u8], i64, i64) =
        if identification.starts_with(b"\x01vorbis") && identification.len() >= 30 {
            (b"\x03vorbis", i64::from(u32_le(&identification, 12)), 0)
        } else if identification.starts_with(b"OpusHead") && identification.len() >= 19 {
            let pre_skip = u16::from_le_bytes([identification[10], identification[11]]);
            (b"OpusTags", 48_000, i64::from(pre_skip))
        } else {
            return Ok(None);
        };

    let Some(comments) = packets.next()? else {
        return Ok(None);
    };
    if !comments.starts_with(prefix) {
        return Ok(None);
    }
    let block = &comments[prefix.len()..];
    let Some(fields) = vorbis_comments::parse(block, block.len() as u64, false) else {
        return Ok(None);
    };

    let cover = if with_cover {
        let pictures = fields
            .get("METADATA_BLOCK_PICTURE")
            .into_iter()
            .flatten()
            .filter_map(|value| picture::parse(&dart::base64_decode(dart::trim(value))?))
            .collect();
        picture::cover(pictures)
    } else {
        None
    };

    let serial = packets.serial.expect("a packet was read");
    let granule = last_granule(source, serial)?;
    // Wrapping, as Dart's 64-bit ints do, for a granule no real file has.
    let samples = granule.unwrap_or(0).wrapping_sub(pre_skip);
    let duration_micros = (rate > 0 && samples > 0).then(|| {
        (samples / rate)
            .wrapping_mul(1_000_000)
            .wrapping_add((samples % rate) * 1_000_000 / rate)
    });
    Ok(Some(VorbisTags {
        fields,
        duration_micros,
        cover,
    }))
}

/// The granule position of the last page of stream `serial` that has one,
/// found by reading the file's last page-length of bytes and looking back from
/// the end for a page whose checksum holds.
fn last_granule<R: Read + Seek>(source: &mut R, serial: u32) -> io::Result<Option<i64>> {
    let length = source.seek(SeekFrom::End(0))?;
    let start = length.saturating_sub(MAX_PAGE_BYTES);
    source.seek(SeekFrom::Start(start))?;
    let tail = read_up_to(source, length - start)?;
    if tail.len() < 27 {
        return Ok(None);
    }
    for at in (0..=tail.len() - 27).rev() {
        if !is_page(&tail, at) {
            continue;
        }
        let Some(end) = page_end(&tail, at) else {
            continue;
        };
        if !checksum_holds(&tail, at, end) || u32_le(&tail, at + 14) != serial {
            continue;
        }
        let granule = i64::from_le_bytes(tail[at + 6..at + 14].try_into().unwrap());
        // -1: no packet ends on this page, so it has no position of its own.
        if granule != -1 {
            return Ok(Some(granule));
        }
    }
    Ok(None)
}

/// Where the page starting at `at` ends, or `None` when it runs past `bytes`.
fn page_end(bytes: &[u8], at: usize) -> Option<usize> {
    if at + 27 > bytes.len() {
        return None;
    }
    let segments = usize::from(bytes[at + 26]);
    if at + 27 + segments > bytes.len() {
        return None;
    }
    let end = at
        + 27
        + segments
        + bytes[at + 27..at + 27 + segments]
            .iter()
            .map(|b| usize::from(*b))
            .sum::<usize>();
    (end <= bytes.len()).then_some(end)
}

/// Whether the page from `start` to `end` carries its own checksum: what tells
/// a page from the bytes `OggS` turning up in audio data.
fn checksum_holds(bytes: &[u8], start: usize, end: usize) -> bool {
    let mut crc: u32 = 0;
    for (i, &byte) in bytes[start..end].iter().enumerate() {
        // The checksum field itself counts as zeros.
        let byte = if (22..26).contains(&i) { 0 } else { byte };
        crc = (crc << 8) ^ CRC_TABLE[usize::from((crc >> 24) as u8 ^ byte)];
    }
    crc == u32_le(bytes, start + 22)
}

const CRC_TABLE: [u32; 256] = {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = (i as u32) << 24;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ 0x04C1_1DB7
            } else {
                crc << 1
            };
            bit += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
};

/// The packets of the first logical stream, reassembled page by page: a packet
/// is a run of 255-byte segments closed by a shorter one, and runs on over the
/// next page when a page's lacing table ends on 255. Other streams' pages are
/// skipped.
struct Packets<'a, R> {
    source: &'a mut R,
    serial: Option<u32>,
    lacing: Vec<u8>,
    data: Vec<u8>,
    segment: usize,
    offset: usize,
}

impl<'a, R: Read> Packets<'a, R> {
    fn new(source: &'a mut R) -> Self {
        Self {
            source,
            serial: None,
            lacing: Vec::new(),
            data: Vec::new(),
            segment: 0,
            offset: 0,
        }
    }

    /// The next packet, or `None` when the file ends first or it grows past
    /// [MAX_PACKET_BYTES].
    fn next(&mut self) -> io::Result<Option<Vec<u8>>> {
        let mut packet = Vec::new();
        loop {
            if self.segment == self.lacing.len() {
                if !self.next_page()? {
                    return Ok(None);
                }
                continue;
            }
            let size = usize::from(self.lacing[self.segment]);
            self.segment += 1;
            packet.extend_from_slice(&self.data[self.offset..self.offset + size]);
            self.offset += size;
            if packet.len() > MAX_PACKET_BYTES {
                return Ok(None);
            }
            if size < 255 {
                return Ok(Some(packet));
            }
        }
    }

    fn next_page(&mut self) -> io::Result<bool> {
        loop {
            let header = read_up_to(self.source, 27)?;
            if header.len() < 27 || !is_page(&header, 0) {
                return Ok(false);
            }
            let lacing = read_up_to(self.source, u64::from(header[26]))?;
            if lacing.len() < usize::from(header[26]) {
                return Ok(false);
            }
            let size: u64 = lacing.iter().map(|b| u64::from(*b)).sum();
            let data = read_up_to(self.source, size)?;
            if (data.len() as u64) < size {
                return Ok(false);
            }
            let page_serial = u32_le(&header, 14);
            if *self.serial.get_or_insert(page_serial) != page_serial {
                continue;
            }
            self.lacing = lacing;
            self.data = data;
            self.segment = 0;
            self.offset = 0;
            return Ok(true);
        }
    }
}
