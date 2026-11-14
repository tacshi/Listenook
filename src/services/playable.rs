use std::path::{Path, PathBuf};

use listenook_core::{container, subtitles};
use nsh_core::prelude::*;

use crate::state::persist;

pub(crate) fn needs_help(path: &str) -> bool {
    cfg!(target_vendor = "apple") && matches!(subtitles::extension(path).as_str(), "mkv" | "avi")
}

pub(crate) fn keeps_picture(path: &str) -> bool {
    subtitles::extension(path) == "mkv" && std::fs::File::open(path).is_ok_and(container::mkv_fits_mp4)
}

fn cache(id: &str, extension: &str) -> Option<PathBuf> {
    Some(persist::data_root()?.join("temporary").join(format!("{id}-playable.{extension}")))
}

const KINDS: [&str; 3] = ["mp4", "mp3", "wav"];

thread_local! {
    static MAKING: std::cell::RefCell<std::collections::HashSet<String>> = Default::default();
}

pub(crate) fn forget(id: &str) {
    for kind in KINDS {
        if let Some(path) = cache(id, kind) {
            let _ = std::fs::remove_file(path);
        }
    }
}

pub(crate) fn made(id: &str) -> Option<PathBuf> {
    KINDS.iter().filter_map(|kind| cache(id, kind)).find(|path| path.is_file())
}

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

pub(crate) async fn prepare(id: String, source: String) -> Option<PathBuf> {
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
