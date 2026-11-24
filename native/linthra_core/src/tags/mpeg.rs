//! MPEG audio frames: finding the first one, and the stream's length from it.

use std::io::{self, Read, Seek, SeekFrom};

use super::{read_up_to, u32_be};

/// How far past the tag the first frame is looked for. Real files start
/// their audio within a few kilobytes; this only has to stop a scan of a big
/// file that isn't MPEG audio at all.
const SEARCH_LIMIT: u64 = 1 << 20;

/// One frame header's facts.
#[derive(Clone, Copy, Debug)]
pub struct Frame {
    /// Where the frame starts in the file.
    pub offset: u64,
    /// 1, 2, or 25 for MPEG 2.5.
    version: u8,
    layer: u8,
    bitrate: Option<u32>,
    sample_rate: u32,
    mono: bool,
}

/// Whether `header` is a frame header: the sync bits, then no reserved
/// version, layer, sample rate or emphasis, and neither a free nor a bad
/// bitrate.
pub fn is_header(header: &[u8]) -> bool {
    header.len() >= 4
        && header[0] == 0xFF
        && header[1] & 0xE0 == 0xE0
        && (header[1] >> 3) & 0x03 != 0x01
        && (header[1] >> 1) & 0x03 != 0x00
        && header[2] >> 4 != 0x0
        && header[2] >> 4 != 0xF
        && (header[2] >> 2) & 0x03 != 0x03
        && header[3] & 0x03 != 0x02
}

fn frame_at(header: &[u8], offset: u64) -> Option<Frame> {
    if !is_header(header) {
        return None;
    }
    let version = match (header[1] >> 3) & 0x03 {
        0 => 25,
        2 => 2,
        _ => 1,
    };
    let layer = 4 - ((header[1] >> 1) & 0x03);
    let rates: [u32; 3] = match version {
        1 => [44_100, 48_000, 32_000],
        2 => [22_050, 24_000, 16_000],
        _ => [11_025, 12_000, 8_000],
    };
    Some(Frame {
        offset,
        version,
        layer,
        bitrate: bitrate(version, layer, header[2] >> 4),
        sample_rate: rates[usize::from((header[2] >> 2) & 0x03)],
        mono: header[3] >> 6 == 0x03,
    })
}

/// Bits per second for a bitrate index, by the spec's tables.
fn bitrate(version: u8, layer: u8, index: u8) -> Option<u32> {
    const V1_L1: [u32; 14] = [
        32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
    ];
    const V1_L2: [u32; 14] = [
        32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
    ];
    const V1_L3: [u32; 14] = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ];
    const V2_L1: [u32; 14] = [
        32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
    ];
    const V2_L23: [u32; 14] = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    let table = match (version, layer) {
        (1, 1) => &V1_L1,
        (1, 2) => &V1_L2,
        (1, _) => &V1_L3,
        (_, 1) => &V2_L1,
        _ => &V2_L23,
    };
    table
        .get(usize::from(index).checked_sub(1)?)
        .map(|kbps| kbps * 1000)
}

/// The first frame at or after `start`, within [SEARCH_LIMIT].
pub fn first_frame<R: Read + Seek>(source: &mut R, start: u64) -> io::Result<Option<Frame>> {
    source.seek(SeekFrom::Start(start))?;
    let bytes = read_up_to(source, SEARCH_LIMIT)?;
    Ok((0..bytes.len().saturating_sub(3)).find_map(|i| {
        (bytes[i] == 0xFF)
            .then(|| frame_at(&bytes[i..i + 4], start + i as u64))
            .flatten()
    }))
}

impl Frame {
    fn samples_per_frame(&self) -> u64 {
        match (self.layer, self.version) {
            (1, _) => 384,
            (2, _) | (3, 1) => 1152,
            _ => 576,
        }
    }

    /// The stream's length in microseconds: from the frame count in a Xing,
    /// Info or VBRI header when this frame carries one, else from
    /// `length_ms` (the tag's TLEN), else from the audio's size over the
    /// bitrate, which is exact for constant-bitrate files.
    pub fn duration_micros<R: Read + Seek>(
        &self,
        source: &mut R,
        audio_end: u64,
        length_ms: Option<i64>,
    ) -> io::Result<Option<i64>> {
        source.seek(SeekFrom::Start(self.offset))?;
        let head = read_up_to(source, 64)?;
        let side_info = match (self.version, self.mono) {
            (1, true) => 17,
            (1, false) => 32,
            (_, true) => 9,
            (_, false) => 17,
        };
        let xing = 4 + side_info;
        let frames = if matches!(head.get(xing..xing + 4), Some(b"Xing" | b"Info"))
            && head.len() >= xing + 12
            && u32_be(&head, xing + 4) & 0x01 != 0
        {
            Some(u32_be(&head, xing + 8))
        } else if head.get(36..40) == Some(b"VBRI") && head.len() >= 54 {
            Some(u32_be(&head, 50))
        } else {
            None
        };
        if let Some(frames) = frames.filter(|f| *f > 0) {
            let micros = u128::from(frames) * u128::from(self.samples_per_frame()) * 1_000_000
                / u128::from(self.sample_rate);
            return Ok(i64::try_from(micros).ok());
        }
        if let Some(ms) = length_ms.filter(|ms| *ms > 0) {
            return Ok(ms.checked_mul(1000));
        }
        let Some(bitrate) = self.bitrate else {
            return Ok(None);
        };
        let bytes = audio_end.saturating_sub(self.offset);
        Ok(i64::try_from(u128::from(bytes) * 8 * 1_000_000 / u128::from(bitrate)).ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_header() {
        let frame = frame_at(&[0xFF, 0xFB, 0x90, 0x00], 7).unwrap();
        assert_eq!((frame.version, frame.layer), (1, 3));
        assert_eq!(frame.bitrate, Some(128_000));
        assert_eq!(frame.sample_rate, 44_100);
        assert_eq!(frame.offset, 7);
    }

    #[test]
    fn refuses_reserved_fields() {
        assert!(!is_header(&[0xFF, 0xEB, 0x90, 0x00])); // reserved version
        assert!(!is_header(&[0xFF, 0xF9, 0x90, 0x00])); // reserved layer
        assert!(!is_header(&[0xFF, 0xFB, 0xF0, 0x00])); // bad bitrate
        assert!(!is_header(&[0xFF, 0xFB, 0x00, 0x00])); // free bitrate
        assert!(!is_header(&[0xFF, 0xFB, 0x9C, 0x00])); // reserved rate
        assert!(!is_header(&[0xFF, 0xFB, 0x90, 0x02])); // reserved emphasis
        assert!(!is_header(&[0xFF, 0xFB, 0x90]));
    }

    #[test]
    fn mpeg_2_5_has_its_own_rates_and_bitrates() {
        let frame = frame_at(&[0xFF, 0xE3, 0x80, 0x00], 0).unwrap();
        assert_eq!(frame.version, 25);
        assert_eq!(frame.sample_rate, 11_025);
        assert_eq!(frame.bitrate, Some(64_000));
        assert_eq!(frame.samples_per_frame(), 576);
    }
}
