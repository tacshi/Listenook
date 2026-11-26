#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use listenook_core::media::container::{self, Converter, Device, Plan};
use listenook_core::media::subtitles;
use nsh_core::prelude::*;

use crate::services::persist;
use crate::ui::tr;

/// Whether the recording at `path` has to be made playable first: Apple's player opens no
/// Matroska (MKV, WebM) or AVI file.
pub(crate) fn needs_help(path: &str) -> bool {
    cfg!(target_vendor = "apple") && matches!(subtitles::extension(path).as_str(), "mkv" | "webm" | "avi")
}

/// What this device's player shows besides H.264 and HEVC, and what it can convert.
fn device() -> Device {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    return apple::device();
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    Device::default()
}

/// A converter of AV1 pictures into ones this device shows.
fn av1_converter() -> Result<Box<dyn Converter>, String> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    return Ok(Box::new(apple::Av1ToHevc::new()?));
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    Err("no AV1 converter here".to_owned())
}

fn plan(path: &str) -> Plan {
    container::plan(Path::new(path), device())
}

pub(crate) fn keeps_picture(path: &str) -> bool {
    matches!(plan(path), Plan::Copy | Plan::ConvertAv1)
}

/// Whether making the recording at `path` playable means converting its pictures, which takes
/// minutes (its sound is ready in seconds).
pub(crate) fn converts(path: &str) -> bool {
    plan(path) == Plan::ConvertAv1
}

/// What to tell someone waiting for the recording at `path` to be made playable.
pub(crate) fn notice(path: &str) -> SharedString {
    if converts(path) {
        tr("Converting this video's picture to play here, which takes a few minutes. Its sound plays meanwhile.")
    } else {
        tr("Preparing this recording for playback…")
    }
}

fn cache(id: &str, extension: &str) -> Option<PathBuf> {
    Some(persist::data_root()?.join("temporary").join(format!("{id}-playable.{extension}")))
}

const KINDS: [&str; 5] = ["mp4", "mov", "m4a", "mp3", "wav"];
const SOUND_ONLY: [&str; 3] = ["m4a", "mp3", "wav"];

/// Recordings being made playable, each with the flag that stops the work. An id is marked for
/// as long as the work on it runs, not for as long as someone waits for it: a page left mid-way
/// drops its wait, but the work goes on writing the file, and a second one must not start
/// beside it.
static MAKING: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, Arc<AtomicBool>>>> =
    std::sync::LazyLock::new(Default::default);

fn making() -> std::sync::MutexGuard<'static, std::collections::HashMap<String, Arc<AtomicBool>>> {
    MAKING.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Marks a recording as being made until it is dropped, when the work ends however it ends.
struct Making(String, Arc<AtomicBool>);

impl Making {
    fn start(id: &str) -> Option<Making> {
        let mut making = making();
        if making.contains_key(id) {
            return None;
        }
        let stop = Arc::new(AtomicBool::new(false));
        making.insert(id.to_owned(), stop.clone());
        Some(Making(id.to_owned(), stop))
    }
}

impl Drop for Making {
    fn drop(&mut self) {
        making().remove(&self.0);
    }
}

