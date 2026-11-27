//! The incremental scan's decisions, for `LocalMusicSource._scanFiles`
//! (lib/core/sources/local/local_music_source.dart), which walks, stamps and
//! reads the files and asks these two questions about each one:
//!
//! - [plan]: can the row(s) already indexed for this file be reused as they
//!   are, or must its tags be read?
//! - [settle]: its tags were read (or the read failed); which row does it
//!   get, and is its stamp kept?
//!
//! A stamp is a file's size and mtime. A file is either a plain audio file,
//! with at most one indexed row under its own path, or the audio a CUE sheet
//! splits into tracks, with one entry per track: the sheet's stamp and the
//! row indexed under that track's uri. Everything leans one way: when in
//! doubt the file is read again, and a read that says nothing new never
//! throws away a row that was right.

/// A file's size and last-modified time (`LocalFileStamp`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub size: i64,
    pub modified_ms: i64,
}

/// A row the catalog already holds (`StampedTrack`), as far as these rules
/// look at it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Indexed {
    /// The stamp its file had when the row was written; none for a row whose
    /// read failed, or one written before stamps existed.
    pub stamp: Option<Stamp>,
    /// The CUE sheet's size and mtime the row was built from, for a CUE
    /// track.
    pub cue_sheet_size: Option<i64>,
    pub cue_sheet_modified_ms: Option<i64>,
    /// Its cover is gone from the artwork cache, so the file is read again
    /// to bring it back.
    pub artwork_missing: bool,
}

/// One track a CUE sheet cuts from the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CueEntry {
    /// The sheet's stamp; none when it couldn't be stat'ed.
    pub sheet: Option<Stamp>,
    /// The row indexed under this track's uri.
    pub indexed: Option<Indexed>,
}

/// One audio file the walk found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanFile {
    /// Its stamp now; none when it couldn't be stat'ed.
    pub stamp: Option<Stamp>,
    /// The row indexed under its path (a plain file only).
    pub indexed: Option<Indexed>,
    /// The tracks CUE sheets cut from it; empty for a plain file.
    pub cue: Vec<CueEntry>,
}

/// What came of reading a file's tags.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Read {
    /// Tags came back.
    pub has_tags: bool,
    /// The read failed, as opposed to finding no tags.
    pub failed: bool,
}

/// What [settle] decides.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Settled {
    /// The indexed row(s) stand as they are.
    Keep {
        /// Stored with the file's stamp, so the next scan reuses it without
        /// reading. Without it the next scan reads the file again.
        stamp: bool,
        /// The walk listed the file, and then it could be neither stat'ed
        /// nor read: moved, deleted or out of reach mid-scan.
        vanished: bool,
        /// Counted among the scan's reused tracks.
        reused: bool,
    },
    /// New row(s) built from what the read found (or the file name).
    Build {
        /// Stored with the file's stamp, as above.
        stamp: bool,
    },
}

fn same(stamp: Stamp, previous: Option<Stamp>) -> bool {
    previous == Some(stamp)
}

/// Every CUE track of the file is indexed from this very file and sheet.
fn cue_unchanged(stamp: Stamp, cue: &[CueEntry], check_artwork: bool) -> bool {
    cue.iter().all(|entry| {
        let (Some(sheet), Some(indexed)) = (entry.sheet, entry.indexed) else {
            return false;
        };
        same(stamp, indexed.stamp)
            && indexed.cue_sheet_size == Some(sheet.size)
            && indexed.cue_sheet_modified_ms == Some(sheet.modified_ms)
            && !(check_artwork && indexed.artwork_missing)
    })
}

/// Whether `file`'s indexed row(s) are reused without reading it: its stamp
/// (and, for CUE tracks, its sheet's) is the one they were built from, and
/// their cover is still cached. Never when `read_unchanged`, which reads
/// every file again because the way tags are read changed.
pub fn plan(file: &ScanFile, read_unchanged: bool) -> bool {
    if read_unchanged {
        return false;
    }
    let Some(stamp) = file.stamp else {
        return false;
    };
    if !file.cue.is_empty() {
        return cue_unchanged(stamp, &file.cue, true);
    }
    match file.indexed {
        Some(indexed) => same(stamp, indexed.stamp) && !indexed.artwork_missing,
        None => false,
    }
}

