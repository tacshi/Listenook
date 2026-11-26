use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use listenook_core::media::subtitles;
use nsh_core::prelude::*;
use serde::{Deserialize, Serialize};

use crate::services::persist;

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct MonitorConfig {
    pub(crate) folder_path: String,
    pub(crate) paused: bool,
    #[serde(flatten)]
    pub(crate) extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Seen {
    pub(crate) size_bytes: u64,
    pub(crate) modified_ms: u64,
}

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
    pub(crate) fn took(&self, path: &str, state: &Seen) -> bool {
        self.records.get(path).and_then(|record| record["fingerprint"]["size_bytes"].as_u64()) == Some(state.size_bytes)
    }

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

    /// One of the choices of how the app shows on the desktop that the file keeps beside the
    /// folder: on or off, `default` until it is chosen.
    fn flag(&self, key: &str, default: bool) -> bool {
        self.config.extra.get(key).and_then(serde_json::Value::as_bool).unwrap_or(default)
    }

    fn set_flag(&mut self, key: &str, on: bool) {
        self.config.extra.insert(key.into(), on.into());
    }

    fn watch(&mut self, folder: &str) {
        self.config.folder_path = folder.to_owned();
        self.config.paused = false;
    }

    fn pause(&mut self, paused: bool) {
        self.config.paused = paused;
    }

    /// The folder to look in now, unless none is chosen or watching it is paused.
    fn folder(&self) -> Option<PathBuf> {
        (!self.config.folder_path.is_empty() && !self.config.paused).then(|| PathBuf::from(&self.config.folder_path))
    }
}

/// The folder the app watches for new media, and how it shows on the desktop (the tray, the
/// Dock, opening at login), which the same file keeps.
#[derive(Clone, Copy)]
pub(crate) struct MonitorState {
    file: Signal<MonitorFile>,
    last_scan: Stored<BTreeMap<String, Seen>>,
    /// Whether a walk of the watched folder is running: a slow folder takes longer than the
    /// time between scans, and walks must not pile up.
    scanning: Stored<bool>,
}

/// What the person chooses of the watched folder and of how the app shows on the desktop.
#[derive(Debug)]
pub(crate) enum MonitorAction<'a> {
    /// Shows the tray icon or not; it stays while the Dock icon is hidden, as one of them must show.
    SetTrayEnabled(bool),
    /// Shows the Dock icon or not; it stays while the tray icon is off, as one of them must show.
    SetDockVisible(bool),
    SetOpensAtLogin(bool),
    /// Watches `folder` from now on; an empty one stops watching.
    WatchFolder(&'a str),
    SetPaused(bool),
}

impl MonitorState {
    /// Does `action`.
    pub(crate) fn act(&self, action: MonitorAction<'_>) {
        match action {
            MonitorAction::SetTrayEnabled(enabled) => self.set_tray_enabled(enabled),
            MonitorAction::SetDockVisible(visible) => self.set_dock_visible(visible),
            MonitorAction::SetOpensAtLogin(enabled) => self.set_opens_at_login(enabled),
            MonitorAction::WatchFolder(folder) => self.watch_folder(folder),
            MonitorAction::SetPaused(paused) => self.set_paused(paused),
        }
    }

    pub(crate) fn install() {
        let file = persist::data_root().as_deref().map(load).unwrap_or_default();
        super::install(Self { file: signal(file), last_scan: stored(BTreeMap::new()), scanning: stored(false) });
    }

    pub(crate) fn get() -> Self {
        super::installed()
    }

    pub(crate) fn config(&self) -> MonitorConfig {
        self.file.with(|file| file.config.clone())
    }

    fn change(&self, change: impl FnOnce(&mut MonitorFile)) {
        self.file.update(change);
        if let Some(root) = persist::data_root()
            && let Err(error) = save(&root, &self.file.get_untracked())
        {
            log::error!("saving the folder monitor: {error}");
        }
    }

    pub(crate) fn tray_enabled(&self) -> bool {
        self.file.with(|file| file.flag("show_tray_icon", cfg!(target_os = "macos")))
    }

    /// Shows the tray icon or not; it stays while the Dock icon is hidden, as one of them must show.
    fn set_tray_enabled(&self, enabled: bool) {
        if enabled || untracked(|| self.dock_visible()) {
            self.change(|file| file.set_flag("show_tray_icon", enabled));
        }
    }

    pub(crate) fn dock_visible(&self) -> bool {
        !cfg!(target_os = "macos") || !self.tray_enabled() || self.file.with(|file| file.flag("show_dock_icon", true))
    }

    /// Shows the Dock icon or not; it stays while the tray icon is off, as one of them must show.
    fn set_dock_visible(&self, visible: bool) {
        if visible || untracked(|| self.tray_enabled()) {
            self.change(|file| file.set_flag("show_dock_icon", visible));
        }
    }

    pub(crate) fn opens_at_login(&self) -> bool {
        self.file.with(|file| file.flag("launch_at_login", false))
    }

    fn set_opens_at_login(&self, enabled: bool) {
        if crate::services::login::set(enabled) {
            self.change(|file| file.set_flag("launch_at_login", enabled));
        }
    }

    /// Watches `folder` from now on; an empty one stops watching.
    fn watch_folder(&self, folder: &str) {
        self.last_scan.replace(BTreeMap::new());
        self.change(|file| file.watch(folder));
    }

    fn set_paused(&self, paused: bool) {
        self.change(|file| file.pause(paused));
    }

    /// Walks the watched folder, unless none is watched or a walk is running: the media that
    /// has stopped changing since the last walk and was not taken before, now taken.
    pub(crate) async fn take_settled(&self) -> Vec<String> {
        let Some(folder) = self.file.with_untracked(MonitorFile::folder) else {
            return Vec::new();
        };
        if self.scanning.replace(true) {
            return Vec::new();
        }
        let scanned = blocking(move || scan(&folder)).await;
        self.scanning.replace(false);
        let Ok(Some(now)) = scanned else {
            return Vec::new();
        };
        let last = self.last_scan.replace(now.clone());
        let taken = self.file.with_untracked(|file| settled(&last, &now, file));
        if !taken.is_empty() {
            self.change(|file| {
                for path in &taken {
                    if let Some(state) = now.get(path) {
                        file.record(path, state, None);
                    }
                }
            });
        }
        taken
    }
}

fn load(root: &Path) -> MonitorFile {
    persist::read_json(&root.join("inbox_monitor.json")).unwrap_or_default()
}

fn save(root: &Path, file: &MonitorFile) -> std::io::Result<()> {
    persist::write_json(&root.join("inbox_monitor.json"), file)
}

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
            } else if let Some(text) = path.to_str().filter(|text| subtitles::is(text, subtitles::Kind::Media)) {
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
