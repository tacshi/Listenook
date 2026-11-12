//! Speech on this machine: the models on disk and their downloads, Qwen3
//! and its word aligner run in the app (the `qwen-asr` crate), MOSS run by
//! the Swift helper, and what a job asks of them — a transcript, and word
//! timing for a transcript.

use std::{
    cell::RefCell,
    collections::{BTreeMap, HashMap},
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};

use listenook_core::{
    Document, Job, TranscriptionProvider, audio,
    local::{self, Model, Word},
};
use nsh_core::prelude::*;
use qwen_asr::{
    align,
    context::{QwenCtx, QwenModel},
    transcribe,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(crate) use listenook_core::local as catalog;

use super::remote::Failure;
use crate::state::{Store, persist, store};

/// The longest recording the local models take.
const MAX_DURATION_MS: i64 = 300 * 60 * 1000;

// --- The worker -----------------------------------------------------------------

/// The worker program: `LISTENOOK_SPEECH_WORKER`, else the app bundle's
/// `Helpers/ListenookSpeechWorker`.
fn worker_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("LISTENOOK_SPEECH_WORKER").map(PathBuf::from) {
        return path.is_file().then_some(path);
    }
    let exe = std::env::current_exe().ok()?;
    let bundled = exe.parent()?.parent()?.join("Helpers/ListenookSpeechWorker");
    bundled.is_file().then_some(bundled)
}

/// Whether this machine can run MOSS: the helper is here and the chip is Apple's.
fn worker_supported() -> bool {
    cfg!(all(target_os = "macos", target_arch = "aarch64")) && worker_path().is_some()
}

/// Whether this build runs Qwen3 and word timing in the app: every one does.
pub(crate) fn supported() -> bool {
    true
}

static BUSY: AtomicBool = AtomicBool::new(false);
static TURN: AtomicBool = AtomicBool::new(false);

thread_local! {
    static STOPS: RefCell<HashMap<&'static str, Arc<AtomicBool>>> = RefCell::new(HashMap::new());
}

/// The one worker lane: models are too large to run two at once. It is
/// free again when this is dropped, which may be on another thread.
pub(crate) struct Lane(&'static AtomicBool);

impl Lane {
    async fn of(flag: &'static AtomicBool) -> Lane {
        while flag.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
            timer(Duration::from_millis(300)).await;
        }
        Lane(flag)
    }

    async fn take() -> Lane {
        Self::of(&BUSY).await
    }

    /// A recording's turn at being transcribed here, from decoding its
    /// audio on: recordings waiting in line hold no audio in memory.
    pub(crate) async fn turn() -> Lane {
        Self::of(&TURN).await
    }
}

