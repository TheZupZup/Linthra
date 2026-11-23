//! Which cached tracks to delete so a new download fits under the cache limit.
//!
//! The same rules as `lib/core/services/cache_eviction_policy.dart`, and held
//! to them by the cases in `test/fixtures/cache_eviction_cases.json`, which
//! both implementations replay. Pure: it takes the cache's metadata and returns
//! a plan, with no I/O.
//!
//! Rules, in order:
//!  - Entries Linthra does not manage (on-device tracks) and zero-byte entries
//!    are never evicted. An unmanaged entry's size still counts as used.
//!  - Protected tracks (the one playing, the ones about to play) are never
//!    evicted, nor are pinned ("Keep offline") ones.
//!  - With `only_preloaded`, only automatic pre-caches are candidates, so a
//!    pre-cache never removes a track the user downloaded.
//!  - Automatic pre-caches go before user downloads. Within each kind the least
//!    recently used goes first: never played counts as oldest, then the oldest
//!    download, then the track id in UTF-16 order, the way Dart compares
//!    strings.
//!  - A re-download replaces its own copy: that copy neither counts as used
//!    nor can be evicted.
//!  - When even evicting every candidate would not make room, nothing is
//!    evicted and the plan says it does not fit.

use std::cmp::Ordering;
use std::collections::HashSet;

/// A cached track's identity: its provider's URI scheme and its id there. Two
/// providers can use the same id for different songs, so both halves count. A
/// track with no scheme has an empty `source`.
///
/// Borrowed, so a plan over a large cache copies no strings.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CacheKey<'a> {
    pub source: &'a str,
    pub id: &'a str,
}

impl<'a> CacheKey<'a> {
    pub fn new(source: Option<&'a str>, id: &'a str) -> Self {
        Self {
            source: source.unwrap_or_default(),
            id,
        }
    }
}

/// What the policy needs to know about one cached track. Times are opaque
/// instants in one unit (the caller picks it); `None` means never.
#[derive(Clone, Debug)]
pub struct CachedEntry<'a> {
    pub key: CacheKey<'a>,
    /// Whether Linthra owns the file, so deleting it frees app-managed space.
    pub managed: bool,
    pub size_bytes: i64,
    pub last_accessed: Option<i64>,
    pub cached_at: Option<i64>,
    pub pinned: bool,
    pub preloaded: bool,
}

/// The tracks a download asks the policy to keep, and what it is downloading.
#[derive(Clone, Debug, Default)]
pub struct EvictionRequest<'a> {
    pub incoming_bytes: i64,
    pub max_bytes: i64,
    /// Never evicted: the track playing and the ones about to play.
    pub protected: HashSet<CacheKey<'a>>,
    /// Only automatic pre-caches may go.
    pub only_preloaded: bool,
    /// The track being downloaded, when it may already have a copy.
    pub incoming: Option<CacheKey<'a>>,
}

/// The policy's answer: indices into the cached entries, in the order to
/// delete them, and whether the download fits once they are gone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvictionPlan {
    pub evict: Vec<usize>,
    pub fits: bool,
}

impl EvictionPlan {
    const FITS: Self = Self {
        evict: Vec::new(),
        fits: true,
    };
    const DOES_NOT_FIT: Self = Self {
        evict: Vec::new(),
        fits: false,
    };
}

/// Whether `entry` may be removed to make room, by the rules [plan] applies.
pub fn is_evictable(
    entry: &CachedEntry,
    protected: &HashSet<CacheKey>,
    only_preloaded: bool,
) -> bool {
    entry.managed
        && entry.size_bytes > 0
        && !entry.pinned
        && (!only_preloaded || entry.preloaded)
        && !protected.contains(&entry.key)
}

/// Plans which of `cached` to delete so `request` fits.
pub fn plan(cached: &[CachedEntry], request: &EvictionRequest) -> EvictionPlan {
    let mut used: i64 = 0;
    let mut candidates: Vec<usize> = Vec::new();
    for (index, entry) in cached.iter().enumerate() {
        if request.incoming.as_ref() == Some(&entry.key) {
            continue;
        }
        used += entry.size_bytes;
        if is_evictable(entry, &request.protected, request.only_preloaded) {
            candidates.push(index);
        }
    }

    let fits_after = |freed: i64| used - freed + request.incoming_bytes <= request.max_bytes;
    if fits_after(0) {
        return EvictionPlan::FITS;
    }
    // Larger than the whole limit: it can never fit, so nothing is deleted.
    if request.incoming_bytes > request.max_bytes {
        return EvictionPlan::DOES_NOT_FIT;
    }

    candidates.sort_by(|&a, &b| evict_first(&cached[a], &cached[b]));

    let mut evict = Vec::new();
    let mut freed: i64 = 0;
    for index in candidates {
        if fits_after(freed) {
            break;
        }
        evict.push(index);
        freed += cached[index].size_bytes;
    }

    if fits_after(freed) {
        EvictionPlan { evict, fits: true }
    } else {
        EvictionPlan::DOES_NOT_FIT
    }
}

/// Eviction order: pre-caches first, then least recently used, then oldest
/// download, then track id.
fn evict_first(a: &CachedEntry, b: &CachedEntry) -> Ordering {
    b.preloaded
        .cmp(&a.preloaded)
        .then_with(|| oldest_first(a.last_accessed, b.last_accessed))
        .then_with(|| oldest_first(a.cached_at, b.cached_at))
        .then_with(|| a.key.id.encode_utf16().cmp(b.key.id.encode_utf16()))
}

/// `None` (never) sorts before any real time.
fn oldest_first(a: Option<i64>, b: Option<i64>) -> Ordering {
    // Option's own order already puts None first.
    a.cmp(&b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, size: i64, accessed: Option<i64>) -> CachedEntry<'_> {
        CachedEntry {
            key: CacheKey::new(Some("jellyfin"), id),
            managed: true,
            size_bytes: size,
            last_accessed: accessed,
            cached_at: None,
            pinned: false,
            preloaded: false,
        }
    }

    #[test]
    fn evicts_the_least_recently_used_until_it_fits() {
        let cached = [
            entry("new", 100, Some(30)),
            entry("old", 100, Some(10)),
            entry("mid", 100, Some(20)),
        ];
        let request = EvictionRequest {
            incoming_bytes: 150,
            max_bytes: 300,
            ..EvictionRequest::default()
        };
        assert_eq!(
            plan(&cached, &request),
            EvictionPlan {
                evict: vec![1, 2],
                fits: true
            }
        );
    }

    #[test]
    fn a_missing_source_is_the_empty_source() {
        assert_eq!(CacheKey::new(None, "1"), CacheKey::new(Some(""), "1"));
        assert_ne!(CacheKey::new(None, "1"), CacheKey::new(Some("plex"), "1"));
    }

    #[test]
    fn ids_compare_by_utf16_code_units() {
        // U+FF5E is one UTF-16 unit; U+1F600 is a surrogate pair starting
        // 0xD83D. UTF-16 puts the emoji first, UTF-8 the other way round.
        let a = entry("\u{FF5E}", 10, None);
        let b = entry("\u{1F600}", 10, None);
        assert_eq!(evict_first(&b, &a), Ordering::Less);
    }
}
