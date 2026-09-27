//! Parallel, read-only filesystem scanner with a small C ABI.
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Default)]
struct Job {
    cancelled: AtomicBool,
    files: AtomicU64,
    directories: AtomicU64,
    bytes: AtomicU64,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    status: &'static str,
    result: Option<String>,
    error: Option<String>,
}

struct Node {
    name: String,
    parent: Option<usize>,
    kind: &'static str,
    logical: u64,
    allocated: u64,
    modified: i64,
    duplicate: bool,
    excluded: bool,
    unreadable: bool,
}

struct Entry {
    name: String,
    path: PathBuf,
    metadata: std::io::Result<fs::Metadata>,
}

const METADATA_BATCH_SIZE: usize = 512;

enum Work {
    Directory(usize, PathBuf),
    Metadata(usize, PathBuf, Vec<PathBuf>),
}

enum Event {
    Batch(Work),
    Complete(DirectoryResult),
}

struct DirectoryResult {
    id: usize,
    path: PathBuf,
    entries: Vec<Entry>,
    errors: Vec<String>,
}

static JOBS: OnceLock<Mutex<HashMap<u64, Arc<Job>>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn jobs() -> &'static Mutex<HashMap<u64, Arc<Job>>> {
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn job(id: u64) -> Option<Arc<Job>> {
    jobs().lock().unwrap().get(&id).cloned()
}

fn quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn c_string(value: String) -> *mut c_char {
    CString::new(value).unwrap().into_raw()
}

/// Start scanning a UTF-8 directory path. Returns zero for invalid input.
///
/// # Safety
/// `path` must point to a valid, null-terminated C string for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn ds_scan_start(path: *const c_char) -> u64 {
    if path.is_null() {
        return 0;
    }
    let Ok(path) = CStr::from_ptr(path).to_str() else {
        return 0;
    };
    let root = PathBuf::from(path);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let job = Arc::new(Job::default());
    job.state.lock().unwrap().status = "scanning";
    jobs().lock().unwrap().insert(id, Arc::clone(&job));
    thread::spawn(move || {
        let outcome = std::panic::catch_unwind(|| scan(&root, &job));
        let mut state = job.state.lock().unwrap();
        if job.cancelled.load(Ordering::Relaxed) {
            state.status = "cancelled";
        } else {
            match outcome {
                Ok(Ok(result)) => {
                    state.result = Some(result);
                    state.status = "complete";
                }
                Ok(Err(error)) => {
                    state.error = Some(error);
                    state.status = "failed";
                }
                Err(_) => {
                    state.error = Some("Scanner worker failed".into());
                    state.status = "failed";
                }
            }
        }
    });
    id
}

#[no_mangle]
pub extern "C" fn ds_scan_poll(id: u64) -> *mut c_char {
    let Some(job) = job(id) else {
        return std::ptr::null_mut();
    };
    let state = job.state.lock().unwrap();
    c_string(format!(
        "{{\"status\":{},\"files\":{},\"directories\":{},\"allocated\":{},\"error\":{}}}",
        quote(state.status),
        job.files.load(Ordering::Relaxed),
        job.directories.load(Ordering::Relaxed),
        job.bytes.load(Ordering::Relaxed),
        state.error.as_deref().map(quote).unwrap_or("null".into())
    ))
}