impl Drop for Lane {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// Stops the worker when the work that asked for it is dropped.
struct Stop {
    pid: Arc<AtomicU32>,
    done: Arc<AtomicBool>,
}

impl Drop for Stop {
    fn drop(&mut self) {
        let (pid, done) = (self.pid.load(Ordering::Relaxed), self.done.clone());
        if pid == 0 || done.load(Ordering::Relaxed) {
            return;
        }
        std::thread::spawn(move || {
            let signal = |name: &str| drop(Command::new("/bin/kill").args([name, &pid.to_string()]).output());
            signal("-TERM");
            std::thread::sleep(Duration::from_secs(2));
            if !done.load(Ordering::Relaxed) {
                signal("-KILL");
            }
        });
    }
}

fn temporary() -> PathBuf {
    let directory = persist::data_root().map_or_else(std::env::temp_dir, |root| root.join("temporary"));
    let _ = std::fs::create_dir_all(&directory);
    directory
}

fn private(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

const NO_FRACTION: u64 = u64::MAX;

fn run_worker(
    program: &Path,
    command: &str,
    request: &Value,
    pid: &AtomicU32,
    fraction: &AtomicU64,
) -> Result<Value, Failure> {
    let stamp = format!("speech-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple());
    let directory = temporary();
    let (request_path, output_path) =
        (directory.join(format!("{stamp}-request.json")), directory.join(format!("{stamp}-output.json")));
    let launch = |error: std::io::Error| Failure::new("local_worker_launch_failed", error.to_string());
    std::fs::write(&request_path, serde_json::to_vec(request).unwrap_or_default()).map_err(launch)?;
    std::fs::write(&output_path, b"").map_err(launch)?;
    private(&request_path);
    private(&output_path);
    let result = (|| {
        let mut child = Command::new(program)
            .arg(command)
            .arg("--request")
            .arg(&request_path)
            .arg("--output")
            .arg(&output_path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(launch)?;
        pid.store(child.id(), Ordering::Relaxed);
        if let Some(stdout) = child.stdout.take() {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(event) = serde_json::from_str::<Value>(&line)
                    && event["event"] == "progress"
                {
                    let value = event["fraction"].as_f64().map_or(NO_FRACTION, |f| f.clamp(0.0, 1.0).to_bits());
                    fraction.store(value, Ordering::Relaxed);
                }
            }
        }
        let status = child.wait().map_err(launch)?;
        let output: Value = serde_json::from_slice(&std::fs::read(&output_path).unwrap_or_default())
            .map_err(|e| Failure::new("local_worker_invalid_output", format!("{status}: {e}")))?;
        if status.success() && output["ok"] == true {
            return Ok(output["result"].clone());
        }
        let error = &output["error"];
        Err(Failure::new(
            error["code"].as_str().unwrap_or("local_worker_failed"),
            error["message"].as_str().unwrap_or("The speech worker failed."),
        ))
    })();
    let _ = std::fs::remove_file(&request_path);
    let _ = std::fs::remove_file(&output_path);
    result
}

/// Runs the worker once and gives its result. `progress` hears how far it
/// is, where the worker says. Dropping the future stops the worker.
async fn worker(command: &'static str, mut request: Value, progress: impl Fn(f64) + 'static) -> Result<Value, Failure> {
    let program =
        worker_path().ok_or_else(|| Failure::new("local_worker_missing", "The speech worker is not installed."))?;
    let _lane = Lane::take().await;
    request["protocol"] = json!(1);
    request["parent_pid"] = json!(std::process::id());
    let (pid, done) = (Arc::new(AtomicU32::new(0)), Arc::new(AtomicBool::new(false)));
    let fraction = Arc::new(AtomicU64::new(NO_FRACTION));
    let _stop = Stop { pid: pid.clone(), done: done.clone() };
    let seen = fraction.clone();
    let _watcher = super::Ends::with(spawn(async move {
        loop {
            timer(Duration::from_millis(400)).await;
            let bits = seen.load(Ordering::Relaxed);
            if bits != NO_FRACTION {
                progress(f64::from_bits(bits));
            }
        }
    }));
    let result = blocking(move || {
        let result = run_worker(&program, command, &request, &pid, &fraction);
        done.store(true, Ordering::Relaxed);
        result
    })
    .await;
    result.unwrap_or_else(|_| Err(Failure::new("local_worker_failed", "The speech worker stopped.")))
}

// --- Models ---------------------------------------------------------------------

/// Where a model stands on this machine.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ModelState {
    Missing,
    /// Part of it is here from a download that stopped.
    Partial,
    /// Downloading: how far, 0–1.
    Downloading(f64),
    Ready,
}

/// What the app shows of the models: downloads under way and what they
/// last failed with. Reading it subscribes to every change on disk too.
#[derive(Debug, Clone, Default, PartialEq)]
struct Models {
    changes: u32,
    downloading: BTreeMap<&'static str, f64>,
    failed: BTreeMap<&'static str, String>,
}

fn models_root() -> Option<PathBuf> {
    persist::data_root().map(|root| root.join("models"))
}

fn directory_of(model: &Model) -> Option<PathBuf> {
    models_root().map(|root| root.join(model.id))
}

fn installed(model: &Model) -> bool {
    let Some(directory) = directory_of(model) else {
        return false;
    };
    let verified: Option<Value> =
        std::fs::read(directory.join(".verified.json")).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok());
    verified.is_some_and(|verified| verified["revision"] == model.revision)
        && model
            .files
            .iter()
            .all(|file| std::fs::metadata(directory.join(file.path)).is_ok_and(|found| found.len() == file.size))
}

/// Where a model stands. Tracked: bindings rerun as downloads move.
pub(crate) fn model_state(model: &'static Model) -> ModelState {
    if let Some(fraction) = global::<Models>().with(|models| models.downloading.get(model.id).copied()) {
        return ModelState::Downloading(fraction);
    }
    if installed(model) {
        ModelState::Ready
    } else if models_root().is_some_and(|root| root.join(format!(".{}.part", model.id)).is_dir()) {
        ModelState::Partial
    } else {
        ModelState::Missing
    }
}

/// The code a model's last download failed with.
pub(crate) fn model_error(model: &'static Model) -> Option<String> {
    global::<Models>().with(|models| models.failed.get(model.id).cloned())
}

/// Whether a provider runs on this machine rather than in the cloud.
pub(crate) fn is_local(provider: TranscriptionProvider) -> bool {
    matches!(provider, TranscriptionProvider::MossLocal | TranscriptionProvider::Qwen3Local)
}

/// Whether this build can offer a local provider at all.
pub(crate) fn offered(provider: TranscriptionProvider) -> bool {
    match provider {
        TranscriptionProvider::MossLocal => worker_supported(),
        TranscriptionProvider::Qwen3Local => supported(),
        _ => false,
    }
}

/// The Qwen3 model to transcribe with: the one settings name if it is
/// here, else the one that is here, the smaller first.
fn qwen3_model() -> &'static Model {
    let large = store().setting(|s| s.extra.get("qwen3_local_model").and_then(Value::as_str) == Some("1.7b"));
    match (installed(&local::QWEN3), installed(&local::QWEN3_LARGE)) {
        (true, true) if large => &local::QWEN3_LARGE,
        (false, true) => &local::QWEN3_LARGE,
        _ => &local::QWEN3,
    }
}

