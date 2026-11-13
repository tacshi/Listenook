//! The app's files: one manifest per job under `jobs/<id>/`, and one JSON
//! file each for settings and the podcast catalog, laid out as the Flutter
//! app lays them out. Writes go to a `.tmp` file first and are renamed.

use std::{
    fs, io,
    path::{Path, PathBuf},
};

use listenook_core::{Job, LibraryCatalog, Settings, podcast::Catalog};

/// Where the app keeps its data: the folder the Flutter app used, so a
/// library made there is this app's as it is. None when it must not touch
/// the disk (`LISTENOOK_EPHEMERAL`, set by tests). `LISTENOOK_DATA_DIR`
/// overrides the platform's place.
pub(crate) fn data_root() -> Option<PathBuf> {
    if std::env::var_os("LISTENOOK_EPHEMERAL").is_some() {
        return None;
    }
    if let Some(root) = std::env::var_os("LISTENOOK_DATA_DIR") {
        return Some(PathBuf::from(root));
    }
    const ID: &str = "app.capyvibe.listenook";
    if cfg!(target_os = "android") {
        // An Android app has no home folder: NSH says where its files go
        // (asked once, on the engine thread, when the store is made).
        return ANDROID_ROOT.get().cloned().flatten();
    }
    let home = PathBuf::from(std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))?);
    Some(if cfg!(target_os = "macos") {
        home.join("Library/Application Support").join(ID)
    } else if cfg!(target_os = "ios") {
        // An app's own container: there is no folder per bundle id in it.
        home.join("Library/Application Support")
    } else if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map_or(home.join("AppData/Roaming"), PathBuf::from).join("Capyvibe/Listenook")
    } else {
        std::env::var_os("XDG_DATA_HOME").map_or(home.join(".local/share"), PathBuf::from).join(ID)
    })
}

static ANDROID_ROOT: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

/// Learns where the app's files go on platforms where only NSH knows.
/// Call it on the engine thread before anything reads [`data_root`].
pub(crate) fn learn_data_root() {
    if cfg!(target_os = "android") {
        let _ = ANDROID_ROOT.set(nsh_core::prelude::data_dir());
    }
}

fn write_atomic(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, contents)?;
    fs::rename(tmp, path)
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> io::Result<()> {
    write_atomic(path, &serde_json::to_vec_pretty(value).map_err(io::Error::other)?)
}

