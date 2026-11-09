//! Small, bounded HTTP byte-range requests for remote audio.
//!
//! This module only plans ranges. It does not download, decode, or cache audio.
//! A caller must verify that the server supports ranges and replies with a
//! matching 206 Partial Content / Content-Range. A 200 OK response may contain
//! the entire track and must not be treated as a bounded chunk.

/// Both ends are inclusive, as required by the HTTP Range header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u64,
    pub end_inclusive: u64,
}

impl ByteRange {
    /// Number of bytes requested, not the size of the remote file.
    pub fn byte_count(self) -> u64 {
        self.end_inclusive - self.start + 1
    }

    pub fn http_header_value(self) -> String {
        format!("bytes={}-{}", self.start, self.end_inclusive)
    }
}

/// Plans the next bounded request starting at `offset`.
///
/// `max_bytes` is the caller's per-request budget. `known_length` is the
/// remote file's total size, if known. A zero budget, an empty file, or an
/// offset at or beyond the end of a known file produces no request.
///
/// No full-file download is implied when the total length is unknown: even
/// then, the returned range stays within the requested budget.
pub fn plan_http_range(
    offset: u64,
    max_bytes: u64,
    known_length: Option<u64>,
) -> Option<ByteRange> {
    if max_bytes == 0 {
        return None;
    }

    let last_byte = match known_length {
        Some(length) if offset >= length => return None,
        Some(length) => length - 1,
        None => u64::MAX,
    };

    Some(ByteRange {
        start: offset,
        end_inclusive: offset.saturating_add(max_bytes - 1).min(last_byte),
    })
}

#[cfg(test)]
mod tests {
    use super::{plan_http_range, ByteRange};

    #[test]
    fn requests_only_one_chunk_of_a_large_track() {
        let track_bytes = 100 * 1024 * 1024;
        let chunk_bytes = 256 * 1024;
        let range = plan_http_range(0, chunk_bytes, Some(track_bytes)).unwrap();

        assert_eq!(
            range,
            ByteRange {
                start: 0,
                end_inclusive: chunk_bytes - 1,
            }
        );
        assert_eq!(range.byte_count(), chunk_bytes);
        assert_eq!(range.http_header_value(), "bytes=0-262143");
    }

    #[test]
    fn next_chunk_starts_after_the_previous_one() {
        let first = plan_http_range(0, 1024, Some(10_000)).unwrap();
        let next = plan_http_range(first.end_inclusive + 1, 1024, Some(10_000)).unwrap();

        assert_eq!(next.start, 1024);
        assert_eq!(next.end_inclusive, 2047);
    }

    #[test]
    fn clamps_the_final_chunk_to_the_file_length() {
        let range = plan_http_range(4096, 4096, Some(5000)).unwrap();

        assert_eq!(range.http_header_value(), "bytes=4096-4999");
        assert_eq!(range.byte_count(), 904);
    }

    #[test]
    fn refuses_empty_requests_and_offsets_past_eof() {
        assert_eq!(plan_http_range(0, 0, None), None);
        assert_eq!(plan_http_range(0, 1024, Some(0)), None);
        assert_eq!(plan_http_range(5000, 1024, Some(5000)), None);
        assert_eq!(plan_http_range(5001, 1024, Some(5000)), None);
    }

    #[test]
    fn unknown_file_length_still_has_a_bounded_range() {
        let range = plan_http_range(8192, 512, None).unwrap();

        assert_eq!(range.http_header_value(), "bytes=8192-8703");
        assert_eq!(range.byte_count(), 512);
    }

    #[test]
    fn handles_offsets_near_the_integer_limit() {
        let range = plan_http_range(u64::MAX - 1, 256, None).unwrap();

        assert_eq!(range.end_inclusive, u64::MAX);
        assert_eq!(range.byte_count(), 2);
        assert_eq!(plan_http_range(u64::MAX, 1, Some(u64::MAX)), None);
        assert_eq!(
            plan_http_range(u64::MAX - 1, 256, Some(u64::MAX))
                .unwrap()
                .byte_count(),
            1
        );
    }
}
