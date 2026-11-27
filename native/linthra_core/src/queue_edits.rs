//! The playback queue's edits and shuffle, on entry ids.
//!
//! The same rules as `lib/core/models/playback_queue.dart`, held to them by the
//! cases in `test/fixtures/queue_edits_cases.txt`, which both replay. Tracks
//! never cross: a queue is the id of each entry in play order, the position of
//! the current one, and, while shuffled, the ids in the order before shuffle.
//! An edit answers with the new ids and, for each entry, where it came from,
//! so Dart can rebuild its track lists without matching tracks by value.

/// Where an entry of an edited queue came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The entry at this position in the queue's play order.
    Track(usize),
    /// The entry at this position in the order before shuffle.
    Original(usize),
    /// The added track at this position (inserts only).
    Added(usize),
}

/// A queue as the edits see it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueueIds {
    pub ids: Vec<i64>,
    /// Position of the current entry in `ids`, -1 when the queue is empty.
    pub current: i64,
    /// The ids in the order before shuffle, or `None` when not shuffled.
    pub original: Option<Vec<i64>>,
}

/// An edited queue: its ids, and where each entry came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueueEdit {
    pub ids: Vec<i64>,
    pub sources: Vec<Source>,
    pub current: i64,
    pub original: Option<(Vec<i64>, Vec<Source>)>,
}

/// An edit to the queue. Every edit leaves the queue alone (`None`) when it
/// has nothing to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QueueOp<'a> {
    /// `count` new entries right after the current one ("play next"), or at
    /// the end ("add to queue"). Asked only of a queue with a current entry.
    Insert { count: usize, after_current: bool },
    /// Takes out the entry at this position in up next.
    RemoveUpNextAt(i64),
    /// Moves an entry of up next from one position to another (the position
    /// after removal, as a reorderable list reports it).
    ReorderUpNext(i64, i64),
    /// Takes out every entry flagged, in play order and in the order before
    /// shuffle (one flag per entry of each).
    RemoveWhere {
        removed: &'a [bool],
        removed_original: &'a [bool],
    },
    /// Shuffles everything but the current entry, which moves to the front.
    Shuffle { seed: u64 },
    /// Back to the order before shuffle, the current entry kept current.
    Unshuffle,
}

impl QueueIds {
    fn has_current(&self) -> bool {
        self.current >= 0 && (self.current as usize) < self.ids.len()
    }

    fn up_next_len(&self) -> i64 {
        if self.has_current() {
            self.ids.len() as i64 - self.current - 1
        } else {
            0
        }
    }

    /// One past the highest id in use, so a new entry never reuses one.
    fn next_id(&self) -> i64 {
        let originals = self.original.iter().flatten();
        self.ids
            .iter()
            .chain(originals)
            .map(|id| id + 1)
            .fold(0, i64::max)
    }

    fn unchanged_original(&self) -> Option<(Vec<i64>, Vec<Source>)> {
        self.original
            .as_ref()
            .map(|ids| (ids.clone(), (0..ids.len()).map(Source::Original).collect()))
    }
}

pub fn edit_queue(queue: &QueueIds, op: &QueueOp) -> Option<QueueEdit> {
    match *op {
        QueueOp::Insert {
            count,
            after_current,
        } => insert(queue, count, after_current),
        QueueOp::RemoveUpNextAt(index) => remove_up_next_at(queue, index),
        QueueOp::ReorderUpNext(from, to) => reorder_up_next(queue, from, to),
        QueueOp::RemoveWhere {
            removed,
            removed_original,
        } => remove_where(queue, removed, removed_original),
        QueueOp::Shuffle { seed } => shuffle(queue, seed),
        QueueOp::Unshuffle => unshuffle(queue),
    }
}

fn tracks_of(len: usize) -> (Vec<Source>, usize) {
    ((0..len).map(Source::Track).collect(), len)
}

fn insert(queue: &QueueIds, count: usize, after_current: bool) -> Option<QueueEdit> {
    if count == 0 || !queue.has_current() {
        return None;
    }
    let first = queue.next_id();
    let added: Vec<i64> = (0..count as i64).map(|i| first + i).collect();
    let added_sources: Vec<Source> = (0..count).map(Source::Added).collect();
    let at = if after_current {
        queue.current as usize + 1
    } else {
        queue.ids.len()
    };
    let (mut sources, _) = tracks_of(queue.ids.len());
    let mut ids = queue.ids.clone();
    ids.splice(at..at, added.iter().copied());
    sources.splice(at..at, added_sources.iter().copied());

    let original = queue.original.as_ref().map(|original| {
        let own = if after_current {
            let current_id = queue.ids[queue.current as usize];
            original.iter().position(|id| *id == current_id)
        } else {
            None
        };
        let at = own.map_or(original.len(), |i| i + 1);
        let mut ids = original.clone();
        let mut sources: Vec<Source> = (0..original.len()).map(Source::Original).collect();
        ids.splice(at..at, added.iter().copied());
        sources.splice(at..at, added_sources.iter().copied());
        (ids, sources)
    });
    Some(QueueEdit {
        ids,
        sources,
        current: queue.current,
        original,
    })
}

