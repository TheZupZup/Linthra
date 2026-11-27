//! What a scan reads about each file the walk listed: its stamp (size and
//! mtime), whether a file it could not read is really gone, and the bytes of
//! a CUE sheet, for `NativeLocalFileStatReader` and `readScanFile`
//! (lib/core/sources/local/native_file_reads.dart).
//!
//! A stamp decides whether a file needs parsing again; one that can't be
//! read is no stamp, and the file is parsed. A file the walk listed and then
//! couldn't read may have been moved or deleted, or its drive may have gone
//! away, or its storage may be failing for a moment. Only the first is
//! "gone", and the evidence for it is the one a later walk would have: the
//! folder it was in answers, and answers without it.
//!
//! Each call can land on storage that stopped answering, and a blocked
//! `stat` or `read` can't be interrupted. So each runs on a worker thread of
//! its own, and the caller waits at most `stall_limit` for it, as Dart's
//! `.timeout` does; a worker that doesn't answer is left blocked where it is,
//! and the next call takes another.

use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// What `stat` says about a path, following links.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Meta {
    pub is_file: bool,
    pub size: i64,
    pub modified_ms: i64,
}

/// A file's size and last-modified time, as `LocalFileStamp` holds them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub size: i64,
    pub modified_ms: i64,
}

/// The filesystem as these reads see it, so tests can make it fail or stall.
pub trait Files: Send + Sync + 'static {
    /// `stat`, following links.
    fn stat(&self, path: &str) -> io::Result<Meta>;

    /// Lists `dir`'s names, handing each to `sink` as it is read; stops early
    /// when `sink` returns false.
    fn names(&self, dir: &str, sink: &mut dyn FnMut(io::Result<Vec<u8>>) -> bool)
        -> io::Result<()>;

    /// The whole file.
    fn read(&self, path: &str) -> io::Result<Vec<u8>>;
}

/// The real filesystem.
pub struct SystemFiles;

impl Files for SystemFiles {
    fn stat(&self, path: &str) -> io::Result<Meta> {
        use std::os::unix::fs::MetadataExt;
        let meta = std::fs::metadata(path)?;
        Ok(Meta {
            is_file: meta.is_file(),
            size: meta.size() as i64,
            // As the Dart VM converts st_mtim: whole milliseconds, truncated.
            modified_ms: meta.mtime() * 1000 + meta.mtime_nsec() / 1_000_000,
        })
    }

    fn names(
        &self,
        dir: &str,
        sink: &mut dyn FnMut(io::Result<Vec<u8>>) -> bool,
    ) -> io::Result<()> {
        use std::os::unix::ffi::OsStrExt;
        for entry in std::fs::read_dir(dir)? {
            if !sink(entry.map(|e| e.file_name().as_bytes().to_vec())) {
                break;
            }
        }
        Ok(())
    }

    fn read(&self, path: &str) -> io::Result<Vec<u8>> {
        std::fs::read(path)
    }
}

/// A thread that runs one call at a time. Kept for the next call once it
/// answers, abandoned to its blocked call when it doesn't.
struct Worker {
    jobs: Sender<Box<dyn FnOnce() + Send>>,
}

impl Worker {
    fn start() -> Option<Worker> {
        let (jobs, inbox) = mpsc::channel::<Box<dyn FnOnce() + Send>>();
        thread::Builder::new()
            .name("linthra-file-read".to_owned())
            .spawn(move || {
                for job in inbox {
                    job();
                }
            })
            .ok()?;
        Some(Worker { jobs })
    }
}

/// Workers that answered their last call, ready for the next. Starting a
/// thread per call would cost more than the `stat` it runs.
static IDLE: Mutex<Vec<Worker>> = Mutex::new(Vec::new());

/// How many idle workers are kept; calls only overlap when callers run
/// several at once.
const MAX_IDLE: usize = 8;

fn idle() -> std::sync::MutexGuard<'static, Vec<Worker>> {
    IDLE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Runs `job` on a worker of its own and waits at most `stall_limit` for
/// it. `None` when it didn't answer, or no thread could be started.
fn bounded<T: Send + 'static>(
    stall_limit: Duration,
    job: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let worker = match idle().pop() {
        Some(worker) => worker,
        None => Worker::start()?,
    };
    let (out, answer) = mpsc::channel();
    worker
        .jobs
        .send(Box::new(move || {
            let _ = out.send(job());
        }))
        .ok()?;
    let value = answer.recv_timeout(stall_limit).ok()?;
    let mut idle = idle();
    if idle.len() < MAX_IDLE {
        idle.push(worker);
    }
    Some(value)
}

