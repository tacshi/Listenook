//! What differs on a phone or a tablet: how wide the window is, and where
//! files come in and go out when there is no file dialog.

use std::path::PathBuf;

use nsh_core::prelude::*;

/// Whether this build is for a phone or a tablet: no file dialogs, no
/// windows, one app on screen.
pub(crate) fn is_phone() -> bool {
    cfg!(any(target_os = "ios", target_os = "android"))
}

/// Below this width there is no room for a sidebar or a side panel.
const COMPACT_BELOW: f32 = 700.0;

/// Whether the window is as narrow as a phone's. Tracked: layouts follow
/// the window, also on a desktop.
pub(crate) fn compact() -> bool {
    window().width.0 < COMPACT_BELOW
}

/// The folder people reach from outside the app: "On My iPhone › Listenook"
/// in the Files app on iOS, the app's own folder on shared storage on
/// Android. Media put there is imported, and exports are written there.
pub(crate) fn shared_folder() -> Option<PathBuf> {
    if cfg!(target_os = "ios") {
        Some(PathBuf::from(std::env::var_os("HOME")?).join("Documents"))
    } else if cfg!(target_os = "android") {
        Some(PathBuf::from("/storage/emulated/0/Android/data/app.capyvibe.listenook/files"))
    } else {
        None
    }
}

/// Where a file named `name` is written for the user to find, on a phone:
/// `Exports` in the shared folder, under a name not yet taken there.
pub(crate) fn export_path(name: &str) -> Option<PathBuf> {
    let folder = shared_folder()?.join("Exports");
    std::fs::create_dir_all(&folder).ok()?;
    let (stem, extension) = name.rsplit_once('.').unwrap_or((name, ""));
    (0..1000)
        .map(|count| {
            let numbered = if count == 0 { stem.to_owned() } else { format!("{stem} {count}") };
            folder.join(if extension.is_empty() { numbered } else { format!("{numbered}.{extension}") })
        })
        .find(|path| !path.exists())
}

/// Whether this platform has a tray (the menu bar on a Mac) to stay in.
pub(crate) fn has_tray() -> bool {
    cfg!(any(target_os = "macos", target_os = "windows", target_os = "linux"))
}
