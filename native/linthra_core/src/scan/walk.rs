//! Walking a music folder, for `NativeAudioFileScanner.listFiles`
//! (lib/core/sources/local/native_audio_file_scanner.dart).
//!
//! One directory at a time, so an unreadable subfolder (permissions that
//! changed, a stale mount inside the music folder) is skipped and reported
//! instead of failing the scan. The caller has to know which part is
//! missing: a file under a skipped folder was not found, which is not the
//! same as not being there. The root itself failing, or the folder going
//! away mid-walk, fails the walk, because an empty or half answer would be
//! saved as "no music" and wipe the library: a drive unplugged mid-scan
//! fails every folder still pending, so the walk only counts if the folder
//! still answers at its end. Symlinks are neither walked nor indexed;
//! anything else that isn't a directory (a FIFO, a socket) is listed as a
//! file, as Dart's listing does.
//!
//! A name that isn't valid UTF-8 (Latin-1 bytes from an old Windows rip, a
//! share mounted without a UTF-8 charset) reaches Dart as text with U+FFFD
//! in it, and that text names nothing: it can't be stat'ed, read, played or
//! listed. Such an entry is reported as unopenable rather than indexed as a
//! song that can never play. A name that really holds U+FFFD opens fine and
//! is kept.
//!
//! Storage that stops answering is the hard part. A directory listing on a
//! share whose server went away blocks for as long as the mount retries, and
//! nothing can interrupt it. So listings run on a worker thread, and the walk
//! waits at most `stall_limit` for each next entry; a worker that doesn't
//! answer is abandoned to its blocked call, and a new one takes the next
//! directory.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// What a directory entry is, without following links.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Dir,
    Link,
    Other,
}

/// One raw entry of a listing.
#[derive(Debug, Clone)]
pub struct RawEntry {
    /// The name as the system has it; it need not be UTF-8.
    pub name: Vec<u8>,
    pub kind: Kind,
}

/// The filesystem as the walk sees it, so tests can make it fail or stall.
pub trait Lister: Send + Sync + 'static {
    /// Lists `dir`, handing each entry to `sink` as it is read; stops early
    /// when `sink` returns false.
    fn list(&self, dir: &str, sink: &mut dyn FnMut(io::Result<RawEntry>) -> bool)
        -> io::Result<()>;

    /// Whether `path` names anything, without following a final link.
    fn exists(&self, path: &str) -> io::Result<bool>;
}

/// Why a folder can't be listed: the errno when the system gave one, or that
/// it stopped answering.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// An I/O error, with its errno when there is one (Dart classifies it).
    Io(Option<i32>),
    /// No answer within the stall limit.
    Stalled,
}

/// How a walk failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkFailure {
    /// The selected folder itself couldn't be listed.
    Root(Fault),
    /// The folder went away, or stopped answering, during the walk.
    Interrupted(Fault),
}

/// A finished walk.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Walk {
    /// Every file found, in walk order.
    pub paths: Vec<String>,
    /// Directories that couldn't be listed and were skipped.
    pub unreadable: Vec<String>,
    /// Entries whose name isn't valid UTF-8 and names nothing as text.
    pub unopenable: Vec<String>,
}

/// The real filesystem.
pub struct SystemLister;

impl Lister for SystemLister {
    fn list(
        &self,
        dir: &str,
        sink: &mut dyn FnMut(io::Result<RawEntry>) -> bool,
    ) -> io::Result<()> {
        use std::os::unix::ffi::OsStrExt;
        for entry in std::fs::read_dir(dir)? {
            let raw = entry.and_then(|e| {
                let kind = e.file_type().map(|t| {
                    if t.is_dir() {
                        Kind::Dir
                    } else if t.is_symlink() {
                        Kind::Link
                    } else {
                        Kind::Other
                    }
                })?;
                Ok(RawEntry {
                    name: e.file_name().as_bytes().to_vec(),
                    kind,
                })
            });
            if !sink(raw) {
                break;
            }
        }
        Ok(())
    }

    fn exists(&self, path: &str) -> io::Result<bool> {
        match std::fs::symlink_metadata(path) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }
}