/// Whether a local provider has what it needs. Tracked, as `model_state`.
pub(crate) fn provider_ready(provider: TranscriptionProvider) -> bool {
    global::<Models>().with(|_| ());
    offered(provider)
        && match provider {
            TranscriptionProvider::MossLocal => installed(&local::MOSS),
            _ => installed(qwen3_model()) && installed(&local::ALIGNER),
        }
}

fn fetch_model(model: &Model, root: &Path, received: &AtomicU64, stop: &AtomicBool) -> Result<(), String> {
    let io = |error: std::io::Error| format!("model_download_failed: {error}");
    let staging = root.join(format!(".{}.part", model.id));
    let mut buffer = vec![0_u8; 256 * 1024];
    let mut before = 0_u64;
    for file in model.files {
        let staged = staging.join(file.path);
        if std::fs::metadata(&staged).is_ok_and(|found| found.len() == file.size) {
            before += file.size;
            received.store(before, Ordering::Relaxed);
            continue;
        }
        if let Some(parent) = staged.parent() {
            std::fs::create_dir_all(parent).map_err(io)?;
        }
        let part = PathBuf::from(format!("{}.part", staged.display()));
        let mut have = std::fs::metadata(&part).map_or(0, |found| found.len());
        if have > file.size {
            let _ = std::fs::remove_file(&part);
            have = 0;
        }
        if have < file.size {
            let mut request = super::http().get(&model.url(file)).set("User-Agent", "Listenook");
            if have > 0 {
                request = request.set("Range", &format!("bytes={have}-"));
            }
            let response = request.call().map_err(|error| format!("model_download_failed: {error}"))?;
            let resumed = response.status() == 206;
            if !resumed {
                have = 0;
            }
            let mut out = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .append(resumed)
                .truncate(!resumed)
                .open(&part)
                .map_err(io)?;
            let mut reader = response.into_reader();
            loop {
                if stop.load(Ordering::Relaxed) {
                    return Err("cancelled".into());
                }
                let read = reader.read(&mut buffer).map_err(io)?;
                if read == 0 {
                    break;
                }
                out.write_all(&buffer[..read]).map_err(io)?;
                have += read as u64;
                received.store(before + have, Ordering::Relaxed);
            }
            out.flush().map_err(io)?;
        }
        if have != file.size {
            let _ = std::fs::remove_file(&part);
            return Err("model_size_mismatch".into());
        }
        let mut hasher = Sha256::new();
        let mut reader = std::fs::File::open(&part).map_err(io)?;
        loop {
            if stop.load(Ordering::Relaxed) {
                return Err("cancelled".into());
            }
            let read = reader.read(&mut buffer).map_err(io)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        let digest: String = hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
        if digest != file.sha256 {
            let _ = std::fs::remove_file(&part);
            return Err("model_checksum_mismatch".into());
        }
        std::fs::rename(&part, &staged).map_err(io)?;
        before += file.size;
        received.store(before, Ordering::Relaxed);
    }
    let target = root.join(model.id);
    let _ = std::fs::remove_dir_all(&target);
    std::fs::rename(&staging, &target).map_err(io)?;
    let files: serde_json::Map<String, Value> = model
        .files
        .iter()
        .map(|file| {
            let modified = std::fs::metadata(target.join(file.path))
                .and_then(|found| found.modified())
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |since| since.as_micros() as u64);
            (file.path.to_owned(), json!({"size_bytes": file.size, "modified_us": modified, "sha256": file.sha256}))
        })
        .collect();
    let verified = json!({"version": 2, "revision": model.revision, "files": files});
    std::fs::write(target.join(".verified.json"), serde_json::to_vec_pretty(&verified).unwrap_or_default()).map_err(io)
}