/// The stamp of the file at `path`, or `None` when it isn't a file, can't be
/// stat'ed, or the `stat` doesn't answer.
pub fn stamp(files: Arc<dyn Files>, path: &str, stall_limit: Duration) -> Option<Stamp> {
    let path = path.to_owned();
    stamp_of(bounded(stall_limit, move || files.stat(&path))?)
}

/// [`stamp`] for each of `paths`, in order, in one go: one thread reads them
/// one after another, and each next stamp gets `stall_limit`.
///
/// A `stat` that doesn't answer ends the batch, with `None` for its path:
/// the rest would most likely stall the same way, one limit each, and the
/// caller asks for them one by one, as it would have without the batch.
pub fn stamps(
    files: Arc<dyn Files>,
    paths: Vec<String>,
    stall_limit: Duration,
) -> Vec<Option<Stamp>> {
    let count = paths.len();
    let mut stamps = Vec::with_capacity(count);
    let (out, answers) = mpsc::channel();
    let started = thread::Builder::new()
        .name("linthra-file-stamps".to_owned())
        .spawn(move || {
            for path in &paths {
                if out.send(files.stat(path)).is_err() {
                    return;
                }
            }
        });
    if started.is_err() {
        return stamps;
    }
    while stamps.len() < count {
        match answers.recv_timeout(stall_limit) {
            Ok(meta) => stamps.push(stamp_of(meta)),
            Err(_) => {
                stamps.push(None);
                break;
            }
        }
    }
    stamps
}

fn stamp_of(meta: io::Result<Meta>) -> Option<Stamp> {
    let meta = meta.ok()?;
    meta.is_file.then_some(Stamp {
        size: meta.size,
        modified_ms: meta.modified_ms,
    })
}

/// The bytes of the file at `path`, or `None` when it can't be read in full
/// within `stall_limit`, as the CUE read in `_scanFiles` gives up on a sheet.
pub fn read(files: Arc<dyn Files>, path: &str, stall_limit: Duration) -> Option<Vec<u8>> {
    let path = path.to_owned();
    bounded(stall_limit, move || files.read(&path))?.ok()
}

/// Whether `path`, inside the selected folder `root`, is gone, because the
/// nearest folder on the way up to `root` that can be listed answers without
/// it. A folder that renamed or moved away is gone the same way, from the
/// folder above it. False whenever that can't be shown: no folder up to
/// `root` answers (a drive that went away), or the folder still lists `path`
/// (a read that failed for a moment).
pub fn is_gone(files: Arc<dyn Files>, path: &str, root: &str, stall_limit: Duration) -> bool {
    let top = normalize(root);
    let mut child = normalize(path);
    if !is_within(&top, &child) {
        return false;
    }
    loop {
        let (folder, name) = split_last(&child);
        if let Some(names) = names_in(&files, &folder, stall_limit) {
            return !names.contains(&name);
        }
        if !is_within(&top, &folder) {
            return false;
        }
        child = folder;
    }
}

/// The names `folder` lists, as Dart has them (a name that isn't UTF-8 with
/// U+FFFD in it), or `None` when it can't be listed in full. Each next name
/// gets `stall_limit`.
fn names_in(
    files: &Arc<dyn Files>,
    folder: &str,
    stall_limit: Duration,
) -> Option<HashSet<String>> {
    let (out, items) = mpsc::channel::<Option<io::Result<Vec<u8>>>>();
    let files = files.clone();
    let dir = folder.to_owned();
    thread::Builder::new()
        .spawn(move || {
            let result = files.names(&dir, &mut |name| out.send(Some(name)).is_ok());
            let _ = out.send(match result {
                Ok(()) => None,
                Err(e) => Some(Err(e)),
            });
        })
        .ok()?;
    let mut names = HashSet::new();
    loop {
        match items.recv_timeout(stall_limit) {
            Ok(Some(Ok(name))) => {
                names.insert(String::from_utf8_lossy(&name).into_owned());
            }
            Ok(None) => return Some(names),
            Ok(Some(Err(_))) => return None,
            Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => return None,
        }
    }
}

/// A normalized path that isn't `/`, split into its folder and its last
/// name: `p.dirname` and `p.basename`.
fn split_last(path: &str) -> (String, String) {
    match path.rfind('/') {
        Some(0) => ("/".to_owned(), path[1..].to_owned()),
        Some(i) => (path[..i].to_owned(), path[i + 1..].to_owned()),
        None => (".".to_owned(), path.to_owned()),
    }
}

