//! Watching a folder: media that appears in it is added to the Library,
//! not transcribed. A file is taken once it has stopped changing, and one
//! the user removed from the Library is not taken again.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use listenook_core::subtitles;
use serde::{Deserialize, Serialize};

/// What is watched (`inbox_monitor.json`, as the Flutter app writes it).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct MonitorConfig {
    pub(crate) folder_path: String,
    pub(crate) paused: bool,
    /// What the Flutter app keeps here besides (extensions, tray and dock
    /// choices): written back as it was.
    #[serde(flatten)]
    pub(crate) extra: serde_json::Map<String, serde_json::Value>,
}

/// A file as it was when it was taken: its path, size and time of change.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Seen {
    pub(crate) size_bytes: u64,
    pub(crate) modified_ms: u64,
}

/// The monitor's file: its configuration and a record of every file it
/// has taken, by path, as the Flutter app writes them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct MonitorFile {
    pub(crate) version: u32,
    pub(crate) config: MonitorConfig,
    pub(crate) records: BTreeMap<String, serde_json::Value>,
    #[serde(flatten)]
    pub(crate) extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for MonitorFile {
    fn default() -> Self {
        Self { version: 1, config: MonitorConfig::default(), records: BTreeMap::new(), extra: Default::default() }
    }
}

impl MonitorFile {
    /// Whether a file was taken before as it is now: added, or added and
    /// then removed from the Library by the user. A file that has changed
    /// size since is a new one.
    pub(crate) fn took(&self, path: &str, state: &Seen) -> bool {
        self.records.get(path).and_then(|record| record["fingerprint"]["size_bytes"].as_u64()) == Some(state.size_bytes)
    }

    /// Records that a file was taken into the Library as job `job_id`.
    pub(crate) fn record(&mut self, path: &str, state: &Seen, job_id: Option<&str>) {
        let modified = listenook_core::iso_from_millis(state.modified_ms as i64);
        let mut record = serde_json::json!({
            "fingerprint": {"identity": path, "path": path, "size_bytes": state.size_bytes, "modified_at": modified},
            "disposition": "queued",
            "updated_at": listenook_core::now_iso(),
        });
        if let Some(job_id) = job_id {
            record["job_id"] = job_id.into();
        }
        self.records.insert(path.to_owned(), record);
    }
}

/// The media files under `folder`, hidden files and folders left out, each
/// with its size and time of change. None when the folder cannot be read.
pub(crate) fn scan(folder: &Path) -> Option<BTreeMap<String, Seen>> {
    let mut found = BTreeMap::new();
    let mut pending: Vec<PathBuf> = vec![folder.to_owned()];
    std::fs::read_dir(folder).ok()?;
    while let Some(directory) = pending.pop() {
        for entry in std::fs::read_dir(&directory).into_iter().flatten().flatten() {
            let path = entry.path();
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if metadata.is_dir() {
                pending.push(path);
            } else if let Some(text) = path.to_str().filter(|text| subtitles::is_media(text)) {
                let modified_ms = metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                    .map_or(0, |since| since.as_millis() as u64);
                found.insert(text.to_owned(), Seen { size_bytes: metadata.len(), modified_ms });
            }
        }
    }
    Some(found)
}

/// The files to take now: in this scan as they were in the last one (so
/// they have stopped changing), and not taken before as they are.
pub(crate) fn settled(last: &BTreeMap<String, Seen>, now: &BTreeMap<String, Seen>, file: &MonitorFile) -> Vec<String> {
    now.iter()
        .filter(|(path, state)| last.get(*path) == Some(state) && !file.took(path, state))
        .map(|(path, _)| path.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_is_taken_once_it_stops_changing_and_only_once() {
        let state = |size| Seen { size_bytes: size, modified_ms: 1 };
        let scan = |size| BTreeMap::from([("/w/talk.mp3".to_owned(), state(size))]);
        let mut file = MonitorFile::default();
        assert!(settled(&BTreeMap::new(), &scan(10), &file).is_empty(), "first sight is not settled");
        assert!(settled(&scan(10), &scan(20), &file).is_empty(), "still being written");
        assert_eq!(settled(&scan(20), &scan(20), &file), ["/w/talk.mp3"]);
        file.record("/w/talk.mp3", &state(20), Some("job-1"));
        assert!(settled(&scan(20), &scan(20), &file).is_empty(), "taken already");
        assert_eq!(settled(&scan(30), &scan(30), &file), ["/w/talk.mp3"], "a new version is taken again");
    }

    #[test]
    fn the_flutter_apps_records_are_read_and_kept() {
        let text = r#"{"version":1,"config":{"folder_path":"/w","paused":false,"show_tray_icon":true},
            "records":{"/w/old.mp3":{"fingerprint":{"path":"/w/old.mp3","size_bytes":7},"disposition":"dismissed"}}}"#;
        let mut file: MonitorFile = serde_json::from_str(text).unwrap();
        assert!(file.took("/w/old.mp3", &Seen { size_bytes: 7, modified_ms: 0 }), "a dismissed file stays dismissed");
        file.record("/w/new.mp3", &Seen { size_bytes: 9, modified_ms: 1_000 }, Some("j"));
        let written = serde_json::to_value(&file).unwrap();
        assert_eq!(written["config"]["show_tray_icon"], true);
        assert_eq!(written["records"]["/w/old.mp3"]["disposition"], "dismissed");
        assert_eq!(written["records"]["/w/new.mp3"]["fingerprint"]["modified_at"], "1970-01-01T00:00:01.000000Z");
    }

    #[test]
    fn a_scan_finds_media_in_subfolders_and_skips_hidden_files() {
        let root = std::env::temp_dir().join(format!("listenook-monitor-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::create_dir_all(root.join(".hidden")).unwrap();
        for name in ["a.mp3", "sub/b.mp4", "notes.txt", ".c.mp3", ".hidden/d.mp3"] {
            std::fs::write(root.join(name), b"x").unwrap();
        }
        let found = scan(&root).unwrap();
        let mut names: Vec<&str> = found.keys().map(|path| path.rsplit(['/', '\\']).next().unwrap()).collect();
        names.sort();
        assert_eq!(names, ["a.mp3", "b.mp4"]);
        assert!(scan(&root.join("missing")).is_none());
        let _ = std::fs::remove_dir_all(root);
    }
}
