//! Audio CDs: what a drive's table of contents and CD-Text say, for
//! lib/core/services/optical/cd_toc_reading.dart, cd_text_reading.dart and
//! cd_disc_id.dart, where the reasoning lives.
//!
//! Every function refuses rather than repairs: a TOC that contradicts itself
//! has no tracks and no identity, and CD-Text that cannot be trusted is no
//! CD-Text. Integer arithmetic wraps like Dart's, so a drive answering with
//! absurd numbers gets the answer the Dart decoder gave.
//! `test/core/services/optical/` holds the fixture discs, and
//! `optical_random_input_test.dart` throws random ones at it.

/// Frames from the start of the lead-in to LBA 0 (`cdLeadInFrames`).
pub const LEAD_IN_FRAMES: i64 = 150;
/// The gap between a CD-Extra's audio and data sessions (`cdXaInterval`).
pub const XA_INTERVAL: i64 = (60 + 90 + 2) * 75;

/// One TOC entry as the drive reported it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TocEntry {
    pub number: i64,
    pub start_lba: i64,
    pub is_data: bool,
}

/// A drive's table of contents.
pub struct Toc<'a> {
    pub first_track: i64,
    pub last_track: i64,
    pub lead_out_lba: i64,
    pub entries: &'a [TocEntry],
}

/// One playable audio track, in frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioTrack {
    pub number: i64,
    pub start_frame: i64,
    pub frame_count: i64,
}

/// `normalizedTocEntries`: the positions of `toc.entries` in track order, or
/// None when the TOC contradicts itself (numbers outside the header's range,
/// a duplicate or a gap, a negative position, starts going backwards, or a
/// lead-out that is not past the last start).
pub fn normalized_entries(toc: &Toc) -> Option<Vec<usize>> {
    if toc.first_track < 1 || toc.last_track > 99 || toc.first_track > toc.last_track {
        return None;
    }
    if toc.lead_out_lba < 0 {
        return None;
    }
    let mut by_number: Vec<Option<usize>> = vec![None; 100];
    for (i, entry) in toc.entries.iter().enumerate() {
        if entry.number < toc.first_track || entry.number > toc.last_track {
            return None;
        }
        if entry.start_lba < 0 {
            return None;
        }
        let slot = &mut by_number[entry.number as usize];
        if slot.is_some() {
            return None;
        }
        *slot = Some(i);
    }
    let ordered: Vec<usize> = by_number.into_iter().flatten().collect();
    if ordered.len() as i64 != toc.last_track - toc.first_track + 1 {
        return None;
    }
    let start = |i: usize| toc.entries[i].start_lba;
    if ordered.windows(2).any(|w| start(w[1]) < start(w[0])) {
        return None;
    }
    if toc.lead_out_lba <= start(*ordered.last()?) {
        return None;
    }
    Some(ordered)
}

/// `playableAudioTracks`: the audio tracks of `entries` (already in order),
/// each running to the next start, or for the last audio track before a data
/// session, to that session's start less [XA_INTERVAL]. A track with no
/// frames is left out.
pub fn playable_tracks(entries: &[TocEntry], lead_out_lba: i64) -> Vec<AudioTrack> {
    let Some(last_audio) = entries.iter().rev().find(|e| !e.is_data).map(|e| e.number) else {
        return Vec::new();
    };
    let mut tracks = Vec::new();
    for (i, entry) in entries.iter().enumerate() {
        if entry.is_data {
            continue;
        }
        let end_lba = match entries.get(i + 1) {
            None => lead_out_lba,
            Some(next) if next.is_data && entry.number == last_audio => {
                next.start_lba.wrapping_sub(XA_INTERVAL)
            }
            Some(next) => next.start_lba,
        };
        let frame_count = end_lba.wrapping_sub(entry.start_lba);
        if frame_count <= 0 {
            continue;
        }
        tracks.push(AudioTrack {
            number: entry.number,
            start_frame: entry.start_lba.wrapping_add(LEAD_IN_FRAMES),
            frame_count,
        });
    }
    tracks
}