/// Which row(s) `file` gets once its tags were read (`read`).
pub fn settle(file: &ScanFile, read: Read, read_unchanged: bool) -> Settled {
    if !file.cue.is_empty() {
        return settle_cue(file, read, read_unchanged);
    }
    let stamp = file.stamp;
    let Some(indexed) = file.indexed else {
        // Nothing to keep: a new file. A failed read keeps no stamp, so the
        // next scan reads it again rather than keep a row built from its
        // file name for good.
        return Settled::Build {
            stamp: stamp.is_some() && !read.failed,
        };
    };
    match stamp {
        // Listed by the walk, but now neither stat'ed nor read: that says
        // nothing about its tags, so its row stays as it was, with no stamp.
        // If the file really is gone, the next walk drops it.
        None if !read.has_tags => Settled::Keep {
            stamp: false,
            vanished: true,
            reused: true,
        },
        // Unchanged, read again for its cover or for the new way of reading
        // tags, and the read found nothing. A failed read says nothing about
        // the tags the row was built from, so the row stays. A file due for
        // the new reader keeps no stamp, so the next scan reads it again; one
        // the new reader read fine and found nothing in is settled below
        // like any other file.
        Some(now)
            if !read.has_tags && same(now, indexed.stamp) && (read.failed || !read_unchanged) =>
        {
            Settled::Keep {
                stamp: !read_unchanged,
                vanished: false,
                reused: false,
            }
        }
        // A row with no stamp, most likely from a read that failed last
        // time too: this failed read says nothing either, so the row stays.
        // It keeps the stamp this time, so a file that can never be read
        // costs one more read rather than one every scan, unless it is due
        // for the new reader.
        Some(_) if read.failed && indexed.stamp.is_none() => Settled::Keep {
            stamp: !read_unchanged,
            vanished: false,
            reused: false,
        },
        _ => Settled::Build {
            stamp: stamp.is_some() && !read.failed,
        },
    }
}