/// Transfers the completed result once, avoiding a second full JSON allocation.
#[no_mangle]
pub extern "C" fn ds_scan_take_result(id: u64) -> *mut c_char {
    let Some(job) = job(id) else {
        return std::ptr::null_mut();
    };
    let result = job.state.lock().unwrap().result.take();
    result.map(c_string).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn ds_scan_cancel(id: u64) {
    if let Some(job) = job(id) {
        job.cancelled.store(true, Ordering::Relaxed);
    }
}

#[no_mangle]
pub extern "C" fn ds_scan_destroy(id: u64) {
    if let Some(job) = jobs().lock().unwrap().remove(&id) {
        job.cancelled.store(true, Ordering::Relaxed);
    }
}

/// # Safety
/// `value` must be null or a pointer returned by this library, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn ds_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

fn read_metadata(id: usize, path: PathBuf, paths: Vec<PathBuf>, job: &Job) -> DirectoryResult {
    let mut result = DirectoryResult {
        id,
        path,
        entries: Vec::with_capacity(paths.len()),
        errors: vec![],
    };
    let mut files = 0;
    for path in paths {
        if job.cancelled.load(Ordering::Relaxed) {
            break;
        }
        let metadata = fs::symlink_metadata(&path);
        if metadata.as_ref().is_ok_and(|m| !m.is_dir()) {
            files += 1;
        }
        result.entries.push(Entry {
            name: path.file_name().unwrap().to_string_lossy().into_owned(),
            path,
            metadata,
        });
    }
    job.files.fetch_add(files, Ordering::Relaxed);
    result
}

fn read_directory(
    id: usize,
    path: PathBuf,
    job: &Job,
    events: &mpsc::SyncSender<Event>,
) -> DirectoryResult {
    let mut paths = Vec::with_capacity(METADATA_BATCH_SIZE);
    let mut errors = vec![];
    match fs::read_dir(&path) {
        Ok(entries) => {
            for entry in entries {
                if job.cancelled.load(Ordering::Relaxed) {
                    break;
                }
                match entry {
                    Ok(entry) => {
                        paths.push(entry.path());
                        // Large directories can use the whole pool; small directories
                        // stay on this worker to avoid unnecessary queue traffic.
                        if paths.len() == METADATA_BATCH_SIZE {
                            let batch = std::mem::replace(
                                &mut paths,
                                Vec::with_capacity(METADATA_BATCH_SIZE),
                            );
                            if events
                                .send(Event::Batch(Work::Metadata(id, path.clone(), batch)))
                                .is_err()
                            {
                                break;
                            }
                        }
                    }
                    Err(error) => errors.push(error.to_string()),
                }
            }
        }
        Err(error) => errors.push(error.to_string()),
    }
    let mut result = read_metadata(id, path, paths, job);
    result.errors = errors;
    job.directories.fetch_add(1, Ordering::Relaxed);
    result
}

fn scan(root: &Path, job: &Arc<Job>) -> Result<String, String> {
    let started = Instant::now();
    let root = fs::canonicalize(root).map_err(|e| e.to_string())?;
    let metadata = fs::metadata(&root).map_err(|e| e.to_string())?;
    if !metadata.is_dir() {
        return Err("Select a directory or a volume".into());
    }
    let device = metadata.dev();
    let mut nodes = vec![Node {
        name: root
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or("/".into()),
        parent: None,
        kind: "directory",
        logical: 0,
        allocated: 0,
        modified: metadata.mtime(),
        duplicate: false,
        excluded: false,
        unreadable: false,
    }];
    let workers = thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .clamp(1, 8);
    let (task_tx, task_rx) = mpsc::channel::<Work>();
    let task_rx = Arc::new(Mutex::new(task_rx));
    let (result_tx, result_rx) = mpsc::sync_channel(16);
    let mut handles = vec![];
    for _ in 0..workers {
        let tasks = Arc::clone(&task_rx);
        let results = result_tx.clone();
        let job = Arc::clone(job);
        handles.push(thread::spawn(move || loop {
            let task = { tasks.lock().unwrap().recv() };
            let Ok(work) = task else { break };
            if job.cancelled.load(Ordering::Relaxed) {
                break;
            }
            let result = match work {
                Work::Directory(id, path) => read_directory(id, path, &job, &results),
                Work::Metadata(id, path, paths) => read_metadata(id, path, paths, &job),
            };
            if results.send(Event::Complete(result)).is_err() {
                break;
            }
        }));
    }
    drop(result_tx);
    task_tx
        .send(Work::Directory(0, root.clone()))
        .map_err(|e| e.to_string())?;
    let mut pending = 1usize;
    let mut hardlinks = HashSet::new();
    let mut issues: Vec<(String, String)> = vec![];
    let mut issue_count = 0usize;
    let mut excluded_count = 0usize;
    let mut duplicate_count = 0usize;
    while pending > 0 && !job.cancelled.load(Ordering::Relaxed) {
        let result = match result_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(Event::Batch(work)) => {
                task_tx.send(work).map_err(|e| e.to_string())?;
                pending += 1;
                continue;
            }
            Ok(Event::Complete(result)) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(_) => break,
        };
        pending -= 1;
        for error in result.errors {
            nodes[result.id].unreadable = true;
            issue_count += 1;
            if issues.len() < 100 {
                issues.push((result.path.to_string_lossy().into_owned(), error));
            }
        }
        let mut batch_bytes = 0;
        for entry in result.entries {
            let parent = Some(result.id);
            let m = match entry.metadata {
                Ok(m) => m,
                Err(error) => {
                    issue_count += 1;
                    if issues.len() < 100 {
                        issues.push((entry.path.to_string_lossy().into_owned(), error.to_string()));
                    }
                    nodes.push(Node {
                        name: entry.name,
                        parent,
                        kind: "unknown",
                        logical: 0,
                        allocated: 0,
                        modified: 0,
                        duplicate: false,
                        excluded: false,
                        unreadable: true,
                    });
                    continue;
                }
            };
            let directory = m.is_dir();
            let symlink = m.file_type().is_symlink();
            let special = !directory && !m.is_file() && !symlink;
            let excluded = m.dev() != device || special;
            let duplicate =
                !directory && !excluded && m.nlink() > 1 && !hardlinks.insert((m.dev(), m.ino()));
            let count_bytes = !directory && !duplicate && !excluded;
            let allocated = if count_bytes {
                m.blocks().saturating_mul(512)
            } else {
                0
            };
            let id = nodes.len();
            nodes.push(Node {
                name: entry.name,
                parent,
                kind: if directory {
                    "directory"
                } else if symlink {
                    "symlink"
                } else {
                    "file"
                },
                logical: if count_bytes { m.len() } else { 0 },
                allocated,
                modified: m.mtime(),
                duplicate,
                excluded,
                unreadable: false,
            });
            batch_bytes += allocated;
            excluded_count += usize::from(excluded);
            duplicate_count += usize::from(duplicate);
            if directory && !excluded {
                if task_tx.send(Work::Directory(id, entry.path)).is_err() {
                    break;
                }
                pending += 1;
            }
        }
        job.bytes.fetch_add(batch_bytes, Ordering::Relaxed);
    }
    drop(task_tx);
    // A cancelled coordinator must release workers blocked on the bounded queue.
    drop(result_rx);
    for handle in handles {
        if handle.join().is_err() {
            return Err("Scanner worker failed".into());
        }
    }
    if job.cancelled.load(Ordering::Relaxed) {
        return Err("Cancelled".into());
    }
    if pending != 0 {
        return Err("Scanner stopped before traversal completed".into());
    }
    for i in (1..nodes.len()).rev() {
        if let Some(parent) = nodes[i].parent {
            nodes[parent].logical = nodes[parent].logical.saturating_add(nodes[i].logical);
            nodes[parent].allocated = nodes[parent].allocated.saturating_add(nodes[i].allocated);
        }
    }
    let mut json = format!(
        "{{\"rootPath\":{},\"elapsed\":{},\"fileCount\":{},\"directoryCount\":{},\"issueCount\":{},\"excludedCount\":{},\"duplicateCount\":{},\"nodes\":[",
        quote(&root.to_string_lossy()), started.elapsed().as_secs_f64(),
        job.files.load(Ordering::Relaxed), job.directories.load(Ordering::Relaxed),
        issue_count, excluded_count, duplicate_count
    );
    use std::fmt::Write;
    for (id, node) in nodes.iter().enumerate() {
        if id > 0 {
            json.push(',');
        }
        write!(&mut json,
            "{{\"id\":{},\"name\":{},\"parent\":{},\"kind\":{},\"logical\":{},\"allocated\":{},\"modified\":{},\"duplicate\":{},\"excluded\":{},\"unreadable\":{}}}",
            id, quote(&node.name), node.parent.map(|p| p.to_string()).unwrap_or("null".into()),
            quote(node.kind), node.logical, node.allocated, node.modified, node.duplicate, node.excluded, node.unreadable
        ).unwrap();
    }
    json.push_str("],\"issues\":[");
    for (i, (path, message)) in issues.iter().enumerate() {
        if i > 0 {
            json.push(',');
        }
        write!(
            &mut json,
            "{{\"path\":{},\"message\":{}}}",
            quote(path),
            quote(message)
        )
        .unwrap();
    }
    json.push_str("]}");
    Ok(json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "diskscope-test-{}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn scan(&self) -> String {
            scan(&self.0, &Arc::new(Job::default())).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn nested_totals_and_symlink_cycles() {
        let f = Fixture::new();
        fs::create_dir(f.0.join("nested")).unwrap();
        fs::write(f.0.join("a.txt"), b"12345").unwrap();
        fs::write(f.0.join("nested/b.txt"), b"1234567").unwrap();
        symlink(&f.0, f.0.join("nested/loop")).unwrap();
        let result = f.scan();
        assert!(result.contains("\"fileCount\":3"));
        assert!(result.contains("\"directoryCount\":2"));
        assert!(result.contains("\"kind\":\"symlink\""));
    }

    #[test]
    fn hardlinks_count_once() {
        let f = Fixture::new();
        fs::write(f.0.join("a"), b"1234567").unwrap();
        fs::hard_link(f.0.join("a"), f.0.join("b")).unwrap();
        let result = f.scan();
        assert!(result.contains("\"duplicateCount\":1"));
        assert_eq!(result.matches("\"logical\":7").count(), 2);
        assert!(result.contains("\"duplicate\":true"));
    }

    #[test]
    fn sparse_file_uses_allocated_blocks() {
        let f = Fixture::new();
        let file = fs::File::create(f.0.join("sparse")).unwrap();
        file.set_len(128 * 1024 * 1024).unwrap();
        let result = f.scan();
        let m = file.metadata().unwrap();
        assert!(m.blocks() * 512 < m.len());
        assert!(result.contains("\"logical\":134217728"));
        assert!(result.contains(&format!("\"allocated\":{}", m.blocks() * 512)));
    }

    #[test]
    fn empty_directory_and_invalid_root() {
        let f = Fixture::new();
        assert!(f.scan().contains("\"fileCount\":0"));
        assert!(scan(&f.0.join("missing"), &Arc::new(Job::default())).is_err());
    }

    #[test]
    fn cancellation_stops_scan() {
        let f = Fixture::new();
        let job = Arc::new(Job::default());
        job.cancelled.store(true, Ordering::Relaxed);
        assert_eq!(scan(&f.0, &job).unwrap_err(), "Cancelled");
    }

    #[test]
    fn json_escaping() {
        assert_eq!(
            quote("a\"b\\c\n\t\0日本語"),
            "\"a\\\"b\\\\c\\n\\t\\u0000日本語\""
        );
    }

    #[test]
    fn ffi_lifecycle_transfers_result_once() {
        let f = Fixture::new();
        let path = CString::new(f.0.to_str().unwrap()).unwrap();
        let id = unsafe { ds_scan_start(path.as_ptr()) };
        assert_ne!(id, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let ptr = ds_scan_poll(id);
            let status = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_owned() };
            unsafe {
                ds_string_free(ptr);
            }
            if status.contains("complete") {
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        let result = ds_scan_take_result(id);
        assert!(!result.is_null());
        unsafe {
            ds_string_free(result);
        }
        assert!(ds_scan_take_result(id).is_null());
        ds_scan_destroy(id);
        assert!(ds_scan_poll(id).is_null());
    }
    #[test]
    fn metadata_batches_preserve_totals_and_nested_directories() {
        for count in [511, 512, 513, 1024, 1300] {
            let f = Fixture::new();
            for index in 0..count {
                fs::write(f.0.join(format!("file-{index}")), b"x").unwrap();
            }
            fs::create_dir(f.0.join("nested")).unwrap();
            fs::write(f.0.join("nested/leaf"), b"1234567").unwrap();
            let result = f.scan();
            assert!(result.contains(&format!("\"fileCount\":{}", count + 1)));
            assert!(result.contains("\"directoryCount\":2"));
            let root = result.split("},{").next().unwrap();
            assert!(root.contains(&format!("\"logical\":{},", count + 7)));
        }
    }

    #[test]
    fn cancellation_during_batched_scan_releases_workers() {
        let f = Fixture::new();
        for index in 0..8192 {
            fs::File::create(f.0.join(format!("file-{index}"))).unwrap();
        }
        let state = Arc::new(Job::default());
        let worker_state = Arc::clone(&state);
        let root = f.0.clone();
        let (tx, rx) = mpsc::channel();
        let handle = thread::spawn(move || {
            tx.send(scan(&root, &worker_state)).unwrap();
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while state.files.load(Ordering::Relaxed) == 0 && Instant::now() < deadline {
            thread::yield_now();
        }
        state.cancelled.store(true, Ordering::Relaxed);
        match rx.recv_timeout(Duration::from_secs(5)).unwrap() {
            Err(error) => assert_eq!(error, "Cancelled"),
            // Completion can win the race before this thread is scheduled again.
            Ok(result) => assert!(result.contains("\"fileCount\":8192")),
        }
        handle.join().unwrap();
    }
}
