//! Recording what this computer plays: on a Mac a Core Audio tap of every
//! app but Listenook (macOS 14.2 and later), on Windows a loopback of the
//! sound sent to the speakers. Either hands stereo float frames to a thread
//! that writes them to a WAV in the library's temporary folder, keeping the
//! header current so a recording outlives a crash, and measures them for
//! the live meter and for finding the silent gaps.

#[cfg(target_os = "macos")]
mod mac;
#[cfg(target_os = "windows")]
mod windows;

use std::{
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

use listenook_core::capture::{self, Meter, Span, WavWriter};

/// The longest recording: past it, recording stops by itself.
pub(crate) const LONGEST_MS: u64 = 5 * 60 * 60 * 1000;

/// Stereo frames, interleaved, as the platform hands them over.
pub(super) type Sink = mpsc::Sender<Vec<f32>>;

/// A platform's capture while it runs: dropping it stops it.
pub(super) trait Stream: Send {}

/// Whether this computer can record what it plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Support {
    Yes,
    /// A Mac older than macOS 14.2, which has no audio taps.
    NeedsNewerMac,
    No,
}

pub(crate) fn support() -> Support {
    if faked() {
        return Support::Yes;
    }
    #[cfg(target_os = "macos")]
    return if mac::has_taps() { Support::Yes } else { Support::NeedsNewerMac };
    #[cfg(target_os = "windows")]
    return Support::Yes;
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    Support::No
}

/// Whether the system lets Listenook hear other apps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Access {
    Granted,
    Denied,
    /// Not asked yet: the system asks when recording starts.
    Unknown,
}

pub(crate) fn access() -> Access {
    if faked() {
        return Access::Granted;
    }
    #[cfg(target_os = "macos")]
    return mac::access();
    #[cfg(not(target_os = "macos"))]
    Access::Granted
}

/// Asks the person to let Listenook hear other apps, waiting for the answer
/// (blocks: run it off the main thread). True when allowed.
pub(crate) fn ask() -> bool {
    #[cfg(target_os = "macos")]
    if !faked() {
        return mac::ask();
    }
    true
}

/// Opens the system's settings where recording other apps is allowed.
pub(crate) fn open_privacy_settings() {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("/usr/bin/open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            .status();
    }
}

/// A recording in progress.
pub(crate) struct Recorder {
    shared: Arc<Shared>,
    stream: Option<Box<dyn Stream>>,
    writer: Option<JoinHandle<std::io::Result<u64>>>,
    path: PathBuf,
}

struct Shared {
    rate: u32,
    paused: AtomicBool,
    frames: AtomicU64,
    full: AtomicBool,
    levels: Mutex<Vec<f32>>,
}

/// A recording once stopped.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Take {
    pub(crate) path: PathBuf,
    pub(crate) levels: Vec<f32>,
    pub(crate) duration_ms: u64,
}

impl Take {
    pub(crate) fn gaps(&self) -> Vec<Span> {
        capture::gaps(&self.levels)
    }

    /// A recording left in `path` by a run that ended before it was saved.
    pub(crate) fn left(path: &Path) -> Option<Take> {
        let (levels, info) = capture::levels_of(path).ok()?;
        (info.duration_ms() >= 1000).then(|| Take { path: path.to_owned(), levels, duration_ms: info.duration_ms() })
    }
}

impl Recorder {
    /// Starts recording into a new WAV at `path` (blocks briefly while the
    /// system sets the capture up). An error code on failure.
    pub(crate) fn start(path: PathBuf) -> Result<Recorder, &'static str> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder).map_err(|_| "capture_failed")?;
        }
        let (sink, frames) = mpsc::channel();
        let (rate, stream) = open(sink)?;
        let shared = Arc::new(Shared {
            rate,
            paused: AtomicBool::new(false),
            frames: AtomicU64::new(0),
            full: AtomicBool::new(false),
            levels: Mutex::new(Vec::new()),
        });
        let mut wav = WavWriter::create(&path, rate, 2).map_err(|error| {
            log::error!("capture: creating {}: {error}", path.display());
            "capture_failed"
        })?;
        let writing = shared.clone();
        let writer = std::thread::Builder::new()
            .name("capture-writer".into())
            .spawn(move || {
                let result = write(&mut wav, frames, &writing);
                let finished = wav.finish();
                result.and(finished)
            })
            .map_err(|_| "capture_failed")?;
        Ok(Recorder { shared, stream: Some(stream), writer: Some(writer), path })
    }

    pub(crate) fn set_paused(&self, paused: bool) {
        self.shared.paused.store(paused, Ordering::Relaxed);
    }

    /// How long it has recorded (not counting pauses).
    pub(crate) fn elapsed_ms(&self) -> u64 {
        self.shared.frames.load(Ordering::Relaxed) * 1000 / u64::from(self.shared.rate.max(1))
    }

    /// Whether it reached [`LONGEST_MS`] and records no more.
    pub(crate) fn full(&self) -> bool {
        self.shared.full.load(Ordering::Relaxed)
    }

    /// The levels of its last `count` × 10 ms.
    pub(crate) fn recent_levels(&self, count: usize) -> Vec<f32> {
        let levels = self.shared.levels.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        levels[levels.len().saturating_sub(count)..].to_vec()
    }

    /// Whether anything louder than silence came in yet.
    pub(crate) fn heard(&self) -> bool {
        capture::heard(&self.shared.levels.lock().unwrap_or_else(|poisoned| poisoned.into_inner()))
    }

    /// Stops recording and finishes the file (blocks until it is written).
    pub(crate) fn stop(mut self) -> Result<Take, &'static str> {
        self.stream.take();
        let written = self.writer.take().map(|writer| writer.join());
        match written {
            Some(Ok(Ok(_))) => {}
            Some(Ok(Err(error))) => {
                log::error!("capture: writing {}: {error}", self.path.display());
                return Err("capture_write_failed");
            }
            _ => return Err("capture_write_failed"),
        }
        let levels = std::mem::take(&mut *self.shared.levels.lock().unwrap_or_else(|poisoned| poisoned.into_inner()));
        let duration_ms = self.elapsed_ms();
        Ok(Take { path: std::mem::take(&mut self.path), levels, duration_ms })
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        self.stream.take();
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
    }
}

