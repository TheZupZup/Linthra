//! MP3: an ID3v2 tag at the start, MPEG audio frames, and maybe an ID3v1 tag
//! in the last 128 bytes.
//!
//! A file is read as MP3 when it opens with an ID3v2 tag or with an MPEG
//! frame. One that carries an APE tag, or whose ID3v2 tag sits in front of a
//! FLAC or Ogg stream, is left to the reader that handles those.

use std::io::{self, Read, Seek, SeekFrom};

use super::{dart, id3v2, mpeg, picture, read_up_to, AudioTags};

/// Whether `head` (a file's first bytes) opens like an MP3.
pub fn claims(head: &[u8]) -> bool {
    head.starts_with(b"ID3") || mpeg::is_header(head)
}

pub fn read<R: Read + Seek>(source: &mut R, with_cover: bool) -> io::Result<Option<AudioTags>> {
    let length = source.seek(SeekFrom::End(0))?;
    let v1 = id3v1(source, length)?;
    let audio_end = length - if v1.is_some() { 128 } else { 0 };
    if has_ape_tag(source, audio_end)? {
        return Ok(None);
    }

    source.seek(SeekFrom::Start(0))?;
    let head = read_up_to(source, 10)?;
    let mut tag = None;
    let mut audio_start = 0;
    if head.starts_with(b"ID3") {
        if head.len() < 10
            || !(2..=4).contains(&head[3])
            || head[6..10].iter().any(|b| b & 0x80 != 0)
        {
            return Ok(None);
        }
        let size = u64::from(id3v2::synchsafe(&head[6..10]));
        let footer = if head[3] == 4 && head[5] & 0x10 != 0 {
            10
        } else {
            0
        };
        let body = read_up_to(source, size)?;
        tag = Some(id3v2::parse(head[3], head[5], &body, with_cover));
        audio_start = skip_appended_tags(source, 10 + size + footer, length)?;
        source.seek(SeekFrom::Start(audio_start))?;
        let next = read_up_to(source, 4)?;
        if next.starts_with(b"fLaC") || next.starts_with(b"OggS") {
            return Ok(None);
        }
    }

    let frame = mpeg::first_frame(source, audio_start)?;
    // Without an ID3v2 tag, only a file whose first bytes are a frame is MP3.
    if tag.is_none() && frame.is_none_or(|f| f.offset != 0) {
        return Ok(None);
    }
    let tag = tag.unwrap_or_default();
    let length_ms = tag
        .length_ms
        .as_ref()
        .and_then(|values| values.first())
        .and_then(|value| dart::leading_number(value));
    let duration_micros = match frame {
        Some(frame) => frame.duration_micros(source, audio_end, length_ms)?,
        None => length_ms
            .filter(|ms| *ms > 0)
            .and_then(|ms| ms.checked_mul(1000)),
    };

    let v1 = v1.unwrap_or_default();
    let track = tag
        .track
        .as_ref()
        .and_then(|values| values.first())
        .and_then(|value| track_number(value))
        .or(v1.track);
    Ok(Some(AudioTags {
        title: first(&tag.title).or(v1.title),
        artist: joined(&tag.artist).or(v1.artist),
        album_artist: joined(&tag.album_artist),
        album: first(&tag.album).or(v1.album),
        track_number: track,
        duration_micros: duration_micros.filter(|micros| *micros > 0),
        cover: picture::cover(tag.pictures),
    }))
}

/// A TRCK value's track: `3` or `3/12`, the forms the spec gives it. `3 of
/// 12`, `1/` or a vinyl side's `A1` don't say which track it is, so they give
/// none, as with the package the app read MP3 with before.
fn track_number(value: &str) -> Option<i64> {
    let value = dart::trim(value);
    let number = match value.split_once('/') {
        Some((number, total)) if !total.is_empty() && total.bytes().all(|b| b.is_ascii_digit()) => {
            number
        }
        Some(_) => return None,
        None => value,
    };
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    number.parse().ok().filter(|n| *n > 0)
}

/// The first non-blank value.
fn first(values: &Option<Vec<String>>) -> Option<String> {
    values
        .iter()
        .flatten()
        .map(|value| dart::trim(value))
        .find(|value| !value.is_empty())
        .map(str::to_owned)
}

/// Every non-blank value, joined: several artists are a joint credit.
fn joined(values: &Option<Vec<String>>) -> Option<String> {
    let kept: Vec<&str> = values
        .iter()
        .flatten()
        .map(|value| dart::trim(value))
        .filter(|value| !value.is_empty())
        .collect();
    (!kept.is_empty()).then(|| kept.join(", "))
}

/// Past any further ID3v2 tags written right after the first one.
fn skip_appended_tags<R: Read + Seek>(source: &mut R, mut at: u64, length: u64) -> io::Result<u64> {
    while at + 10 <= length {
        source.seek(SeekFrom::Start(at))?;
        let header = read_up_to(source, 10)?;
        if !header.starts_with(b"ID3") || header[6..10].iter().any(|b| b & 0x80 != 0) {
            break;
        }
        let footer = if header[3] == 4 && header[5] & 0x10 != 0 {
            10
        } else {
            0
        };
        let total = 10 + u64::from(id3v2::synchsafe(&header[6..10])) + footer;
        if total > length - at {
            break;
        }
        at += total;
    }
    Ok(at)
}

/// Whether an APE tag ends at `end`: its footer's `APETAGEX` 32 bytes back.
fn has_ape_tag<R: Read + Seek>(source: &mut R, end: u64) -> io::Result<bool> {
    if end < 32 {
        return Ok(false);
    }
    source.seek(SeekFrom::Start(end - 32))?;
    Ok(read_up_to(source, 8)? == b"APETAGEX")
}

/// What an ID3v1 tag holds.
#[derive(Default)]
struct Id3v1 {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    track: Option<i64>,
}

/// The ID3v1 tag in the last 128 bytes, when there is one: `TAG`, then
/// Latin-1 fields padded with NUL or spaces; a v1.1 tag ends its comment with
/// a zero and the track number.
fn id3v1<R: Read + Seek>(source: &mut R, length: u64) -> io::Result<Option<Id3v1>> {
    if length < 128 {
        return Ok(None);
    }
    source.seek(SeekFrom::Start(length - 128))?;
    let tag = read_up_to(source, 128)?;
    if tag.len() < 128 || !tag.starts_with(b"TAG") {
        return Ok(None);
    }
    let field = |range: std::ops::Range<usize>| {
        let bytes = &tag[range];
        let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
        let text: String = bytes[..end].iter().map(|b| char::from(*b)).collect();
        let text = dart::trim(&text);
        (!text.is_empty()).then(|| text.to_owned())
    };
    Ok(Some(Id3v1 {
        title: field(3..33),
        artist: field(33..63),
        album: field(63..93),
        track: (tag[125] == 0 && tag[126] != 0).then(|| i64::from(tag[126])),
    }))
}

#[cfg(test)]
mod tests {
    use super::track_number;

    #[test]
    fn a_track_is_a_number_or_a_number_out_of_a_total() {
        assert_eq!(track_number("3"), Some(3));
        assert_eq!(track_number(" 3/12 "), Some(3));
        assert_eq!(track_number("03"), Some(3));
        for odd in ["A1", "3 of 12", "1/", "1 / 10", "/12", "0", "", "x3/4"] {
            assert_eq!(track_number(odd), None, "{odd:?}");
        }
    }
}