fn remove_up_next_at(queue: &QueueIds, index: i64) -> Option<QueueEdit> {
    if index < 0 || index >= queue.up_next_len() {
        return None;
    }
    let absolute = (queue.current + 1 + index) as usize;
    let removed_id = queue.ids[absolute];
    let (mut sources, _) = tracks_of(queue.ids.len());
    let mut ids = queue.ids.clone();
    ids.remove(absolute);
    sources.remove(absolute);
    let original = queue.unchanged_original().map(|(mut ids, mut sources)| {
        if let Some(i) = ids.iter().position(|id| *id == removed_id) {
            ids.remove(i);
            sources.remove(i);
        }
        (ids, sources)
    });
    Some(QueueEdit {
        ids,
        sources,
        current: queue.current,
        original,
    })
}

fn reorder_up_next(queue: &QueueIds, from: i64, to: i64) -> Option<QueueEdit> {
    let count = queue.up_next_len();
    if from < 0 || from >= count || to < 0 || to >= count || from == to {
        return None;
    }
    let base = (queue.current + 1) as usize;
    let (mut sources, _) = tracks_of(queue.ids.len());
    let mut ids = queue.ids.clone();
    let id = ids.remove(base + from as usize);
    let source = sources.remove(base + from as usize);
    ids.insert(base + to as usize, id);
    sources.insert(base + to as usize, source);
    Some(QueueEdit {
        ids,
        sources,
        current: queue.current,
        original: queue.unchanged_original(),
    })
}

fn remove_where(
    queue: &QueueIds,
    removed: &[bool],
    removed_original: &[bool],
) -> Option<QueueEdit> {
    if !removed.iter().any(|r| *r) {
        return None;
    }
    let mut ids = Vec::new();
    let mut sources = Vec::new();
    // The current entry when it stays, else the first one kept after it.
    let mut current: Option<usize> = None;
    for (i, id) in queue.ids.iter().enumerate() {
        if removed.get(i).copied().unwrap_or(false) {
            continue;
        }
        if current.is_none() && i as i64 >= queue.current {
            current = Some(ids.len());
        }
        ids.push(*id);
        sources.push(Source::Track(i));
    }
    if ids.is_empty() {
        return Some(QueueEdit {
            ids,
            sources,
            current: -1,
            original: None,
        });
    }
    let original = queue.original.as_ref().map(|original| {
        let mut kept = Vec::new();
        let mut kept_sources = Vec::new();
        for (i, id) in original.iter().enumerate() {
            if removed_original.get(i).copied().unwrap_or(false) {
                continue;
            }
            kept.push(*id);
            kept_sources.push(Source::Original(i));
        }
        (kept, kept_sources)
    });
    let current = current.unwrap_or(ids.len() - 1) as i64;
    Some(QueueEdit {
        ids,
        sources,
        current,
        original,
    })
}

fn shuffle(queue: &QueueIds, seed: u64) -> Option<QueueEdit> {
    if !queue.has_current() {
        return None;
    }
    let current = queue.current as usize;
    let mut rest: Vec<usize> = (0..queue.ids.len()).filter(|i| *i != current).collect();
    shuffle_in_place(&mut rest, seed);
    let order: Vec<usize> = std::iter::once(current).chain(rest).collect();
    // Shuffling again keeps the first order remembered.
    let original = queue.unchanged_original().or_else(|| {
        let (sources, _) = tracks_of(queue.ids.len());
        Some((queue.ids.clone(), sources))
    });
    Some(QueueEdit {
        ids: order.iter().map(|i| queue.ids[*i]).collect(),
        sources: order.into_iter().map(Source::Track).collect(),
        current: 0,
        original,
    })
}

fn unshuffle(queue: &QueueIds) -> Option<QueueEdit> {
    let original = queue.original.as_ref()?;
    let own = if queue.has_current() {
        let current_id = queue.ids[queue.current as usize];
        original.iter().position(|id| *id == current_id)
    } else {
        None
    };
    let current = match own {
        Some(i) => i as i64,
        None if original.is_empty() => -1,
        None => 0,
    };
    Some(QueueEdit {
        ids: original.clone(),
        sources: (0..original.len()).map(Source::Original).collect(),
        current,
        original: None,
    })
}

/// Fisher-Yates driven by splitmix64: the same seed always gives the same
/// order, which is what lets a test pin a shuffle down.
pub fn shuffle_in_place<T>(items: &mut [T], seed: u64) {
    let mut state = seed;
    for i in (1..items.len()).rev() {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        let j = ((z >> 1) % (i as u64 + 1)) as usize;
        items.swap(i, j);
    }
}