fn write(wav: &mut WavWriter, frames: mpsc::Receiver<Vec<f32>>, shared: &Shared) -> std::io::Result<()> {
    let mut meter = Meter::new(shared.rate, 2);
    let (mut fresh, mut pcm) = (Vec::new(), Vec::new());
    let longest = LONGEST_MS * u64::from(shared.rate) / 1000;
    let mut synced = Instant::now();
    for chunk in frames {
        if shared.paused.load(Ordering::Relaxed) || shared.full.load(Ordering::Relaxed) {
            continue;
        }
        let room = (longest.saturating_sub(wav.frames()) * 2) as usize;
        let chunk = &chunk[..chunk.len().min(room)];
        meter.push(chunk, &mut fresh);
        pcm.clear();
        capture::pcm16(chunk, &mut pcm);
        wav.write(&pcm)?;
        shared.frames.store(wav.frames(), Ordering::Relaxed);
        if wav.frames() >= longest {
            shared.full.store(true, Ordering::Relaxed);
        }
        if !fresh.is_empty() {
            shared.levels.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).append(&mut fresh);
        }
        if synced.elapsed() >= Duration::from_secs(1) {
            wav.sync()?;
            synced = Instant::now();
        }
    }
    Ok(())
}

fn open(sink: Sink) -> Result<(u32, Box<dyn Stream>), &'static str> {
    if faked() {
        return Ok(fake::open(sink));
    }
    #[cfg(target_os = "macos")]
    return mac::open(sink);
    #[cfg(target_os = "windows")]
    return windows::open(sink);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        drop(sink);
        Err("capture_unsupported")
    }
}

/// Makes the file of a recording to keep: the `spans` of `take`, encoded
/// as AAC in an M4A where the system can (a WAV where it cannot), written
/// beside `take` (blocks). Its path, or an error code.
pub(crate) fn export(take: &Path, spans: &[Span]) -> Result<PathBuf, &'static str> {
    let kept = take.with_extension("kept.wav");
    capture::splice(take, spans, &kept).map_err(|error| {
        log::error!("capture: splicing {}: {error}", take.display());
        "capture_write_failed"
    })?;
    let encoded = take.with_extension("m4a");
    let _ = std::fs::remove_file(&encoded);
    if encode(&kept, &encoded) {
        let _ = std::fs::remove_file(&kept);
        return Ok(encoded);
    }
    let _ = std::fs::remove_file(&encoded);
    Ok(kept)
}

fn encode(wav: &Path, m4a: &Path) -> bool {
    #[cfg(target_os = "macos")]
    return mac::encode(wav, m4a);
    #[cfg(target_os = "windows")]
    return windows::encode(wav, m4a);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = (wav, m4a);
        false
    }
}

/// Whether recording plays a made-up sound instead of the computer's: for
/// the headless flows (`LISTENOOK_CAPTURE=fake`).
fn faked() -> bool {
    std::env::var("LISTENOOK_CAPTURE").as_deref() == Ok("fake")
}

/// A made-up recording: a second of silence, a sound, a long silence and a
/// sound again, then silence in real time while it runs.
mod fake {
    use std::{
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        time::Duration,
    };

    use super::{Sink, Stream};

    const RATE: u32 = 48_000;

    struct Fake(Arc<AtomicBool>);

    impl Stream for Fake {}

    impl Drop for Fake {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Relaxed);
        }
    }

    fn part(seconds: f32, loud: bool) -> Vec<f32> {
        let frames = (seconds * RATE as f32) as usize;
        (0..frames)
            .flat_map(|frame| {
                let sample = if loud { (frame as f32 * 0.05).sin() * 0.4 } else { 0.0 };
                [sample, sample]
            })
            .collect()
    }

    pub(super) fn open(sink: Sink) -> (u32, Box<dyn Stream>) {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        std::thread::spawn(move || {
            for (seconds, loud) in [(1.0, false), (2.0, true), (4.0, false), (2.0, true)] {
                if sink.send(part(seconds, loud)).is_err() {
                    return;
                }
            }
            while !stopping.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(50));
                if sink.send(part(0.05, false)).is_err() {
                    return;
                }
            }
        });
        (RATE, Box::new(Fake(stop)))
    }
}