/// `musicBrainzDiscId`: libdiscid's identifier, or None when the TOC cannot
/// produce one.
pub fn music_brainz_disc_id(toc: &Toc) -> Option<String> {
    let order = normalized_entries(toc)?;
    let entries: Vec<TocEntry> = order.iter().map(|&i| toc.entries[i]).collect();
    let last_audio_index = entries.iter().rposition(|e| !e.is_data)?;
    let last_audio_track = entries[last_audio_index].number;
    if last_audio_track < toc.first_track {
        return None;
    }
    let mut offsets = [0i64; 100];
    for entry in &entries {
        if entry.number > last_audio_track {
            continue;
        }
        offsets[entry.number as usize] = if entry.start_lba > 0 {
            entry.start_lba.wrapping_add(LEAD_IN_FRAMES)
        } else {
            LEAD_IN_FRAMES
        };
    }
    offsets[0] = match entries.get(last_audio_index + 1) {
        None => toc.lead_out_lba.wrapping_add(LEAD_IN_FRAMES),
        Some(next) => next
            .start_lba
            .wrapping_sub(XA_INTERVAL)
            .wrapping_add(LEAD_IN_FRAMES),
    };
    if offsets[0] <= offsets[last_audio_track as usize] {
        return None;
    }
    let mut input = format!("{}{}", hex(toc.first_track, 2), hex(last_audio_track, 2));
    for offset in offsets {
        input.push_str(&hex(offset, 8));
    }
    let encoded = base64(&sha1(input.as_bytes()));
    Some(
        encoded
            .chars()
            .map(|c| match c {
                '+' => '.',
                '/' => '_',
                '=' => '-',
                c => c,
            })
            .collect(),
    )
}

/// `value.toRadixString(16).toUpperCase().padLeft(width, '0')`. Every value
/// that reaches it is positive, but a negative one would read like Dart's.
fn hex(value: i64, width: usize) -> String {
    let digits = if value < 0 {
        format!("-{:X}", value.unsigned_abs())
    } else {
        format!("{value:X}")
    };
    format!("{digits:0>width$}")
}

/// SHA-1, for the disc id: a few dozen lines instead of a dependency.
pub fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64).wrapping_mul(8)).to_be_bytes());
    for chunk in message.as_chunks::<64>().0 {
        let mut w = [0u32; 80];
        for (i, word) in chunk.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(*word);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, &word) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A827999),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }
        for (slot, value) in h.iter_mut().zip([a, b, c, d, e]) {
            *slot = slot.wrapping_add(value);
        }
    }
    let mut digest = [0u8; 20];
    for (i, word) in h.iter().enumerate() {
        digest[4 * i..4 * i + 4].copy_from_slice(&word.to_be_bytes());
    }
    digest
}

/// Standard base64 with `=` padding.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        for k in 0..4 {
            if k <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * k)) as usize & 63] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// CD-Text title and performer pack types.
const TITLE_PACK: u8 = 0x80;
const PERFORMER_PACK: u8 = 0x81;
const BLOCK_SIZE_PACK: u8 = 0x8f;
const PACK_LENGTH: usize = 18;
const CHARSET_ISO_8859_1: u8 = 0x00;
const CHARSET_ASCII: u8 = 0x01;
const REPEAT_MARKER: u8 = 0x09;
const MAX_PACKS: usize = 2048;

/// The CD-Text a disc carries: titles and performers by item (0 the disc,
/// 1-99 the tracks) in item order, each text as its Latin-1 bytes (every
/// byte is the code point of the same number).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct CdText {
    pub titles: Vec<(u32, Vec<u8>)>,
    pub performers: Vec<(u32, Vec<u8>)>,
}

struct Pack<'a> {
    kind: u8,
    item: u8,
    sequence: u8,
    character_position: u8,
    payload: &'a [u8],
}

/// `cdTextFrom`: None for no CD-Text, or for CD-Text that cannot be trusted
/// (see the Dart docs for every reason).
pub fn cd_text(response: &[u8]) -> Option<CdText> {
    let packs = packs(response)?;
    let charset = packs
        .iter()
        .find(|p| p.kind == BLOCK_SIZE_PACK && p.item == 0)
        .map_or(CHARSET_ISO_8859_1, |p| p.payload[0]);
    if charset != CHARSET_ISO_8859_1 && charset != CHARSET_ASCII {
        return None;
    }
    let titles = texts(&packs, TITLE_PACK, charset)?;
    let performers = texts(&packs, PERFORMER_PACK, charset)?;
    let text = CdText { titles, performers };
    (!text.titles.is_empty() || !text.performers.is_empty()).then_some(text)
}