/// One entry as the walk uses it.
enum Item {
    /// A path that names something, and whether it is a directory to walk.
    Entry { path: String, kind: Kind },
    /// A name that isn't UTF-8 and whose lossy text names nothing.
    NamesNothing(String),
    /// The listing failed (to open, or part way through).
    Failed(Option<i32>),
    /// The listing finished.
    Done,
}

enum Job {
    List(String),
    Inspect(String),
}

/// A thread that runs listings, replaced when one stops answering.
struct Worker {
    jobs: Sender<(Job, Sender<Item>)>,
}

impl Worker {
    fn start(lister: Arc<dyn Lister>) -> Worker {
        let (jobs, inbox) = mpsc::channel::<(Job, Sender<Item>)>();
        thread::spawn(move || {
            for (job, out) in inbox {
                match job {
                    Job::List(dir) => list_into(&*lister, &dir, &out),
                    Job::Inspect(dir) => inspect_into(&*lister, &dir, &out),
                }
            }
        });
        Worker { jobs }
    }

    fn run(&self, job: Job) -> Receiver<Item> {
        let (out, items) = mpsc::channel();
        // A worker whose thread is gone (it can't be: it only ends when this
        // sender drops) would just yield a closed channel, read as a stall.
        let _ = self.jobs.send((job, out));
        items
    }
}

fn list_into(lister: &dyn Lister, dir: &str, out: &Sender<Item>) {
    let result = lister.list(dir, &mut |entry| {
        let item = match entry {
            Ok(raw) => item_for(lister, dir, raw),
            Err(e) => Item::Failed(e.raw_os_error()),
        };
        let failed = matches!(item, Item::Failed(_));
        out.send(item).is_ok() && !failed
    });
    let last = match result {
        Ok(()) => Item::Done,
        Err(e) => Item::Failed(e.raw_os_error()),
    };
    let _ = out.send(last);
}

/// The entry for `raw`, or that its name names nothing: a name that isn't
/// UTF-8 reaches Dart as text with U+FFFD in it, and a path holding U+FFFD is
/// kept only when it names something (then it is that thing). The whole path
/// is checked, so under a folder whose name really holds U+FFFD every entry
/// is; any error answers "nothing there". A check that never answers stalls
/// the listing, and the folder counts as not answering, which says nothing
/// about the name.
fn item_for(lister: &dyn Lister, dir: &str, raw: RawEntry) -> Item {
    let path = join(dir, &String::from_utf8_lossy(&raw.name));
    if path.contains('\u{FFFD}') && !lister.exists(&path).unwrap_or(false) {
        return Item::NamesNothing(path);
    }
    Item::Entry {
        path,
        kind: raw.kind,
    }
}

/// Can `dir` be opened and its first entry read? The check
/// `IoDirectoryReadability.inspect` makes.
fn inspect_into(lister: &dyn Lister, dir: &str, out: &Sender<Item>) {
    let mut failed = None;
    let result = lister.list(dir, &mut |entry| {
        if let Err(e) = entry {
            failed = Some(e.raw_os_error());
        }
        false
    });
    let item = match (result, failed) {
        (Err(e), _) => Item::Failed(e.raw_os_error()),
        (Ok(()), Some(errno)) => Item::Failed(errno),
        (Ok(()), None) => Item::Done,
    };
    let _ = out.send(item);
}

/// A directory's path joined to an entry name, as Dart's listing joins it
/// (no doubled separator after a trailing one).
fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