/// Downloads a model, continuing what an earlier try left.
pub(crate) fn download_model(store: Store, model: &'static Model) {
    let Some(root) = models_root() else {
        return;
    };
    let state = global::<Models>();
    if state.with_untracked(|models| models.downloading.contains_key(model.id)) {
        return;
    }
    let stop = Arc::new(AtomicBool::new(false));
    STOPS.with(|stops| stops.borrow_mut().insert(model.id, stop.clone()));
    state.update(|models| {
        models.failed.remove(model.id);
        models.downloading.insert(model.id, 0.0);
    });
    store.run(async move {
        let received = Arc::new(AtomicU64::new(0));
        let seen = received.clone();
        let total = model.size().max(1) as f64;
        let _watcher = super::Ends::with(spawn(async move {
            loop {
                timer(Duration::from_millis(500)).await;
                let fraction = seen.load(Ordering::Relaxed) as f64 / total;
                state.update(|models| {
                    models.downloading.insert(model.id, fraction.min(1.0));
                });
            }
        }));
        let result = blocking(move || fetch_model(model, &root, &received, &stop)).await;
        STOPS.with(|stops| stops.borrow_mut().remove(model.id));
        let failure = match result {
            Ok(Ok(())) => None,
            Ok(Err(error)) if error == "cancelled" => None,
            Ok(Err(error)) => Some(error),
            Err(_) => Some("model_download_failed".to_owned()),
        };
        if let Some(error) = &failure {
            log::warn!("downloading {}: {error}", model.id);
        }
        state.update(|models| {
            models.changes += 1;
            models.downloading.remove(model.id);
            if let Some(error) = failure {
                models.failed.insert(model.id, error.split(':').next().unwrap_or("model_download_failed").to_owned());
            }
        });
    });
}

/// Stops a model's download; what arrived stays for the next try.
pub(crate) fn cancel_download(model: &'static Model) {
    STOPS.with(|stops| {
        if let Some(stop) = stops.borrow().get(model.id) {
            stop.store(true, Ordering::Relaxed);
        }
    });
}

/// Deletes a model and anything a download left of it.
pub(crate) fn remove_model(model: &'static Model) {
    cancel_download(model);
    if let Some(root) = models_root() {
        let _ = std::fs::remove_dir_all(root.join(model.id));
        let _ = std::fs::remove_dir_all(root.join(format!(".{}.part", model.id)));
    }
    global::<Models>().update(|models| {
        models.changes += 1;
        models.failed.remove(model.id);
    });
}

// --- Audio ----------------------------------------------------------------------

