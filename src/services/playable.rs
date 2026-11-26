use std::path::{Path, PathBuf};

use listenook_core::{media::container, media::subtitles};
use nsh_core::prelude::*;

use crate::services::persist;

pub(crate) fn needs_help(path: &str) -> bool {
    cfg!(target_vendor = "apple") && matches!(subtitles::extension(path).as_str(), "mkv" | "avi")
}

pub(crate) fn keeps_picture(path: &str) -> bool {
    container::keeps_picture(Path::new(path))
}

fn cache(id: &str, extension: &str) -> Option<PathBuf> {
    Some(persist::data_root()?.join("temporary").join(format!("{id}-playable.{extension}")))
}

const KINDS: [&str; 4] = ["mp4", "mov", "mp3", "wav"];

/// Recordings being made playable. An id is marked for as long as the work on it runs, not
/// for as long as someone waits for it: a page left mid-way drops its wait, but the work goes
/// on writing the file, and a second one must not start beside it.
static MAKING: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<String>>> =
    std::sync::LazyLock::new(Default::default);

fn making() -> std::sync::MutexGuard<'static, std::collections::HashSet<String>> {
    MAKING.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Marks a recording as being made until it is dropped, when the work ends however it ends.
struct Making(String);

impl Drop for Making {
    fn drop(&mut self) {
        making().remove(&self.0);
    }
}

pub(crate) fn forget(id: &str) {
    for kind in KINDS {
        if let Some(path) = cache(id, kind) {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// The playable file already made for a recording. A sound-only one doesn't count once its
/// source can keep its picture: AVI files were all made sound-only before their pictures
/// could be kept.
pub(crate) fn made(id: &str, source: &str) -> Option<PathBuf> {
    let path = KINDS.iter().filter_map(|kind| cache(id, kind)).find(|path| path.is_file())?;
    let sound_only = path.extension().is_some_and(|extension| extension == "mp3" || extension == "wav");
    (!sound_only || !keeps_picture(source)).then_some(path)
}

fn make(id: &str, source: &Path) -> Option<PathBuf> {
    forget(id);
    let stem = cache(id, "x")?.with_extension("");
    std::fs::create_dir_all(stem.parent()?).ok()?;
    let part = stem.with_extension("part");
    if source.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("avi")) {
        let movie = std::fs::File::open(source)
            .and_then(|input| Ok((input, std::fs::File::create(&part)?)))
            .map_err(|error| error.to_string())
            .and_then(|(input, out)| container::avi_to_mov(input, out));
        return match movie {
            Ok(()) => {
                let path = stem.with_extension("mov");
                std::fs::rename(&part, &path).ok()?;
                Some(path)
            }
            Err(reason) => {
                log::info!("{}: {reason}; playing its sound", source.display());
                let _ = std::fs::remove_file(&part);
                super::audio::avi_sound_file(source, &stem)
            }
        };
    }
    let video = std::fs::File::create(&part)
        .map_err(|error| error.to_string())
        .and_then(|out| container::mkv_to_mp4(|| std::fs::File::open(source), out));
    match video {
        Ok(()) => {
            let path = stem.with_extension("mp4");
            std::fs::rename(&part, &path).ok()?;
            Some(path)
        }
        Err(reason) => {
            log::info!("{}: {reason}; playing its sound", source.display());
            let _ = std::fs::remove_file(&part);
            let samples = super::audio::decode(source, 22_050)?;
            let path = stem.with_extension("wav");
            std::fs::write(&part, listenook_core::media::audio::wav(&samples, 22_050)).ok()?;
            std::fs::rename(&part, &path).ok()?;
            Some(path)
        }
    }
}

pub(crate) async fn prepare(id: String, source: String) -> Option<PathBuf> {
    loop {
        if let Some(path) = made(&id, &source) {
            return Some(path);
        }
        if making().insert(id.clone()) {
            break;
        }
        timer(std::time::Duration::from_millis(200)).await;
    }
    let mark = Making(id.clone());
    blocking(move || {
        let _mark = mark;
        make(&id, Path::new(&source))
    })
    .await
    .ok()
    .flatten()
}