/// Every readable job, newest first. A manifest that cannot be read is skipped.
pub(crate) fn load_jobs(root: &Path) -> Vec<Job> {
    let mut jobs: Vec<Job> = fs::read_dir(root.join("jobs"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| read_json::<Job>(&entry.path().join("manifest.json")))
        .filter(|job| Job::is_valid_id(&job.id))
        .collect();
    jobs.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    jobs
}

/// One job's manifest, when it is there and readable.
pub(crate) fn load_job(root: &Path, id: &str) -> Option<Job> {
    if !Job::is_valid_id(id) {
        return None;
    }
    read_json::<Job>(&root.join("jobs").join(id).join("manifest.json")).filter(|job| job.id == id)
}

/// Writes a job's manifest.
pub(crate) fn save_job(root: &Path, job: &Job) -> io::Result<()> {
    if !Job::is_valid_id(&job.id) {
        return Err(io::Error::other("invalid job id"));
    }
    write_json(&root.join("jobs").join(&job.id).join("manifest.json"), job)
}

/// Removes a job's directory.
pub(crate) fn delete_job(root: &Path, id: &str) -> io::Result<()> {
    if !Job::is_valid_id(id) {
        return Err(io::Error::other("invalid job id"));
    }
    match fs::remove_dir_all(root.join("jobs").join(id)) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

/// The saved settings, or the defaults.
pub(crate) fn load_settings(root: &Path) -> Settings {
    read_json::<Settings>(&root.join("settings.json")).unwrap_or_default().sanitized()
}

/// Writes the settings.
pub(crate) fn save_settings(root: &Path, settings: &Settings) -> io::Result<()> {
    write_json(&root.join("settings.json"), settings)
}

/// The saved groups and tags, or none.
pub(crate) fn load_library_catalog(root: &Path) -> LibraryCatalog {
    read_json(&root.join("library_catalog.json")).unwrap_or_default()
}

/// Writes the groups and tags.
pub(crate) fn save_library_catalog(root: &Path, catalog: &LibraryCatalog) -> io::Result<()> {
    write_json(&root.join("library_catalog.json"), catalog)
}

/// The recordings removed from this device and when, for a sync to
/// remove them from the other device rather than bring them back.
pub(crate) fn load_removed(root: &Path) -> listenook_core::sync::Removed {
    read_json(&root.join("removed.json")).unwrap_or_default()
}

/// Writes the removed recordings.
pub(crate) fn save_removed(root: &Path, removed: &listenook_core::sync::Removed) -> io::Result<()> {
    write_json(&root.join("removed.json"), removed)
}

/// The folder monitor's saved state, or none.
pub(crate) fn load_monitor(root: &Path) -> super::monitor::MonitorFile {
    read_json(&root.join("inbox_monitor.json")).unwrap_or_default()
}

/// Writes the folder monitor's state.
pub(crate) fn save_monitor(root: &Path, file: &super::monitor::MonitorFile) -> io::Result<()> {
    write_json(&root.join("inbox_monitor.json"), file)
}

/// The saved podcast catalog, or an empty one.
pub(crate) fn load_catalog(root: &Path) -> Catalog {
    read_json(&root.join("podcast_catalog.json")).unwrap_or_default()
}

/// Writes the podcast catalog, each feed with its newest 50 episodes.
pub(crate) fn save_catalog(root: &Path, catalog: &Catalog) -> io::Result<()> {
    let mut trimmed = catalog.clone();
    for feed in &mut trimmed.feeds {
        feed.episodes.truncate(50);
    }
    write_json(&root.join("podcast_catalog.json"), &trimmed)
}

/// How far each episode was listened to, most recent first.
pub(crate) fn load_listening(root: &Path) -> Vec<listenook_core::podcast::ListenProgress> {
    read_json::<serde_json::Value>(&root.join("podcast_playback.json"))
        .and_then(|file| serde_json::from_value(file.get("entries")?.clone()).ok())
        .unwrap_or_default()
}

/// Writes how far episodes were listened to: the 200 most recent.
pub(crate) fn save_listening(root: &Path, entries: &[listenook_core::podcast::ListenProgress]) -> io::Result<()> {
    let kept: Vec<_> = entries.iter().take(200).collect();
    write_json(&root.join("podcast_playback.json"), &serde_json::json!({"version": 1, "entries": kept}))
}

/// Where an episode of job `id` is downloaded to.
pub(crate) fn podcast_path(root: &Path, id: &str, file_name: &str) -> PathBuf {
    root.join("podcasts").join(id).join(file_name)
}

#[cfg(test)]
mod tests {
    use listenook_core::{JobStatus, ThemeMode};

    use super::*;

    fn temp(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("listenook-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        root
    }

    #[test]
    fn jobs_round_trip_newest_first_and_delete() {
        let root = temp("jobs");
        let job = |id: &str, created: &str| Job {
            id: id.into(),
            created_at: created.into(),
            status: JobStatus::Completed,
            ..Job::default()
        };
        save_job(&root, &job("a", "2026-01-01T00:00:00.000Z")).unwrap();
        save_job(&root, &job("b", "2026-02-01T00:00:00.000Z")).unwrap();
        assert!(save_job(&root, &job("../x", "")).is_err());
        fs::create_dir_all(root.join("jobs/broken")).unwrap();
        fs::write(root.join("jobs/broken/manifest.json"), "{").unwrap();
        let jobs = load_jobs(&root);
        assert_eq!(jobs.iter().map(|j| j.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
        assert_eq!(jobs[0].status, JobStatus::Completed);
        delete_job(&root, "b").unwrap();
        delete_job(&root, "b").unwrap();
        assert_eq!(load_jobs(&root).len(), 1);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn settings_round_trip_and_default_when_missing() {
        let root = temp("settings");
        assert_eq!(load_settings(&root).theme_mode, ThemeMode::System);
        let settings = Settings { theme_mode: ThemeMode::Dark, mimic_rep_goal: 0, ..Settings::default() };
        save_settings(&root, &settings).unwrap();
        let loaded = load_settings(&root);
        assert_eq!(loaded.theme_mode, ThemeMode::Dark);
        assert_eq!(loaded.mimic_rep_goal, 3, "an out-of-range goal reads as the default");
        let _ = fs::remove_dir_all(root);
    }
}

/// Where a video was left in the player, and with which subtitles
/// (`video_playback.json`, as the Flutter app writes it).
#[derive(Debug, Clone, PartialEq, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub(crate) struct VideoPosition {
    pub(crate) path: String,
    pub(crate) position_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) subtitle_id: Option<String>,
    pub(crate) updated_at: String,
    #[serde(flatten)]
    extra: serde_json::Map<String, serde_json::Value>,
}

fn video_positions(root: &Path) -> Vec<VideoPosition> {
    read_json::<serde_json::Value>(&root.join("video_playback.json"))
        .and_then(|file| serde_json::from_value(file.get("entries")?.clone()).ok())
        .unwrap_or_default()
}

/// Where the video at `path` was left, if it was played before.
pub(crate) fn video_position(root: &Path, path: &str) -> Option<VideoPosition> {
    video_positions(root).into_iter().find(|entry| entry.path == path)
}

/// Remembers where a video is and its subtitles; the most recent two
/// hundred videos are kept.
pub(crate) fn remember_video(root: &Path, path: &str, position_ms: i64, subtitle_id: Option<String>) {
    let mut entries = video_positions(root);
    entries.retain(|entry| entry.path != path);
    entries.insert(
        0,
        VideoPosition {
            path: path.to_owned(),
            position_ms,
            subtitle_id,
            updated_at: listenook_core::now_iso(),
            extra: Default::default(),
        },
    );
    entries.truncate(200);
    if let Err(error) =
        write_json(&root.join("video_playback.json"), &serde_json::json!({"version": 1, "entries": entries}))
    {
        log::error!("saving video positions: {error}");
    }
}

/// Where a recording's media is now, when the app's folder has moved under
/// it. On an iPhone or iPad the app's container has a new name after an
/// update or a reinstall, so a path kept in full no longer leads anywhere:
/// what follows the container's own folders (`Library/Application Support`,
/// `Documents`) is looked for in the container there is now. `None` when
/// the path is good as it is, or leads nowhere either way.
pub(crate) fn rehomed(path: &str, root: &Path, exists: impl Fn(&Path) -> bool) -> Option<String> {
    if path.is_empty() || exists(Path::new(path)) {
        return None;
    }
    // The data root is `<container>/Library/Application Support` there.
    let container = root.parent().and_then(Path::parent);
    let candidates = [
        ("/Library/Application Support/", Some(root.to_path_buf())),
        ("/Documents/", container.map(|container| container.join("Documents"))),
    ];
    candidates.into_iter().find_map(|(marker, base)| {
        let rest = &path[path.rfind(marker)? + marker.len()..];
        let moved = base?.join(rest);
        (exists(&moved)).then(|| moved.to_string_lossy().into_owned())
    })
}

#[cfg(test)]
mod rehomed_tests {
    use super::*;

    #[test]
    // An iOS container's paths, which only Unix joins with `/`.
    #[cfg_attr(windows, ignore = "iOS container paths")]
    fn media_is_found_again_when_the_container_is_renamed() {
        let root = Path::new("/var/mobile/Containers/Data/Application/NEW/Library/Application Support");
        let there = |path: &Path| path.starts_with("/var/mobile/Containers/Data/Application/NEW");
        let old = "/var/mobile/Containers/Data/Application/OLD/Library/Application Support/media/a.m4a";
        assert_eq!(
            rehomed(old, root, there).as_deref(),
            Some("/var/mobile/Containers/Data/Application/NEW/Library/Application Support/media/a.m4a")
        );
        let shared = "/var/mobile/Containers/Data/Application/OLD/Documents/b.mp4";
        assert_eq!(
            rehomed(shared, root, there).as_deref(),
            Some("/var/mobile/Containers/Data/Application/NEW/Documents/b.mp4")
        );
        // A path that still leads somewhere is left alone, and so is one that leads nowhere.
        let good = "/var/mobile/Containers/Data/Application/NEW/Library/Application Support/media/a.m4a";
        assert_eq!(rehomed(good, root, there), None);
        assert_eq!(rehomed("/somewhere/else.mp3", root, there), None);
        assert_eq!(rehomed(old, root, |_| false), None);
    }
}