/// The recording as the models hear it: mono samples at 16 kHz.
pub(crate) async fn prepare_audio(job: &Job) -> Result<Arc<Vec<i16>>, Failure> {
    let source = PathBuf::from(&job.source_path);
    if !source.exists() {
        return Err(Failure::new("missing_source", "The recording is gone."));
    }
    blocking(move || super::audio::decode(&source, RATE as u32))
        .await
        .ok()
        .flatten()
        .map(Arc::new)
        .ok_or_else(|| Failure::new("unsupported_format", "The audio could not be decoded."))
}

/// How long prepared audio is, in milliseconds.
pub(crate) fn duration_ms(samples: &[i16]) -> i64 {
    milliseconds(samples.len())
}

// --- The engine -----------------------------------------------------------------

const RATE: usize = 16_000;
/// The longest piece Qwen3 and the aligner take whole, and how far back
/// from its end a quiet place to cut is looked for.
const PIECE_SECONDS: usize = 28;
const SEARCH_SECONDS: usize = 6;

/// Tells engine work on another thread to stop when its asker is dropped.
struct Halt(Arc<AtomicBool>);

impl Drop for Halt {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

fn stopped() -> Failure {
    Failure::new("cancelled", "Stopped.")
}

fn load(model: &Model) -> Result<Arc<QwenModel>, Failure> {
    let directory = directory_of(model).map(|path| path.display().to_string()).unwrap_or_default();
    QwenModel::load(&directory).ok_or_else(|| Failure::new("local_stt_model_missing", "The model could not be loaded."))
}

/// How many pieces are worked on at once: half the cores, at most four.
/// Each piece already keeps more than one core busy.
fn workers(pieces: usize) -> usize {
    let cores = std::thread::available_parallelism().map_or(2, |count| count.get());
    (cores / 2).clamp(1, 4).min(pieces.max(1))
}

/// Does `work` for each of `count` pieces on several threads, each with a
/// session of its own on the one loaded model, and gives the results in
/// the pieces' order. `done` hears of every piece finished.
fn in_parallel<T: Send>(
    model: &Arc<QwenModel>,
    count: usize,
    stop: &AtomicBool,
    done: &(dyn Fn() + Sync),
    prepare: &(dyn Fn(&mut QwenCtx) + Sync),
    work: &(dyn Fn(&mut QwenCtx, usize) -> T + Sync),
) -> Result<Vec<T>, Failure> {
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Option<T>>> = Mutex::new((0..count).map(|_| None).collect());
    std::thread::scope(|scope| {
        for _ in 0..workers(count) {
            scope.spawn(|| {
                let mut session = model.new_session();
                prepare(&mut session);
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= count || stop.load(Ordering::Relaxed) {
                        break;
                    }
                    let value = work(&mut session, index);
                    if let Ok(mut results) = results.lock() {
                        results[index] = Some(value);
                    }
                    done();
                }
            });
        }
    });
    if stop.load(Ordering::Relaxed) {
        return Err(stopped());
    }
    results
        .into_inner()
        .ok()
        .and_then(|results| results.into_iter().collect::<Option<Vec<T>>>())
        .ok_or_else(|| Failure::new("local_worker_failed", "Transcription stopped."))
}

fn floats(samples: &[i16]) -> Vec<f32> {
    samples.iter().map(|sample| f32::from(*sample) / 32768.0).collect()
}

fn milliseconds(samples: usize) -> i64 {
    (samples * 1000 / RATE) as i64
}

/// The aligner's words for `samples[from..to]`, in the recording's time.
/// A word marked later than its sound begins — the first of a stretch, or
/// one after a pause — is moved back to where the sound begins.
fn timed_words(
    aligner: &mut QwenCtx,
    samples: &[i16],
    from: usize,
    to: usize,
    text: &str,
    language: &str,
) -> Vec<Word> {
    let piece = &samples[from..to];
    let mut words: Vec<Word> = align::forced_align(aligner, &floats(piece), text, language)
        .unwrap_or_default()
        .into_iter()
        .map(|word| Word { text: word.text, start_ms: word.start_ms as i64, end_ms: word.end_ms as i64 })
        .collect();
    let position = |ms: i64| (ms.max(0) as usize * RATE / 1000).min(piece.len());
    for index in 0..words.len() {
        // Nothing is said before the first word, so all the sound just
        // before it is its own, across the dips inside a word; later words
        // only reach back over unbroken sound.
        let (floor, bridge) = if index == 0 {
            ((words[0].start_ms - 1500).max(0), RATE / 5)
        } else {
            (words[index - 1].end_ms, RATE / 20)
        };
        if index == 0 || words[index].start_ms > floor {
            let onset = audio::speech_onset(piece, RATE, position(floor), position(words[index].start_ms), bridge);
            words[index].start_ms = words[index].start_ms.min(milliseconds(onset).max(floor));
        }
    }
    let offset = milliseconds(from);
    for word in &mut words {
        word.start_ms += offset;
        word.end_ms += offset;
    }
    words
}