/// `_packsFrom`: block 0's packs in sequence order.
fn packs(response: &[u8]) -> Option<Vec<Pack<'_>>> {
    if response.len() < 4 {
        return None;
    }
    let declared = ((response[0] as usize) << 8) | response[1] as usize;
    let end = (declared + 2).min(response.len());
    let payload = end.checked_sub(4).filter(|&n| n > 0)?;
    if payload % PACK_LENGTH != 0 || payload / PACK_LENGTH > MAX_PACKS {
        return None;
    }
    let mut packs = Vec::new();
    for bytes in response[4..end].as_chunks::<PACK_LENGTH>().0 {
        let indicator = bytes[3];
        if (indicator >> 4) & 0x07 != 0 {
            continue;
        }
        if !crc_matches(bytes) || indicator & 0x80 != 0 {
            return None;
        }
        packs.push(Pack {
            kind: bytes[0],
            item: bytes[1],
            sequence: bytes[2],
            character_position: indicator & 0x0f,
            payload: &bytes[4..16],
        });
    }
    if packs.is_empty() {
        return None;
    }
    packs.sort_by_key(|p| p.sequence);
    // A gap (or a repeat) means a pack went missing. Sequence numbers are
    // bytes, but Dart compares them as ints, so 255 is never followed by 0.
    if packs
        .windows(2)
        .any(|w| w[1].sequence as u32 != w[0].sequence as u32 + 1)
    {
        return None;
    }
    Some(packs)
}

/// `_textsFor`: one pack type's strings by item, or None when a pack's
/// header contradicts where the stream puts it.
fn texts(packs: &[Pack], kind: u8, charset: u8) -> Option<Vec<(u32, Vec<u8>)>> {
    let of_kind: Vec<&Pack> = packs.iter().filter(|p| p.kind == kind).collect();
    let Some(first) = of_kind.first() else {
        return Some(Vec::new());
    };
    let mut texts = Vec::new();
    let mut item = first.item as u32;
    let mut previous: Option<Vec<u8>> = None;
    let mut buffer: Vec<u8> = Vec::new();
    for pack in of_kind {
        if pack.item as u32 != item {
            return None;
        }
        if pack.character_position as usize != buffer.len().min(15) {
            return None;
        }
        for &byte in pack.payload {
            if byte != 0 {
                buffer.push(byte);
                continue;
            }
            if item > 99 {
                return Some(texts);
            }
            let text = decode(&buffer, charset, previous.as_deref());
            match text {
                Some(text) if !text.is_empty() => {
                    texts.push((item, text.clone()));
                    previous = Some(text);
                }
                _ => previous = None,
            }
            buffer.clear();
            item += 1;
        }
    }
    Some(texts)
}

/// `_decode`: the text's Latin-1 bytes, trimmed as Dart's `trim` trims, the
/// repeat marker resolved. None for an ASCII block carrying a high byte.
fn decode(bytes: &[u8], charset: u8, previous: Option<&[u8]>) -> Option<Vec<u8>> {
    if bytes == [REPEAT_MARKER] {
        return previous.map(<[u8]>::to_vec);
    }
    if bytes.is_empty() {
        return None;
    }
    if charset == CHARSET_ASCII && bytes.iter().any(|&b| b > 0x7f) {
        return None;
    }
    // Dart's `trim` whitespace, among the first 256 code points.
    let space = |b: &u8| matches!(b, 0x09..=0x0D | 0x20 | 0x85 | 0xA0);
    let start = bytes.iter().position(|b| !space(b)).unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|b| !space(b))
        .map_or(start, |i| i + 1);
    Some(bytes[start..end].to_vec())
}

fn crc_matches(pack: &[u8]) -> bool {
    let stored = ((pack[16] as u16) << 8) | pack[17] as u16;
    stored == 0 || stored == pack_crc(pack)
}

/// `cdTextPackCrc`: CRC-16/CCITT over the first sixteen bytes, inverted.
pub fn pack_crc(pack: &[u8]) -> u16 {
    let mut crc: u16 = 0;
    for &byte in &pack[..16] {
        crc ^= (byte as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc ^ 0xffff
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_matches_the_reference_vectors() {
        let hex = |d: [u8; 20]| d.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(hex(sha1(b"")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(
            hex(sha1(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert_eq!(
            hex(sha1(
                b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            )),
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        );
    }

    #[test]
    fn base64_pads_like_dart() {
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
    }

    #[test]
    fn refuses_a_toc_with_a_gap() {
        let entries = [
            TocEntry {
                number: 1,
                start_lba: 0,
                is_data: false,
            },
            TocEntry {
                number: 3,
                start_lba: 900,
                is_data: false,
            },
        ];
        let toc = Toc {
            first_track: 1,
            last_track: 3,
            lead_out_lba: 2000,
            entries: &entries,
        };
        assert_eq!(normalized_entries(&toc), None);
        assert_eq!(music_brainz_disc_id(&toc), None);
    }

    #[test]
    fn hex_reads_like_dart() {
        assert_eq!(hex(1, 2), "01");
        assert_eq!(hex(0x1A2B, 8), "00001A2B");
        assert_eq!(hex(0x1_0000_0000, 8), "100000000");
        assert_eq!(hex(-31, 8), "00000-1F");
    }
}