/// `p.normalize` on POSIX: `.` and empty parts dropped, `..` resolved where
/// it can be (and dropped at the root), no trailing separator.
pub fn normalize(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    let mut leading_doubles = 0;
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    leading_doubles += 1;
                }
            }
            _ => parts.push(part),
        }
    }
    let mut out: Vec<&str> = Vec::new();
    if !absolute {
        out.extend(std::iter::repeat_n("..", leading_doubles));
    }
    out.extend(parts);
    if absolute {
        format!("/{}", out.join("/"))
    } else if out.is_empty() {
        ".".to_owned()
    } else {
        out.join("/")
    }
}

/// `p.isWithin` for two normalized paths: whether `child` is strictly inside
/// `parent`. A relative one is taken from the current directory first, as
/// `p.isWithin` does whenever the two differ.
pub fn is_within(parent: &str, child: &str) -> bool {
    let parent = from_current(parent);
    let child = from_current(child);
    if parent == "/" {
        return child != "/";
    }
    child.len() > parent.len()
        && child.starts_with(&parent)
        && child.as_bytes()[parent.len()] == b'/'
}

fn from_current(path: &str) -> String {
    if Path::new(path).is_absolute() {
        return path.to_owned();
    }
    let cwd = std::env::current_dir()
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "/".to_owned());
    normalize(&format!("{cwd}/{path}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Clone)]
    enum Entry {
        File(i64, i64),
        Dir(Vec<&'static str>),
        Unlistable,
        Stalls,
    }

    /// A filesystem in memory, keyed by path.
    #[derive(Default)]
    struct FakeFiles {
        entries: Mutex<HashMap<String, Entry>>,
    }

    impl FakeFiles {
        fn with(entries: &[(&str, Entry)]) -> Arc<FakeFiles> {
            let fake = FakeFiles::default();
            for (path, entry) in entries {
                fake.entries
                    .lock()
                    .unwrap()
                    .insert((*path).to_owned(), entry.clone());
            }
            Arc::new(fake)
        }

        fn get(&self, path: &str) -> Option<Entry> {
            self.entries.lock().unwrap().get(path).cloned()
        }
    }

    fn stall() -> ! {
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    }

    impl Files for FakeFiles {
        fn stat(&self, path: &str) -> io::Result<Meta> {
            match self.get(path) {
                None => Err(io::Error::from_raw_os_error(2)),
                Some(Entry::File(size, modified_ms)) => Ok(Meta {
                    is_file: true,
                    size,
                    modified_ms,
                }),
                Some(Entry::Stalls) => stall(),
                Some(_) => Ok(Meta {
                    is_file: false,
                    size: 4096,
                    modified_ms: 0,
                }),
            }
        }

        fn names(
            &self,
            dir: &str,
            sink: &mut dyn FnMut(io::Result<Vec<u8>>) -> bool,
        ) -> io::Result<()> {
            match self.get(dir) {
                Some(Entry::Dir(names)) => {
                    for name in names {
                        if !sink(Ok(name.as_bytes().to_vec())) {
                            break;
                        }
                    }
                    Ok(())
                }
                Some(Entry::Stalls) => stall(),
                Some(Entry::Unlistable) => Err(io::Error::from_raw_os_error(5)),
                _ => Err(io::Error::from_raw_os_error(2)),
            }
        }

        fn read(&self, path: &str) -> io::Result<Vec<u8>> {
            match self.get(path) {
                Some(Entry::File(..)) => Ok(path.as_bytes().to_vec()),
                Some(Entry::Stalls) => stall(),
                _ => Err(io::Error::from_raw_os_error(21)),
            }
        }
    }

    const LIMIT: Duration = Duration::from_millis(50);

    #[test]
    fn stamps_files_only() {
        let fs = FakeFiles::with(&[
            ("/m/a.flac", Entry::File(10, 1234)),
            ("/m", Entry::Dir(vec!["a.flac"])),
        ]);
        assert_eq!(
            stamp(fs.clone(), "/m/a.flac", LIMIT),
            Some(Stamp {
                size: 10,
                modified_ms: 1234
            })
        );
        assert_eq!(stamp(fs.clone(), "/m", LIMIT), None);
        assert_eq!(stamp(fs, "/m/missing.flac", LIMIT), None);
    }

    #[test]
    fn a_stat_that_never_answers_is_no_stamp() {
        let fs = FakeFiles::with(&[("/m/a.flac", Entry::Stalls)]);
        assert_eq!(stamp(fs, "/m/a.flac", LIMIT), None);
    }

    #[test]
    fn stamps_in_one_go_until_one_stalls() {
        let fs = FakeFiles::with(&[
            ("/m/a.flac", Entry::File(1, 10)),
            ("/m/b.flac", Entry::File(2, 20)),
            ("/m/stuck.flac", Entry::Stalls),
            ("/m", Entry::Dir(vec![])),
        ]);
        let paths = |names: &[&str]| names.iter().map(|n| format!("/m/{n}")).collect();
        let a = Some(Stamp {
            size: 1,
            modified_ms: 10,
        });
        let b = Some(Stamp {
            size: 2,
            modified_ms: 20,
        });
        assert_eq!(
            stamps(
                fs.clone(),
                paths(&["a.flac", "", "missing", "b.flac"]),
                LIMIT
            ),
            vec![a, None, None, b]
        );
        // Stops at the stall: the rest are asked one by one.
        assert_eq!(
            stamps(
                fs.clone(),
                paths(&["a.flac", "stuck.flac", "b.flac"]),
                LIMIT
            ),
            vec![a, None]
        );
        assert_eq!(stamps(fs, Vec::new(), LIMIT), vec![]);
    }

    #[test]
    fn reads_or_gives_up() {
        let fs = FakeFiles::with(&[
            ("/m/a.cue", Entry::File(1, 1)),
            ("/m/stuck.cue", Entry::Stalls),
            ("/m/dir.cue", Entry::Dir(vec![])),
        ]);
        assert_eq!(
            read(fs.clone(), "/m/a.cue", LIMIT),
            Some(b"/m/a.cue".to_vec())
        );
        assert_eq!(read(fs.clone(), "/m/stuck.cue", LIMIT), None);
        assert_eq!(read(fs, "/m/dir.cue", LIMIT), None);
    }

    #[test]
    fn gone_when_the_nearest_listable_folder_lacks_it() {
        // Listed by its folder: there.
        let fs = FakeFiles::with(&[
            ("/m", Entry::Dir(vec!["A"])),
            ("/m/A", Entry::Dir(vec!["a.flac"])),
        ]);
        assert!(!is_gone(fs.clone(), "/m/A/a.flac", "/m", LIMIT));
        // Its folder answers without it: gone.
        assert!(is_gone(fs.clone(), "/m/A/b.flac", "/m", LIMIT));
        // Its folder moved away: gone, from the folder above.
        assert!(is_gone(fs, "/m/B/a.flac", "/m", LIMIT));
    }

    #[test]
    fn not_gone_when_it_cannot_be_shown() {
        // An unlistable folder whose parent still lists it.
        let fs = FakeFiles::with(&[("/m", Entry::Dir(vec!["A"])), ("/m/A", Entry::Unlistable)]);
        assert!(!is_gone(fs, "/m/A/a.flac", "/m", LIMIT));
        // Nothing up to the root answers: a drive that went away.
        let fs = FakeFiles::with(&[("/", Entry::Dir(vec![]))]);
        assert!(!is_gone(fs, "/m/A/a.flac", "/m", LIMIT));
        // Storage that stopped answering.
        let fs = FakeFiles::with(&[("/m", Entry::Stalls), ("/m/A", Entry::Stalls)]);
        assert!(!is_gone(fs, "/m/A/a.flac", "/m", LIMIT));
        // Outside the selected folder, or the folder itself.
        let fs = FakeFiles::with(&[("/", Entry::Dir(vec![])), ("/m", Entry::Dir(vec![]))]);
        assert!(!is_gone(fs.clone(), "/other.flac", "/m", LIMIT));
        assert!(!is_gone(fs, "/m", "/m", LIMIT));
    }

    #[test]
    fn normalizes_as_the_path_package() {
        for (input, expected) in [
            ("", "."),
            (".", "."),
            ("/", "/"),
            ("//", "/"),
            ("/..", "/"),
            ("/a/../..", "/"),
            ("/a/./b//c/", "/a/b/c"),
            ("/a/b/../c", "/a/c"),
            ("a/..", "."),
            ("a/../..", ".."),
            ("../../a", "../../a"),
            ("./a/", "a"),
        ] {
            assert_eq!(normalize(input), expected, "{input:?}");
        }
    }

    #[test]
    fn within_is_strict() {
        assert!(is_within("/m", "/m/a"));
        assert!(is_within("/", "/m"));
        assert!(!is_within("/m", "/m"));
        assert!(!is_within("/m", "/ma"));
        assert!(!is_within("/m/a", "/m"));
        assert!(!is_within("/", "/"));
    }
}