/// Runs engine work off the engine thread, one at a time, reporting how
/// far it is. Dropping the future stops the work at its next piece, and
/// the lane stays taken until it has stopped.
async fn engine<T: Send + 'static>(
    progress: impl Fn(f64) + 'static,
    work: impl FnOnce(&AtomicBool, &AtomicU64) -> Result<T, Failure> + Send + 'static,
) -> Result<T, Failure> {
    let lane = Lane::take().await;
    let (stop, fraction) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicU64::new(NO_FRACTION)));
    let _halt = Halt(stop.clone());
    let seen = fraction.clone();
    let _watcher = super::Ends::with(spawn(async move {
        loop {
            timer(Duration::from_millis(400)).await;
            let bits = seen.load(Ordering::Relaxed);
            if bits != NO_FRACTION {
                progress(f64::from_bits(bits));
            }
        }
    }));
    let result = blocking(move || {
        let _lane = lane;
        work(&stop, &fraction)
    })
    .await;
    result.unwrap_or_else(|_| Err(Failure::new("local_worker_failed", "Transcription stopped.")))
}

/// Qwen3 on a recording: the text of each piece, then its words' times,
/// which give the sentences theirs. Pieces are worked on side by side.
fn run_qwen3(
    samples: &[i16],
    model: &'static Model,
    hints: &[String],
    terms: &[String],
    stop: &AtomicBool,
    fraction: &AtomicU64,
) -> Result<Document, Failure> {
    let cuts = local::cut_points(samples, RATE, PIECE_SECONDS, SEARCH_SECONDS);
    let pieces: Vec<(usize, usize)> =
        std::iter::once(0).chain(cuts.iter().copied()).zip(cuts.iter().copied()).collect();
    let finished = AtomicUsize::new(0);
    let done = || {
        let finished = finished.fetch_add(1, Ordering::Relaxed) + 1;
        fraction.store((finished as f64 / (pieces.len() as f64 * 2.0)).to_bits(), Ordering::Relaxed);
    };
    let hinted: Vec<&'static str> = hints.iter().filter_map(|hint| local::language_name(hint)).collect();
    let prompt = terms.join(", ");

    // One hint is the language. Several say which it may be: the model
    // listens for itself, and is held to the hints when it hears another.
    let asr = load(model)?;
    let prepare = |session: &mut QwenCtx| {
        if let [only] = hinted.as_slice() {
            let _ = session.set_force_language(only);
        }
        if !prompt.is_empty() {
            let _ = session.set_prompt(&prompt);
        }
    };
    let hear = |session: &mut QwenCtx, index: usize| -> (String, &'static str) {
        let (from, to) = pieces[index];
        let audio = floats(&samples[from..to]);
        let text = transcribe::transcribe_audio(session, &audio).unwrap_or_default();
        let detected = session.detected_language.as_deref().and_then(local::known_language);
        if hinted.len() > 1 && !text.trim().is_empty() && detected.is_none_or(|name| !hinted.contains(&name)) {
            let fallback = local::language_for(hints, &text);
            let again = match session.set_force_language(fallback) {
                Ok(()) => transcribe::transcribe_audio(session, &audio).unwrap_or(text),
                Err(()) => text,
            };
            let _ = session.set_force_language("");
            return (again.trim().to_owned(), fallback);
        }
        let language = match hinted.as_slice() {
            [only] => only,
            _ => detected.unwrap_or_else(|| local::guess_language(&text)),
        };
        (text.trim().to_owned(), language)
    };
    let heard = in_parallel(&asr, pieces.len(), stop, &done, &prepare, &hear)?;
    drop(asr);

    let aligner = load(&local::ALIGNER)?;
    let time = |session: &mut QwenCtx, index: usize| -> Vec<Word> {
        let ((from, to), (text, language)) = (pieces[index], &heard[index]);
        if text.is_empty() { Vec::new() } else { timed_words(session, samples, from, to, text, language) }
    };
    let timed = in_parallel(&aligner, pieces.len(), stop, &done, &|_| (), &time)?;

    let mut document = Document::default();
    for (((from, to), (text, language)), words) in pieces.iter().zip(&heard).zip(&timed) {
        if text.is_empty() {
            continue;
        }
        let (mut segments, tokens) = local::timed_sentences(text, words, milliseconds(*to), document.segments.len());
        if segments.is_empty() {
            // Nothing could be timed: the piece is one sentence.
            segments.push(listenook_core::Segment {
                id: format!("qwen3-{}", document.segments.len()),
                start_ms: milliseconds(*from),
                end_ms: milliseconds(*to),
                text: text.clone(),
                ..Default::default()
            });
        }
        let code = local::LANGUAGES.iter().find(|known| known.0 == *language).map(|known| known.1.to_owned());
        for segment in &mut segments {
            segment.language = code.clone();
        }
        document.segments.extend(segments);
        document.tokens.extend(tokens);
    }
    document.touch();
    Ok(document)
}

