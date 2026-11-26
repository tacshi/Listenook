use listenook_core::media::subtitles;
use nsh_core::{
    file_dialog::{FileFilter, OpenDialog},
    prelude::*,
};

use crate::state::monitor::MonitorState;
use crate::ui::tr;
use crate::{
    state::{Filter, store},
    ui::{Tone, toast},
};

pub(crate) fn reveal(path: String) {
    let answer = reveal_path(path);
    store().run(async move {
        if answer.await.is_err() {
            toast(Tone::Error, tr("Couldn’t show the file. It may have been moved."));
        }
    });
}

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
        } else if subtitles::is(&path, subtitles::Kind::Media) || subtitles::is(&path, subtitles::Kind::Subtitles) {
            out.push(path);
        }
    }
    out.sort();
    out
}

pub(crate) fn add_media(paths: Vec<String>) {
    let store = store();
    let added = store.add_files(&expanded(paths));
    if added == 0 {
        toast(Tone::Info, tr("No new audio or video files were found."));
    } else {
        store.act(crate::state::Action::Show(Filter::All));
    }
}

pub(crate) fn pick_media() {
    RELINKING.set(None);
    if crate::services::pick_documents() {
        return;
    }
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
            toast(Tone::Error, crate::ui::error_text(code));
            return;
        }
    };
    let apply = move || {
        store.update_job(&job_id, |job| {
            job.apply(listenook_core::Change::ReplaceTranscript(
                document,
                Some(listenook_core::TranscriptAcquisitionMode::ImportedSubtitles),
            ));
            job.apply(listenook_core::Change::Finish(false));
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
    static RELINKING: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

pub(crate) fn relink(job_id: String) {
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

fn relinked(job_id: &str, path: &str) {
    let store = store();
    store.update_job(job_id, |job| job.apply(listenook_core::Change::Relink(path.to_owned())));
    crate::services::playable::forget(job_id);
    toast(Tone::Success, tr("Media relinked."));
}

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

pub(crate) fn import_picked(paths: Vec<String>) {
    let picked = paths.len();
    let found: Vec<std::path::PathBuf> = paths.into_iter().map(std::path::PathBuf::from).collect();
    let copies = found.clone();
    if let Some(job_id) = RELINKING.take() {
        let media = found.iter().find(|path| {
            path.is_file() && path.to_str().is_some_and(|path| subtitles::is(path, subtitles::Kind::Media))
        });
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
    for copy in copies {
        let _ = std::fs::remove_file(copy);
    }
}

/// Puts a recording made in the app into the Library as `title`, moving its
/// file into the library's media. The new recording's id.
pub(crate) fn add_recording(path: &std::path::Path, title: &str) -> Option<String> {
    let store = store();
    let media = store.data_root()?.join("media");
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("m4a").to_lowercase();
    let kept = media.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&media).ok()?;
    if std::fs::rename(path, &kept).is_err() {
        std::fs::copy(path, &kept).ok()?;
        let _ = std::fs::remove_file(path);
    }
    let mut job = store.new_job(kept.to_str()?, listenook_core::JobSourceOrigin::Manual);
    job.apply(listenook_core::Change::Rename(title));
    let id = job.id.clone();
    store.act(crate::state::Action::AddJob(job));
    Some(id)
}

pub(crate) fn import_opened(paths: Vec<String>) -> usize {
    take_in_with(paths.into_iter().map(std::path::PathBuf::from).collect(), |from, to| {
        let Some(source) = from.to_str() else {
            return false;
        };
        let copied = crate::services::copy_opened(source, to);
        if copied && source.contains("/Inbox/") {
            let _ = std::fs::remove_file(from);
        }
        copied
    })
}

fn take_in(found: Vec<std::path::PathBuf>) -> usize {
    take_in_with(found, |from, to| {
        std::fs::rename(from, to).is_ok() || (std::fs::copy(from, to).is_ok() && std::fs::remove_file(from).is_ok())
    })
}

fn take_in_with(found: Vec<std::path::PathBuf>, bring: impl Fn(&std::path::Path, &std::path::Path) -> bool) -> usize {
    let store = store();
    let Some(root) = store.data_root() else {
        return 0;
    };
    let media = root.join("media");
    let mut taken: Vec<(String, String)> = Vec::new();
    for path in
        found.into_iter().filter(|path| path.to_str().is_some_and(|path| subtitles::is(path, subtitles::Kind::Media)))
    {
        let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("media").to_lowercase();
        let title = path.file_stem().and_then(|stem| stem.to_str()).unwrap_or("Recording").to_owned();
        let kept = media.join(format!("{}.{extension}", uuid::Uuid::new_v4()));
        let moved = std::fs::create_dir_all(&media).is_ok() && bring(&path, &kept);
        if moved && let Some(kept) = kept.to_str() {
            taken.push((kept.to_owned(), title));
        }
    }
    if taken.is_empty() {
        return 0;
    }
    let paths: Vec<String> = taken.iter().map(|(path, _)| path.clone()).collect();
    store.add_files(&paths);
    for (path, title) in taken {
        if let Some(job) = store.jobs().iter().find(|job| job.source_path == path) {
            store.update_job(&job.id, |job| job.apply(listenook_core::Change::Rename(&title)));
        }
    }
    store.act(crate::state::Action::Show(Filter::All));
    paths.len()
}

pub(crate) async fn save_target(name: String) -> Option<std::path::PathBuf> {
    if crate::platform::is_phone() {
        return crate::platform::export_path(&name);
    }
    pick_save_path(nsh_core::file_dialog::SaveDialog::new().file_name(name)).await.ok().flatten()
}

pub(crate) fn saved_text() -> SharedString {
    if crate::platform::is_phone() {
        tr("Saved to the Listenook folder in Files, under Exports.")
    } else {
        tr("Export complete")
    }
}

/// Takes in the media that has stopped changing in the watched folder since the last look.
pub(crate) fn take_from_watched_folder() {
    let store = store();
    store.run(async move {
        let taken = MonitorState::get().take_settled().await;
        if taken.is_empty() {
            return;
        }
        let added = store.add_files(&taken);
        if added > 0 {
            toast(Tone::Info, format!("{added} {}", tr("new recordings from the watched folder.")));
        }
    });
}
