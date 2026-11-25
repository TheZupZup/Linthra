//! A Vorbis comment block, the payload FLAC's VORBIS_COMMENT block and Ogg's
//! comment header share. Little-endian: vendor length, vendor, comment count,
//! then each comment as a length and `FIELD=value` in UTF-8.

use super::{dart, u32_le, Fields};

/// A block declaring more comments than this is corrupt: real files carry
/// tens, a heavily tagged one a few hundred.
const MAX_COMMENTS: u32 = 1 << 16;

/// In FLAC, a comment longer than this is skipped rather than read: a field
/// name is short, so one that big is never a field this is after.
const MAX_COMMENT_BYTES: u64 = 1 << 20;

/// The comments of a block declared `declared` bytes long, of which `bytes`
/// is what the file actually holds (less, when it is cut short).
///
/// `None` when the block doesn't hold together: a length running past the
/// block, too many comments, or bytes the file doesn't have. A comment that
/// isn't UTF-8, or has no field name, is skipped and the rest kept. With
/// `skip_oversized` (FLAC), a comment over 1 MiB is passed over unread.
pub fn parse(bytes: &[u8], declared: u64, skip_oversized: bool) -> Option<Fields> {
    let end = declared;
    let mut at: u64 = 0;
    let read_u32 = |at: &mut u64| -> Option<u32> {
        if *at + 4 > end || *at + 4 > bytes.len() as u64 {
            return None;
        }
        let value = u32_le(bytes, *at as usize);
        *at += 4;
        Some(value)
    };

    let vendor = read_u32(&mut at)?;
    if at + u64::from(vendor) > end {
        return None;
    }
    at += u64::from(vendor);

    let count = read_u32(&mut at)?;
    if count > MAX_COMMENTS {
        return None;
    }
    let mut fields = Fields::new();
    for _ in 0..count {
        let length = u64::from(read_u32(&mut at)?);
        let next = at + length;
        if next > end {
            return None;
        }
        if skip_oversized && length > MAX_COMMENT_BYTES {
            at = next;
            continue;
        }
        if next > bytes.len() as u64 {
            return None;
        }
        collect(&mut fields, &bytes[at as usize..next as usize]);
        at = next;
    }
    Some(fields)
}

/// Adds one `FIELD=value` comment to `fields`, unless it isn't UTF-8 or has
/// no field name.
fn collect(fields: &mut Fields, raw: &[u8]) {
    let Ok(comment) = std::str::from_utf8(raw) else {
        return;
    };
    let Some(equals) = comment.find('=').filter(|at| *at > 0) else {
        return;
    };
    fields
        .entry(dart::to_upper_case(&comment[..equals]))
        .or_default()
        .push(comment[equals + 1..].to_owned());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(comments: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&3u32.to_le_bytes());
        out.extend_from_slice(b"ven");
        out.extend_from_slice(&(comments.len() as u32).to_le_bytes());
        for comment in comments {
            out.extend_from_slice(&(comment.len() as u32).to_le_bytes());
            out.extend_from_slice(comment);
        }
        out
    }

    #[test]
    fn keeps_order_and_repeats_and_skips_what_it_cannot_read() {
        let bytes = block(&[b"artist=Alice", b"ARTIST=Bob", b"=x", b"plain", b"T=\xFF"]);
        let fields = parse(&bytes, bytes.len() as u64, false).unwrap();
        assert_eq!(fields["ARTIST"], ["Alice", "Bob"]);
        assert_eq!(fields.len(), 1);
    }

    #[test]
    fn refuses_a_length_past_the_block() {
        let mut bytes = block(&[b"TITLE=X"]);
        let at = bytes.len() - 11;
        bytes[at..at + 4].copy_from_slice(&100u32.to_le_bytes());
        assert_eq!(parse(&bytes, bytes.len() as u64, false), None);
    }

    #[test]
    fn refuses_too_many_comments() {
        let mut bytes = block(&[]);
        let at = bytes.len() - 4;
        bytes[at..].copy_from_slice(&(MAX_COMMENTS + 1).to_le_bytes());
        assert_eq!(parse(&bytes, bytes.len() as u64, false), None);
    }

    #[test]
    fn a_flac_block_passes_over_a_huge_comment() {
        // Declares a 2 MiB comment the file doesn't hold, then ends: FLAC
        // skips it unread, Ogg needs its bytes.
        let mut bytes = block(&[]);
        let at = bytes.len() - 4;
        bytes[at..].copy_from_slice(&1u32.to_le_bytes());
        bytes.extend_from_slice(&(2u32 << 20).to_le_bytes());
        let declared = bytes.len() as u64 + (2 << 20);
        assert_eq!(parse(&bytes, declared, true), Some(Fields::new()));
        assert_eq!(parse(&bytes, declared, false), None);
    }
}