/// Word times for a transcript that has sentences already.
fn run_alignment(
    samples: &[i16],
    document: &Document,
    hints: &[String],
    stop: &AtomicBool,
    fraction: &AtomicU64,
) -> Result<Vec<listenook_core::Token>, Failure> {
    let plan = local::plan(document);
    let aligner = load(&local::ALIGNER)?;
    let finished = AtomicUsize::new(0);
    let done = || {
        let finished = finished.fetch_add(1, Ordering::Relaxed) + 1;
        fraction.store((finished as f64 / plan.windows.len() as f64).to_bits(), Ordering::Relaxed);
    };
    let time = |session: &mut QwenCtx, index: usize| -> Vec<listenook_core::Token> {
        let window = &plan.windows[index];
        let from = (window.start_ms.max(0) as usize * RATE / 1000).min(samples.len());
        let to = (window.end_ms.max(0) as usize * RATE / 1000).clamp(from, samples.len());
        let sentences: Vec<&listenook_core::Segment> =
            window.segments.iter().filter_map(|s| document.segments.iter().find(|d| d.id == s.id)).collect();
        let texts: Vec<&str> = sentences.iter().map(|sentence| sentence.text.as_str()).collect();
        let text = texts.join(" ");
        let words = timed_words(session, samples, from, to, &text, local::language_for(hints, &text));
        sentences
            .iter()
            .zip(local::distribute(&words, &texts))
            .filter(|(_, words)| !words.is_empty())
            .flat_map(|(sentence, words)| local::word_tokens(sentence, &words))
            .collect()
    };
    Ok(in_parallel(&aligner, plan.windows.len(), stop, &done, &|_| (), &time)?.into_iter().flatten().collect())
}

// --- Transcription --------------------------------------------------------------

