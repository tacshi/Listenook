//! Recordings the system player cannot open, made into ones it can.
//! Apple's player reads neither Matroska nor AVI files: a Matroska file's
//! H.264 video and AAC sound are put into an MP4 file as they are; of
//! anything else the sound is played. The result is made once and kept in
//! the app's temporary folder. Windows' and Android's players read both
//! containers themselves.

use std::path::{Path, PathBuf};

use listenook_core::{container, subtitles};
use nsh_core::prelude::*;

use crate::state::persist;

/// Whether the player here cannot open this file as it is.
pub(crate) fn needs_help(path: &str) -> bool {
    cfg!(target_vendor = "apple") && matches!(subtitles::extension(path).as_str(), "mkv" | "avi")
}

/// Whether a file that needs help will play with its picture.
pub(crate) fn keeps_picture(path: &str) -> bool {
    subtitles::extension(path) == "mkv" && std::fs::File::open(path).is_ok_and(container::mkv_fits_mp4)
}

fn cache(id: &str, extension: &str) -> Option<PathBuf> {
    Some(persist::data_root()?.join("temporary").join(format!("{id}-playable.{extension}")))
}

const KINDS: [&str; 3] = ["mp4", "mp3", "wav"];

thread_local! {
    /// The recordings something playable is being made for.
    static MAKING: std::cell::RefCell<std::collections::HashSet<String>> = Default::default();
}

/// Deletes what was made for a recording.
pub(crate) fn forget(id: &str) {
    for kind in KINDS {
        if let Some(path) = cache(id, kind) {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// What was made for a recording earlier, if it is still there.
pub(crate) fn made(id: &str) -> Option<PathBuf> {
    KINDS.iter().filter_map(|kind| cache(id, kind)).find(|path| path.is_file())
}

/// An AVI file's sound track in a file of its own beside `stem`.
pub(crate) fn avi_sound_file(source: &Path, stem: &Path) -> Option<PathBuf> {
    let part = stem.with_extension("part");
    let kind = container::avi_sound(std::fs::File::open(source).ok()?, std::fs::File::create(&part).ok()?);
    match kind {
        Ok(kind) => {
            let path = stem.with_extension(kind.extension());
            std::fs::rename(&part, &path).ok()?;
            Some(path)
        }
        Err(reason) => {
            log::warn!("{}: {reason}", source.display());
            let _ = std::fs::remove_file(&part);
            None
        }
    }
}

fn make(id: &str, source: &Path) -> Option<PathBuf> {
    let stem = cache(id, "x")?.with_extension("");
    std::fs::create_dir_all(stem.parent()?).ok()?;
    let part = stem.with_extension("part");
    if source.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("avi")) {
        return avi_sound_file(source, &stem);
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
            // No picture can be kept: the sound, decoded, as a WAV file.
            log::info!("{}: {reason}; playing its sound", source.display());
            let _ = std::fs::remove_file(&part);
            let samples = super::audio::decode(source, 22_050)?;
            let path = stem.with_extension("wav");
            std::fs::write(&part, listenook_core::audio::wav(&samples, 22_050)).ok()?;
            std::fs::rename(&part, &path).ok()?;
            Some(path)
        }
    }
}

/// The file to play for a recording that needs help, made now if it was
/// not made before. None when nothing playable can be made of it.
pub(crate) async fn prepare(id: String, source: String) -> Option<PathBuf> {
    // A second request for a recording waits for the first to finish
    // instead of writing over its file.
    while MAKING.with_borrow(|making| making.contains(&id)) {
        timer(std::time::Duration::from_millis(200)).await;
    }
    if let Some(path) = made(&id) {
        return Some(path);
    }
    MAKING.with_borrow_mut(|making| making.insert(id.clone()));
    let (work, done) = (id.clone(), id);
    let path = blocking(move || make(&work, Path::new(&source))).await.ok().flatten();
    MAKING.with_borrow_mut(|making| making.remove(&done));
    path
}