/// `Directory.absolute.path`: an absolute path as is, a relative one under
/// the current directory.
fn absolute(path: &str) -> String {
    if Path::new(path).is_absolute() {
        return path.to_owned();
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    join(&cwd.to_string_lossy(), path)
}

/// The walker: the worker currently answering, and how long to wait for it.
struct Walker {
    lister: Arc<dyn Lister>,
    worker: Worker,
    stall_limit: Duration,
}

impl Walker {
    /// Waits for the next item; a stall abandons the worker.
    fn next(&mut self, items: &Receiver<Item>) -> Option<Item> {
        match items.recv_timeout(self.stall_limit) {
            Ok(item) => Some(item),
            Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {
                self.worker = Worker::start(self.lister.clone());
                None
            }
        }
    }

    /// Why `folder` can't be listed now, `None` when it can; one that doesn't
    /// answer within the stall limit is [`Fault::Stalled`].
    fn inspect(&mut self, folder: &str) -> Option<Fault> {
        let items = self.worker.run(Job::Inspect(folder.to_owned()));
        match self.next(&items) {
            None => Some(Fault::Stalled),
            Some(Item::Failed(errno)) => Some(Fault::Io(errno)),
            Some(_) => None,
        }
    }
}

/// Walks `folder`: every file under it, depth first, with the folders it had
/// to skip and the names it couldn't use (see the module docs).
pub fn walk(
    folder: &str,
    stall_limit: Duration,
    lister: Arc<dyn Lister>,
) -> Result<Walk, WalkFailure> {
    let mut walker = Walker {
        worker: Worker::start(lister.clone()),
        lister,
        stall_limit,
    };
    let mut walk = Walk::default();
    let mut pending: Vec<String> = vec![folder.to_owned()];
    let mut is_root = true;
    while let Some(directory) = pending.pop() {
        let was_root = std::mem::replace(&mut is_root, false);
        let items = walker.worker.run(Job::List(directory.clone()));
        loop {
            match walker.next(&items) {
                Some(Item::Entry { path, kind }) => match kind {
                    Kind::Dir => pending.push(path),
                    Kind::Link => {}
                    Kind::Other => walk.paths.push(absolute(&path)),
                },
                Some(Item::NamesNothing(path)) => walk.unopenable.push(path),
                Some(Item::Done) => break,
                Some(Item::Failed(errno)) => {
                    if was_root {
                        return Err(WalkFailure::Root(Fault::Io(errno)));
                    }
                    walk.unreadable.push(absolute(&directory));
                    break;
                }
                None => {
                    if was_root {
                        return Err(WalkFailure::Root(Fault::Stalled));
                    }
                    walk.unreadable.push(absolute(&directory));
                    if let Some(fault) = walker.inspect(folder) {
                        return Err(WalkFailure::Interrupted(fault));
                    }
                    break;
                }
            }
        }
    }
    // The walk only counts if the folder was still there at its end.
    if let Some(fault) = walker.inspect(folder) {
        return Err(WalkFailure::Interrupted(fault));
    }
    Ok(walk)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// A filesystem in memory: each directory lists its entries, or fails
    /// with an errno, or never answers. A directory can change once it has
    /// been listed ([FakeFs::then]), the way a drive pulled mid-walk does,
    /// and every listing is counted.
    #[derive(Default)]
    struct FakeFs {
        dirs: Mutex<HashMap<String, Listing>>,
        after_listing: Mutex<HashMap<String, Listing>>,
        listings: Mutex<HashMap<String, usize>>,
        /// Whether asking if a name holding U+FFFD exists never answers.
        exists_stalls: bool,
    }

    #[derive(Clone)]
    enum Listing {
        Entries(Vec<(&'static [u8], Kind)>),
        Fails(i32),
        FailsAfter(Vec<(&'static [u8], Kind)>, i32),
        Stalls,
    }

    impl FakeFs {
        fn with(dirs: &[(&str, Listing)]) -> Arc<FakeFs> {
            let fs = FakeFs::default();
            for (dir, listing) in dirs {
                fs.dirs
                    .lock()
                    .unwrap()
                    .insert((*dir).to_owned(), listing.clone());
            }
            Arc::new(fs)
        }

        fn set(&self, dir: &str, listing: Listing) {
            self.dirs.lock().unwrap().insert(dir.to_owned(), listing);
        }

        /// Once `dir` has been listed, it answers with `listing` instead.
        fn then(&self, dir: &str, listing: Listing) {
            self.after_listing
                .lock()
                .unwrap()
                .insert(dir.to_owned(), listing);
        }

        /// How many times `dir` was listed (or inspected).
        fn listed(&self, dir: &str) -> usize {
            self.listings.lock().unwrap().get(dir).copied().unwrap_or(0)
        }
    }

    impl Lister for FakeFs {
        fn list(
            &self,
            dir: &str,
            sink: &mut dyn FnMut(io::Result<RawEntry>) -> bool,
        ) -> io::Result<()> {
            *self
                .listings
                .lock()
                .unwrap()
                .entry(dir.to_owned())
                .or_default() += 1;
            let listing = self.dirs.lock().unwrap().get(dir).cloned();
            if let Some(next) = self.after_listing.lock().unwrap().remove(dir) {
                self.set(dir, next);
            }
            let emit = |entries: &[(&[u8], Kind)],
                        sink: &mut dyn FnMut(io::Result<RawEntry>) -> bool| {
                for (name, kind) in entries {
                    if !sink(Ok(RawEntry {
                        name: name.to_vec(),
                        kind: *kind,
                    })) {
                        return;
                    }
                }
            };
            match listing {
                None => Err(io::Error::from_raw_os_error(2)),
                Some(Listing::Entries(entries)) => {
                    emit(&entries, sink);
                    Ok(())
                }
                Some(Listing::Fails(errno)) => Err(io::Error::from_raw_os_error(errno)),
                Some(Listing::FailsAfter(entries, errno)) => {
                    emit(&entries, sink);
                    sink(Err(io::Error::from_raw_os_error(errno)));
                    Ok(())
                }
                Some(Listing::Stalls) => loop {
                    thread::sleep(Duration::from_secs(3600));
                },
            }
        }

        fn exists(&self, _path: &str) -> io::Result<bool> {
            if self.exists_stalls {
                loop {
                    thread::sleep(Duration::from_secs(3600));
                }
            }
            Ok(false)
        }
    }

    const LIMIT: Duration = Duration::from_millis(200);

    #[test]
    fn walks_depth_first_like_dart_and_skips_links() {
        let fs = FakeFs::with(&[
            (
                "/m",
                Listing::Entries(vec![
                    (b"a.flac", Kind::Other),
                    (b"sub", Kind::Dir),
                    (b"l.flac", Kind::Link),
                    (b"z.mp3", Kind::Other),
                ]),
            ),
            ("/m/sub", Listing::Entries(vec![(b"b.flac", Kind::Other)])),
        ]);
        let walk = walk("/m", LIMIT, fs).unwrap();
        assert_eq!(walk.paths, ["/m/a.flac", "/m/z.mp3", "/m/sub/b.flac"]);
    }

    #[test]
    fn a_root_that_fails_or_stalls_fails_the_walk() {
        let fs = FakeFs::with(&[("/m", Listing::Fails(13))]);
        assert_eq!(
            walk("/m", LIMIT, fs),
            Err(WalkFailure::Root(Fault::Io(Some(13))))
        );
        let fs = FakeFs::with(&[("/m", Listing::Stalls)]);
        assert_eq!(
            walk("/m", LIMIT, fs),
            Err(WalkFailure::Root(Fault::Stalled))
        );
    }

    #[test]
    fn an_unreadable_subfolder_is_skipped_and_reported() {
        let fs = FakeFs::with(&[
            (
                "/m",
                Listing::Entries(vec![(b"bad", Kind::Dir), (b"a.flac", Kind::Other)]),
            ),
            (
                "/m/bad",
                Listing::FailsAfter(vec![(b"kept.flac", Kind::Other)], 13),
            ),
        ]);
        let walk = walk("/m", LIMIT, fs).unwrap();
        assert_eq!(walk.paths, ["/m/a.flac", "/m/bad/kept.flac"]);
        assert_eq!(walk.unreadable, ["/m/bad"]);
    }

    #[test]
    fn a_stalled_subfolder_is_skipped_while_the_folder_answers() {
        let fs = FakeFs::with(&[
            (
                "/m",
                Listing::Entries(vec![(b"share", Kind::Dir), (b"a.flac", Kind::Other)]),
            ),
            ("/m/share", Listing::Stalls),
        ]);
        let walk = walk("/m", LIMIT, fs).unwrap();
        assert_eq!(walk.paths, ["/m/a.flac"]);
        assert_eq!(walk.unreadable, ["/m/share"]);
    }

    #[test]
    fn a_folder_gone_by_the_end_interrupts_the_walk() {
        let fs = FakeFs::with(&[("/m", Listing::Entries(vec![(b"sub", Kind::Dir)]))]);
        // The subfolder fails, and by then the folder itself is gone.
        fs.set("/m/sub", Listing::Fails(5));
        let shared = fs.clone();
        let lister: Arc<dyn Lister> = fs;
        let mut walker = Walker {
            worker: Worker::start(lister.clone()),
            lister,
            stall_limit: LIMIT,
        };
        assert_eq!(walker.inspect("/m"), None);
        shared.set("/m", Listing::Fails(19));
        assert_eq!(walker.inspect("/m"), Some(Fault::Io(Some(19))));
    }

    #[test]
    fn a_folder_gone_by_the_end_fails_the_whole_walk() {
        // A drive pulled mid-walk: the subfolder still to list fails, which
        // alone would only skip it, and the folder itself is gone by the
        // check at the end. Half a walk must not pass for a whole one.
        let fs = FakeFs::with(&[
            (
                "/m",
                Listing::Entries(vec![(b"a.flac", Kind::Other), (b"sub", Kind::Dir)]),
            ),
            ("/m/sub", Listing::Fails(5)),
        ]);
        fs.then("/m", Listing::Fails(2));
        assert_eq!(
            walk("/m", LIMIT, fs),
            Err(WalkFailure::Interrupted(Fault::Io(Some(2))))
        );
    }

    #[test]
    fn a_folder_that_stops_answering_the_last_check_is_interrupted() {
        let fs = FakeFs::with(&[("/m", Listing::Entries(vec![(b"a.flac", Kind::Other)]))]);
        fs.then("/m", Listing::Stalls);
        assert_eq!(
            walk("/m", LIMIT, fs),
            Err(WalkFailure::Interrupted(Fault::Stalled))
        );
    }

    #[test]
    fn a_share_gone_after_its_top_folder_ends_the_walk_at_the_first_stall() {
        // Every folder still to list would stall, one limit after the other:
        // the folder itself is asked once, and the walk ends there.
        let fs = FakeFs::with(&[
            (
                "/m",
                Listing::Entries(vec![
                    (b"A", Kind::Dir),
                    (b"B", Kind::Dir),
                    (b"C", Kind::Dir),
                    (b"D", Kind::Dir),
                ]),
            ),
            ("/m/A", Listing::Stalls),
            ("/m/B", Listing::Stalls),
            ("/m/C", Listing::Stalls),
            ("/m/D", Listing::Stalls),
        ]);
        fs.then("/m", Listing::Stalls);
        let shared = fs.clone();
        assert_eq!(
            walk("/m", LIMIT, fs),
            Err(WalkFailure::Interrupted(Fault::Stalled))
        );
        let stalled: usize = ["/m/A", "/m/B", "/m/C", "/m/D"]
            .iter()
            .map(|d| shared.listed(d))
            .sum();
        assert_eq!(stalled, 1);
        // Listed once, then asked once whether it still answers.
        assert_eq!(shared.listed("/m"), 2);
    }

    #[test]
    fn names_that_are_not_utf8_are_reported_not_listed() {
        let fs = FakeFs::with(&[(
            "/m",
            Listing::Entries(vec![
                (b"caf\xe9.flac", Kind::Other),
                (b"bad\xffdir", Kind::Dir),
                (b"fine.flac", Kind::Other),
            ]),
        )]);
        let walk = walk("/m", LIMIT, fs).unwrap();
        assert_eq!(walk.paths, ["/m/fine.flac"]);
        assert_eq!(
            walk.unopenable,
            ["/m/caf\u{FFFD}.flac", "/m/bad\u{FFFD}dir"]
        );
        // The folder isn't unreadable: nothing under it was ever indexed.
        assert!(walk.unreadable.is_empty());
    }

    #[test]
    fn a_name_whose_check_never_answers_leaves_its_folder_unreadable() {
        // Whether a name holding U+FFFD names anything can't be told when the
        // storage stops answering: that says nothing about the name, so its
        // folder counts as not answering and what was indexed under it stays.
        let fs = Arc::new(FakeFs {
            exists_stalls: true,
            ..FakeFs::default()
        });
        fs.set("/m", Listing::Entries(vec![(b"Album", Kind::Dir)]));
        fs.set(
            "/m/Album",
            Listing::Entries(vec![(b"odd \xe8 name.flac", Kind::Other)]),
        );
        let walk = walk("/m", LIMIT, fs).unwrap();
        assert!(walk.unopenable.is_empty());
        assert_eq!(walk.unreadable, ["/m/Album"]);
    }

    #[test]
    fn joins_like_dart() {
        assert_eq!(join("/m/", "a"), "/m/a");
        assert_eq!(join("/m", "a"), "/m/a");
    }
}