/// Transcribes prepared audio with a local provider.
pub(crate) async fn transcribe(store: Store, job: &Job, samples: Arc<Vec<i16>>) -> Result<Document, Failure> {
    let duration_ms = duration_ms(&samples);
    let provider = job.transcription_provider;
    if !offered(provider) {
        return Err(Failure::new("local_stt_unsupported", "Local transcription is not available here."));
    }
    if !provider_ready(provider) {
        return Err(Failure::new("local_stt_model_missing", "The model is not downloaded."));
    }
    if duration_ms > MAX_DURATION_MS {
        return Err(Failure::new("duration_limit", "The recording is too long."));
    }
    let id = job.id.clone();
    store.set_progress(&id, "local_transcribing", None);
    let heard = move |fraction: f64| store.set_progress(&id, "local_transcribing", Some(fraction));
    if provider == TranscriptionProvider::Qwen3Local {
        let model = qwen3_model();
        let (hints, terms) = (job.options.language_hints.clone(), job.options.context_terms.clone());
        return engine(heard, move |stop, fraction| run_qwen3(&samples, model, &hints, &terms, stop, fraction)).await;
    }
    // The helper reads a file.
    let wav = temporary().join(format!("{}-local.wav", job.id));
    let (target, audio) = (wav.clone(), samples.clone());
    blocking(move || std::fs::write(target, audio::wav(&audio, RATE as u32)))
        .await
        .map_err(|_| Failure::new("local_worker_launch_failed", "The audio could not be written."))?
        .map_err(|error| Failure::new("local_worker_launch_failed", error.to_string()))?;
    private(&wav);
    let directory = directory_of(&local::MOSS).map(|path| path.display().to_string()).unwrap_or_default();
    let request = json!({
        "model_directory": directory, "audio_path": wav.display().to_string(),
        "chunk_seconds": 30, "parallel_chunks": 2, "max_new_tokens_per_chunk": 640,
        "hotwords": job.options.context_terms,
    });
    let result = worker("transcribe-moss", request, heard).await;
    let _ = std::fs::remove_file(&wav);
    Ok(local::moss_document(&result?, duration_ms))
}

// --- Word timing ----------------------------------------------------------------

/// Whether a job's transcript can be given word timing here.
pub(crate) fn can_align(job: &Job) -> bool {
    supported()
        && matches!(
            job.transcription_provider,
            TranscriptionProvider::MossPro | TranscriptionProvider::MossLocal | TranscriptionProvider::Qwen3Local
        )
        && job.document.as_ref().is_some_and(|document| !document.segments.is_empty())
        && installed(&local::ALIGNER)
}

/// Times the words of a job's transcript against prepared audio and
/// returns the job's `forced_alignment` record. The words it could time
/// are in the transcript when it returns.
pub(crate) async fn align(store: Store, id: &str, samples: Arc<Vec<i16>>) -> Value {
    let unavailable = |code: &str| json!({"status": "unavailable", "warning_code": code});
    let Some(job) = store.job_now(id) else {
        return unavailable("alignment_source_missing");
    };
    let Some(document) = job.document.clone() else {
        return unavailable("alignment_source_missing");
    };
    if !installed(&local::ALIGNER) {
        return unavailable("alignment_model_missing");
    }
    let plan = local::plan(&document);
    let total = document.segments.len();
    if plan.windows.is_empty() {
        return unavailable(if plan.too_long > 0 {
            "alignment_segment_too_long"
        } else {
            "alignment_no_eligible_segments"
        });
    }
    let (job_id, hints) = (id.to_owned(), job.options.language_hints.clone());
    let heard = move |fraction: f64| store.set_progress(&job_id, "aligning", Some(fraction));
    let automatic = hints.len() != 1;
    let result = engine(heard, move |stop, fraction| run_alignment(&samples, &document, &hints, stop, fraction)).await;
    let (tokens, failure) = match result {
        Ok(tokens) => (tokens, None),
        Err(error) => {
            log::warn!("aligning {id}: {} ({})", error.code, error.message);
            (Vec::new(), Some(error.code))
        }
    };
    let mut aligned: Vec<&str> = tokens.iter().filter_map(|token| token.segment_id.as_deref()).collect();
    aligned.dedup();
    let aligned = aligned.len();
    let (status, warning) = match (aligned, failure) {
        (0, failure) => ("failed", Some(failure.unwrap_or_else(|| "alignment_failed".into()))),
        (count, None) if count == total => ("completed", None),
        (_, _) if plan.too_long > 0 => ("partial", Some("alignment_segment_too_long".to_owned())),
        _ => ("partial", Some("alignment_partial".to_owned())),
    };
    if aligned > 0 {
        store.update_document(id, |document| document.tokens = tokens);
    }
    let mut record = json!({
        "status": status,
        "model_id": local::ALIGNER.id,
        "model_revision": local::ALIGNER.revision,
        "aligned_segments": aligned,
        "total_segments": total,
        "language_automatically_determined": automatic,
    });
    if let Some(warning) = warning {
        record["warning_code"] = json!(warning);
    }
    record
}
