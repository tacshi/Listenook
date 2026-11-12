//! Small helpers shared by pages.

use listenook_core::subtitles;
use nsh_core::{
    file_dialog::{FileFilter, OpenDialog},
    prelude::*,
};

use crate::{
    state::{Filter, store, tr},
    ui::{Tone, toast},
};

/// A local path as the `file:` URL a media element loads.
pub(crate) fn file_url(path: &str) -> String {
    let mut url = String::from("file://");
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => url.push(byte as char),
            _ => url.push_str(&format!("%{byte:02X}")),
        }
    }
    url
}

/// The local path of a `file:` URL, or the text itself when it is a path.
pub(crate) fn path_of_url(url: &str) -> String {
    let Some(rest) = url.strip_prefix("file://") else {
        return url.to_owned();
    };
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    let (bytes, mut out, mut at) = (rest.as_bytes(), Vec::with_capacity(rest.len()), 0);
    while at < bytes.len() {
        let decoded = (bytes[at] == b'%' && at + 2 < bytes.len())
            .then(|| std::str::from_utf8(&bytes[at + 1..(at + 3).min(bytes.len())]).ok())
            .flatten()
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        match decoded {
            Some(byte) => {
                out.push(byte);
                at += 3;
            }
            None => {
                out.push(bytes[at]);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Shows a file in the system's file manager.
pub(crate) fn reveal(path: String) {
    let answer = reveal_path(path);
    store().run(async move {
        if answer.await.is_err() {
            toast(Tone::Error, tr("Couldn’t show the file. It may have been moved."));
        }
    });
}

/// Every media and subtitle file under the given paths, folders opened.
fn expanded(paths: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    let mut pending = paths;
    while let Some(path) = pending.pop() {
        if std::path::Path::new(&path).is_dir() {
            let children = std::fs::read_dir(&path).into_iter().flatten().flatten();
            pending.extend(
                children
                    .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
                    .filter_map(|entry| entry.path().to_str().map(str::to_owned)),
            );
        } else if subtitles::is_media(&path) || subtitles::is_subtitle(&path) {
            out.push(path);
        }
    }
    out.sort();
    out
}

/// Adds files and folders to the Library and shows them there; says so when
/// none of them is new media.
pub(crate) fn add_media(paths: Vec<String>) {
    let store = store();
    let added = store.add_files(&expanded(paths));
    if added == 0 {
        toast(Tone::Info, tr("No new audio or video files were found."));
    } else {
        store.show(Filter::All);
    }
}

/// Asks for media and subtitle files, then adds them to the Library.
pub(crate) fn pick_media() {
    // Not for a recording to relink, should one have been asked for and
    // then given up on.
    RELINKING.set(None);
    // An iPhone or iPad shows the Files app's browser; what is picked
    // arrives later (`take_picked`).
    if crate::services::pick_documents() {
        return;
    }
    // Android has no file dialog here: media comes in through the app's folder.
    if crate::platform::is_phone() {
        import_shared();
        return;
    }
    let mut extensions: Vec<&str> = subtitles::MEDIA_EXTENSIONS.to_vec();
    extensions.extend(subtitles::SUBTITLE_EXTENSIONS);
    let dialog =
        OpenDialog::files_and_folders().multiple(true).filter(FileFilter::new("Media and subtitles", extensions));
    let answer = pick_paths(dialog);
    store().run(async move {
        if let Ok(Some(paths)) = answer.await {
            add_media(paths.iter().filter_map(|path| path.to_str().map(str::to_owned)).collect());
        }
    });
}

/// Asks for a subtitle file and makes it the recording's transcript. A
/// recording that has one already is asked about first: its translation
/// and AI Brief go with the old transcript.
pub(crate) fn attach_subtitles(job_id: String) {
    let dialog = OpenDialog::files().filter(FileFilter::new("Subtitles", subtitles::SUBTITLE_EXTENSIONS.to_vec()));
    let answer = pick_paths(dialog);
    store().run(async move {
        let Ok(Some(paths)) = answer.await else {
            return;
        };
        if let Some(path) = paths.first().and_then(|path| path.to_str()) {
            import_subtitle_file(job_id, path.to_owned());
        }
    });
}

/// Makes a subtitle file a recording's transcript, asking first when it
/// would replace one.
pub(crate) fn import_subtitle_file(job_id: String, path: String) {
    let store = store();
    let Some(job) = store.job_now(&job_id) else {
        return;
    };
    let duration = Some(job.duration_ms()).filter(|duration| *duration > 0);
    let imported = std::fs::read(&path).map_err(|_| "subtitle_read_failed").and_then(|bytes| {
        subtitles::import_subtitles(&subtitles::decode(&bytes), &subtitles::extension(&path), duration)
    });
    let document = match imported {
        Ok(imported) => imported.document,
        Err(code) => {
            toast(Tone::Error, crate::state::error_text(code));
            return;
        }
    };
    let apply = move || {
        store.update_job(&job_id, |job| {
            job.document = Some(document);
            job.ai_brief = None;
            job.translation_state = Default::default();
            job.status = listenook_core::JobStatus::Completed;
            job.error_code = None;
            job.transcript_acquisition_mode = listenook_core::TranscriptAcquisitionMode::ImportedSubtitles;
        });
        toast(Tone::Success, tr("Subtitles imported."));
    };
    if job.has_transcript() {
        crate::ui::confirm_destructive(
            tr("Replace this transcript?"),
            tr("Its edits, translation and AI Brief are replaced by the subtitle file."),
            tr("Cancel"),
            tr("Replace"),
            apply,
        );
    } else {
        apply();
    }
}

thread_local! {
    /// The recording the next files picked on a phone are for, when they
    /// were asked for to relink it.
    static RELINKING: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

/// Asks for the media file a recording has lost, and points it there.
pub(crate) fn relink(job_id: String) {
    // On an iPhone or iPad the file browser answers later (`import_picked`).
    RELINKING.set(Some(job_id.clone()));
    if crate::services::pick_documents() {
        return;
    }
    RELINKING.set(None);
    let dialog = OpenDialog::files().filter(FileFilter::new("Media", subtitles::MEDIA_EXTENSIONS.to_vec()));
    let answer = pick_paths(dialog);
    store().run(async move {
        let Ok(Some(paths)) = answer.await else {
            return;
        };
        if let Some(path) = paths.first().and_then(|path| path.to_str()) {
            relinked(&job_id, path);
        }
    });
}

/// Points a recording at `path`, its media from now on.
fn relinked(job_id: &str, path: &str) {
    let store = store();
    store.update_job(job_id, |job| {
        job.source_path = path.to_owned();
        if job.status == listenook_core::JobStatus::MissingSource {
            job.status = if job.has_transcript() {
                listenook_core::JobStatus::Completed
            } else {
                listenook_core::JobStatus::Ready
            };
            job.progress.stage = "ready".into();
        }
        if job.error_code.as_deref() == Some("missing_source") {
            job.error_code = None;
            job.error_message = None;
        }
    });
    // What was made playable was made from the old file.
    crate::services::playable::forget(job_id);
    toast(Tone::Success, tr("Media relinked."));
}

/// Saves a copy of a recording's media where the user chooses: a
/// downloaded episode lives in the app's own folder otherwise.
pub(crate) fn save_copy(source: String) {
    let name = std::path::Path::new(&source).file_name().and_then(|name| name.to_str()).unwrap_or("media").to_owned();
    store().run(async move {
        let Some(target) = save_target(name).await else {
            return;
        };
        let copied = blocking(move || std::fs::copy(&source, &target).is_ok()).await.unwrap_or(false);
        if copied {
            toast(Tone::Success, if crate::platform::is_phone() { saved_text() } else { tr("Saved.") });
        } else {
            toast(Tone::Error, tr("Couldn’t save the file. Choose another folder and try again."));
        }
    });
}

/// Asks for a video and opens it in the player.
pub(crate) fn pick_video() {
    let answer =
        pick_paths(OpenDialog::files().filter(FileFilter::new("Videos", crate::pages::VIDEO_EXTENSIONS.to_vec())));
    store().run(async move {
        if let Ok(Some(paths)) = answer.await
            && let Some(path) = paths.first().and_then(|path| path.to_str())
        {
            store().open_video(path);
        }
    });
}

/// Takes in the media people put in the app's folder (the Files app on
/// iOS): each file is moved into the app's own storage, so the folder is
/// empty again and the recording does not depend on it.
pub(crate) fn import_shared() {
    let Some(shared) = crate::platform::shared_folder() else {
        return;
    };
    let _ = std::fs::create_dir_all(&shared);
    let found: Vec<std::path::PathBuf> =
        std::fs::read_dir(&shared).into_iter().flatten().flatten().map(|entry| entry.path()).collect();
    if take_in(found) == 0 {
        toast(Tone::Info, tr("Put audio or video in the Listenook folder in the Files app, then tap + again."));
    }
}

/// Takes in the files picked in the system's file browser on an iPhone or
/// iPad: the copies it made are moved into the app's own storage.
pub(crate) fn import_picked(paths: Vec<String>) {
    let picked = paths.len();
    let found: Vec<std::path::PathBuf> = paths.into_iter().map(std::path::PathBuf::from).collect();
    let copies = found.clone();
    // Picked for a recording that lost its media: the first media file
    // becomes that recording's, kept with the app's own.
    if let Some(job_id) = RELINKING.take() {
        let media = found.iter().find(|path| path.is_file() && path.to_str().is_some_and(subtitles::is_media));
        let kept = media.and_then(|path| {
            let folder = store().data_root()?.join("media");
            let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("media").to_lowercase();
            let kept = folder.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
            let moved = std::fs::create_dir_all(&folder).is_ok()
                && (std::fs::rename(path, &kept).is_ok() || std::fs::copy(path, &kept).is_ok());
            moved.then_some(kept)
        });
        match kept.as_deref().and_then(std::path::Path::to_str) {
            Some(kept) => relinked(&job_id, kept),
            None => toast(Tone::Info, tr("No new audio or video files were found.")),
        }
        for copy in copies {
            let _ = std::fs::remove_file(copy);
        }
        return;
    }
    if take_in(found) == 0 && picked > 0 {
        toast(Tone::Info, tr("No new audio or video files were found."));
    }
    // What was not media was copied for nothing.
    for copy in copies {
        let _ = std::fs::remove_file(copy);
    }
}

/// Moves media files into the app's own storage and adds them to the
/// Library under their own names. Returns how many were taken.
fn take_in(found: Vec<std::path::PathBuf>) -> usize {
    let store = store();
    let Some(root) = store.data_root() else {
        return 0;
    };
    let media = root.join("media");
    let mut taken: Vec<(String, String)> = Vec::new();
    for path in found.into_iter().filter(|path| path.is_file() && path.to_str().is_some_and(subtitles::is_media)) {
        let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("media").to_lowercase();
        let title = path.file_stem().and_then(|stem| stem.to_str()).unwrap_or("Recording").to_owned();
        let kept = media.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
        let moved = std::fs::create_dir_all(&media).is_ok()
            && (std::fs::rename(&path, &kept).is_ok()
                || (std::fs::copy(&path, &kept).is_ok() && std::fs::remove_file(&path).is_ok()));
        if moved && let Some(kept) = kept.to_str() {
            taken.push((kept.to_owned(), title));
        }
    }
    if taken.is_empty() {
        return 0;
    }
    let paths: Vec<String> = taken.iter().map(|(path, _)| path.clone()).collect();
    store.add_files(&paths);
    // The copy is named for the app; the recording keeps the file's name.
    for (path, title) in taken {
        if let Some(job) = store.jobs().iter().find(|job| job.source_path == path) {
            store.update_job(&job.id, |job| job.display_title = Some(title));
        }
    }
    store.show(Filter::All);
    paths.len()
}

/// Where to save a file named `name`: asked of the user where there is a
/// save dialog; on a phone, the app's folder, which the Files app shows.
pub(crate) async fn save_target(name: String) -> Option<std::path::PathBuf> {
    if crate::platform::is_phone() {
        return crate::platform::export_path(&name);
    }
    pick_save_path(nsh_core::file_dialog::SaveDialog::new().file_name(name)).await.ok().flatten()
}

/// What to say once a file is saved: on a phone, also where it went.
pub(crate) fn saved_text() -> SharedString {
    if crate::platform::is_phone() {
        tr("Saved to the Listenook folder in Files, under Exports.")
    } else {
        tr("Export complete")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_urls_round_trip_spaces_and_unicode() {
        let path = "/Users/me/My Talks/聆页 #1.mp3";
        let url = file_url(path);
        assert_eq!(url, "file:///Users/me/My%20Talks/%E8%81%86%E9%A1%B5%20%231.mp3");
        assert_eq!(path_of_url(&url), path);
        assert_eq!(path_of_url("/plain/path.mp3"), "/plain/path.mp3");
    }
}