fn remove_made(id: &str) {
    for kind in KINDS {
        if let Some(path) = cache(id, kind) {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Stops the work on a recording's playable file and removes what was made.
pub(crate) fn forget(id: &str) {
    if let Some(stop) = making().get(id) {
        stop.store(true, Ordering::Relaxed);
    }
    remove_made(id);
}

fn is_sound_only(path: &Path) -> bool {
    path.extension().is_some_and(|extension| SOUND_ONLY.iter().any(|kind| extension == *kind))
}

/// The playable file already made for a recording. A sound-only one doesn't count once its
/// source can keep its picture: AVI files were all made sound-only before their pictures
/// could be kept, and an AV1 video plays its sound alone while its pictures are converted.
pub(crate) fn made(id: &str, source: &str) -> Option<PathBuf> {
    let path = KINDS.iter().filter_map(|kind| cache(id, kind)).find(|path| path.is_file())?;
    (!is_sound_only(&path) || !keeps_picture(source)).then_some(path)
}

/// What [`repackage`] puts in the MP4 file of a Matroska video.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Repackage {
    Whole,
    Sound,
    ConvertedAv1,
}

fn repackage(id: &str, source: &Path, what: Repackage, stop: &AtomicBool) -> Option<PathBuf> {
    let path = cache(id, if what == Repackage::Sound { "m4a" } else { "mp4" })?;
    std::fs::create_dir_all(path.parent()?).ok()?;
    let part = path.with_extension(format!("{}.part", path.extension()?.to_string_lossy()));
    let started = std::time::Instant::now();
    let mut told = 0;
    let mut going = |done: f64| {
        let tenths = (done * 10.0) as i32;
        if what == Repackage::ConvertedAv1 && tenths > told {
            told = tenths;
            log::info!("{}: {}% converted in {:.0?}", source.display(), tenths * 10, started.elapsed());
        }
        !stop.load(Ordering::Relaxed)
    };
    let made = (|| {
        let (input, output) = (std::fs::File::open(source), std::fs::File::create(&part));
        let (input, output) = (input.map_err(|e| e.to_string())?, output.map_err(|e| e.to_string())?);
        match what {
            Repackage::Whole => container::mkv_to_mp4(input, output, container::Pictures::Copy, &mut going),
            Repackage::Sound => container::mkv_to_mp4(input, output, container::Pictures::Leave, &mut going),
            Repackage::ConvertedAv1 => {
                let mut converter = av1_converter()?;
                container::mkv_to_mp4(input, output, container::Pictures::Convert(converter.as_mut()), &mut going)
            }
        }
    })();
    match made {
        Ok(()) if !stop.load(Ordering::Relaxed) => {
            std::fs::rename(&part, &path).ok()?;
            log::info!("{}: made playable in {:.1?}", source.display(), started.elapsed());
            Some(path)
        }
        result => {
            if let Err(reason) = result {
                log::info!("{}: {reason}", source.display());
            }
            let _ = std::fs::remove_file(&part);
            None
        }
    }
}

/// The recording's sound alone, decoded: for a video whose sound can't be repackaged.
fn decoded_sound(id: &str, source: &Path) -> Option<PathBuf> {
    let path = cache(id, "wav")?;
    std::fs::create_dir_all(path.parent()?).ok()?;
    let part = path.with_extension("wav.part");
    let samples = super::audio::decode(source, 22_050)?;
    std::fs::write(&part, listenook_core::media::audio::wav(&samples, 22_050)).ok()?;
    std::fs::rename(&part, &path).ok()?;
    Some(path)
}

fn avi_movie(id: &str, source: &Path) -> Option<PathBuf> {
    let path = cache(id, "mov")?;
    std::fs::create_dir_all(path.parent()?).ok()?;
    let part = path.with_extension("mov.part");
    let movie = std::fs::File::open(source)
        .and_then(|input| Ok((input, std::fs::File::create(&part)?)))
        .map_err(|error| error.to_string())
        .and_then(|(input, out)| container::avi_to_mov(input, out));
    match movie {
        Ok(()) => {
            std::fs::rename(&part, &path).ok()?;
            Some(path)
        }
        Err(reason) => {
            log::info!("{}: {reason}; playing its sound", source.display());
            let _ = std::fs::remove_file(&part);
            super::audio::avi_sound_file(source, &cache(id, "x")?.with_extension(""))
        }
    }
}

/// Makes a recording playable here, handing `show` each file as it is ready: when its pictures
/// have to be converted, which takes minutes, a file of its sound alone first. False when
/// nothing playable could be made.
pub(crate) async fn prepare(id: String, source: String, show: impl Fn(PathBuf) + 'static) -> bool {
    let mut sound_shown = false;
    let mark = loop {
        if let Some(path) = made(&id, &source) {
            show(path);
            return true;
        }
        if let Some(mark) = Making::start(&id) {
            break mark;
        }
        // Another page is making it: its sound may already be there to play meanwhile.
        if let Some(sound) = cache(&id, "m4a").filter(|sound| !sound_shown && sound.is_file()) {
            sound_shown = true;
            show(sound);
        }
        timer(std::time::Duration::from_millis(200)).await;
    };
    let plan = {
        let source = source.clone();
        blocking(move || plan(&source)).await.unwrap_or(Plan::Decode)
    };
    let first = match plan {
        Plan::Copy if subtitles::extension(&source) == "avi" => None,
        Plan::Copy => Some(Repackage::Whole),
        Plan::Sound | Plan::ConvertAv1 => Some(Repackage::Sound),
        Plan::Decode => None,
    };
    remove_made(&mark.0);
    let stop = mark.1.clone();
    let work = move |what: Option<Repackage>| {
        let (id, source, stop) = (id.clone(), source.clone(), stop.clone());
        blocking(move || {
            let source = Path::new(&source);
            match what {
                Some(what) => repackage(&id, source, what, &stop),
                None if subtitles::extension(&source.to_string_lossy()) == "avi" => avi_movie(&id, source),
                None => decoded_sound(&id, source),
            }
        })
    };
    let sound = work(first).await.ok().flatten();
    if let Some(sound) = &sound {
        show(sound.clone());
    }
    if plan != Plan::ConvertAv1 {
        return sound.is_some();
    }
    match work(Some(Repackage::ConvertedAv1)).await.ok().flatten() {
        Some(video) => {
            show(video);
            if let Some(sound) = sound {
                let _ = std::fs::remove_file(sound);
            }
            true
        }
        None => sound.is_some(),
    }
}