/// [settle] for the CUE tracks of one audio file.
fn settle_cue(file: &ScanFile, read: Read, read_unchanged: bool) -> Settled {
    match file.stamp {
        // A failed read of an unchanged file and sheets keeps every track's
        // row: rebuilt now, they would lose their tags for good.
        Some(stamp) if read.failed && cue_unchanged(stamp, &file.cue, false) => Settled::Keep {
            stamp: !read_unchanged,
            vanished: false,
            reused: true,
        },
        stamp => Settled::Build {
            stamp: stamp.is_some() && !read.failed,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: Stamp = Stamp {
        size: 100,
        modified_ms: 5,
    };
    const OLD: Stamp = Stamp {
        size: 90,
        modified_ms: 4,
    };
    const SHEET: Stamp = Stamp {
        size: 7,
        modified_ms: 9,
    };

    fn row(stamp: Option<Stamp>) -> Indexed {
        Indexed {
            stamp,
            ..Indexed::default()
        }
    }

    fn plain(stamp: Option<Stamp>, indexed: Option<Indexed>) -> ScanFile {
        ScanFile {
            stamp,
            indexed,
            cue: Vec::new(),
        }
    }

    fn cue_row(stamp: Option<Stamp>, sheet: Stamp) -> Indexed {
        Indexed {
            stamp,
            cue_sheet_size: Some(sheet.size),
            cue_sheet_modified_ms: Some(sheet.modified_ms),
            artwork_missing: false,
        }
    }

    fn cued(stamp: Option<Stamp>, entries: &[(Option<Stamp>, Option<Indexed>)]) -> ScanFile {
        ScanFile {
            stamp,
            indexed: None,
            cue: entries
                .iter()
                .map(|&(sheet, indexed)| CueEntry { sheet, indexed })
                .collect(),
        }
    }

    const READ: Read = Read {
        has_tags: true,
        failed: false,
    };
    const EMPTY: Read = Read {
        has_tags: false,
        failed: false,
    };
    const FAILED: Read = Read {
        has_tags: false,
        failed: true,
    };

    #[test]
    fn an_unchanged_file_is_reused() {
        assert!(plan(&plain(Some(NOW), Some(row(Some(NOW)))), false));
    }

    #[test]
    fn anything_else_is_read() {
        // Changed, never stamped, not indexed, not stat'ed.
        assert!(!plan(&plain(Some(NOW), Some(row(Some(OLD)))), false));
        assert!(!plan(&plain(Some(NOW), Some(row(None))), false));
        assert!(!plan(&plain(Some(NOW), None), false));
        assert!(!plan(&plain(None, Some(row(Some(NOW)))), false));
        // Its cover is gone from the cache.
        let mut lost = row(Some(NOW));
        lost.artwork_missing = true;
        assert!(!plan(&plain(Some(NOW), Some(lost)), false));
        // The way tags are read changed.
        assert!(!plan(&plain(Some(NOW), Some(row(Some(NOW)))), true));
    }

    #[test]
    fn cue_tracks_are_reused_only_when_file_and_sheets_are_unchanged() {
        let track = Some(cue_row(Some(NOW), SHEET));
        assert!(plan(
            &cued(Some(NOW), &[(Some(SHEET), track), (Some(SHEET), track)]),
            false
        ));
        // One track not indexed, a sheet not stat'ed, a sheet changed.
        assert!(!plan(
            &cued(Some(NOW), &[(Some(SHEET), track), (Some(SHEET), None)]),
            false
        ));
        assert!(!plan(&cued(Some(NOW), &[(None, track)]), false));
        assert!(!plan(&cued(Some(NOW), &[(Some(OLD), track)]), false));
        // The audio changed, or wasn't stat'ed.
        assert!(!plan(&cued(Some(OLD), &[(Some(SHEET), track)]), false));
        assert!(!plan(&cued(None, &[(Some(SHEET), track)]), false));
        // One cover gone, or tags due for the new reader.
        let mut lost = cue_row(Some(NOW), SHEET);
        lost.artwork_missing = true;
        assert!(!plan(
            &cued(
                Some(NOW),
                &[(Some(SHEET), track), (Some(SHEET), Some(lost))]
            ),
            false
        ));
        assert!(!plan(&cued(Some(NOW), &[(Some(SHEET), track)]), true));
    }

    #[test]
    fn a_new_file_is_built_and_stamped_unless_its_read_failed() {
        let file = plain(Some(NOW), None);
        assert_eq!(settle(&file, READ, false), Settled::Build { stamp: true });
        assert_eq!(settle(&file, EMPTY, false), Settled::Build { stamp: true });
        assert_eq!(
            settle(&file, FAILED, false),
            Settled::Build { stamp: false }
        );
        assert_eq!(
            settle(&plain(None, None), READ, false),
            Settled::Build { stamp: false }
        );
    }

    #[test]
    fn a_file_that_vanished_mid_scan_keeps_its_row() {
        let file = plain(None, Some(row(Some(OLD))));
        let kept = Settled::Keep {
            stamp: false,
            vanished: true,
            reused: true,
        };
        assert_eq!(settle(&file, FAILED, false), kept);
        assert_eq!(settle(&file, EMPTY, true), kept);
        // Tags came back after all: rebuilt, still without a stamp.
        assert_eq!(settle(&file, READ, false), Settled::Build { stamp: false });
    }

    #[test]
    fn an_unchanged_file_read_again_for_nothing_keeps_its_row() {
        let file = plain(Some(NOW), Some(row(Some(NOW))));
        let keep = |stamp| Settled::Keep {
            stamp,
            vanished: false,
            reused: false,
        };
        // Read for its cover: a failed or empty read keeps the row.
        assert_eq!(settle(&file, FAILED, false), keep(true));
        assert_eq!(settle(&file, EMPTY, false), keep(true));
        // Read for the new reader: a failed read keeps the row, unstamped;
        // an empty one is what the new reader found, and is built.
        assert_eq!(settle(&file, FAILED, true), keep(false));
        assert_eq!(settle(&file, EMPTY, true), Settled::Build { stamp: true });
        // Tags came back: rebuilt.
        assert_eq!(settle(&file, READ, false), Settled::Build { stamp: true });
    }

    #[test]
    fn an_unstamped_row_survives_another_failed_read_once() {
        let file = plain(Some(NOW), Some(row(None)));
        let keep = |stamp| Settled::Keep {
            stamp,
            vanished: false,
            reused: false,
        };
        assert_eq!(settle(&file, FAILED, false), keep(true));
        assert_eq!(settle(&file, FAILED, true), keep(false));
        assert_eq!(settle(&file, EMPTY, false), Settled::Build { stamp: true });
    }

    #[test]
    fn a_changed_file_whose_read_failed_is_rebuilt_unstamped() {
        let file = plain(Some(NOW), Some(row(Some(OLD))));
        assert_eq!(
            settle(&file, FAILED, false),
            Settled::Build { stamp: false }
        );
        assert_eq!(settle(&file, EMPTY, false), Settled::Build { stamp: true });
    }

    #[test]
    fn cue_tracks_keep_their_rows_through_a_failed_read_of_an_unchanged_file() {
        let track = Some(cue_row(Some(NOW), SHEET));
        let file = cued(Some(NOW), &[(Some(SHEET), track), (Some(SHEET), track)]);
        let keep = |stamp| Settled::Keep {
            stamp,
            vanished: false,
            reused: true,
        };
        assert_eq!(settle(&file, FAILED, false), keep(true));
        assert_eq!(settle(&file, FAILED, true), keep(false));
        // A missing cover doesn't matter here: the rows are kept as they are.
        let mut lost = cue_row(Some(NOW), SHEET);
        lost.artwork_missing = true;
        let file = cued(Some(NOW), &[(Some(SHEET), Some(lost))]);
        assert_eq!(settle(&file, FAILED, false), keep(true));
    }

    #[test]
    fn cue_tracks_are_rebuilt_otherwise() {
        let track = Some(cue_row(Some(NOW), SHEET));
        let unchanged = cued(Some(NOW), &[(Some(SHEET), track)]);
        assert_eq!(
            settle(&unchanged, READ, false),
            Settled::Build { stamp: true }
        );
        assert_eq!(
            settle(&unchanged, EMPTY, false),
            Settled::Build { stamp: true }
        );
        let changed = cued(Some(NOW), &[(Some(OLD), track)]);
        assert_eq!(
            settle(&changed, FAILED, false),
            Settled::Build { stamp: false }
        );
        let unstat = cued(None, &[(Some(SHEET), track)]);
        assert_eq!(
            settle(&unstat, FAILED, false),
            Settled::Build { stamp: false }
        );
        assert_eq!(
            settle(&unstat, READ, false),
            Settled::Build { stamp: false }
        );
    }
}
