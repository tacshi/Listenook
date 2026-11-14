use std::path::PathBuf;

use nsh_core::prelude::*;

pub(crate) fn is_phone() -> bool {
    cfg!(any(target_os = "ios", target_os = "android"))
}

const COMPACT_BELOW: f32 = 700.0;

pub(crate) fn compact() -> bool {
    window().width.0 < COMPACT_BELOW
}

pub(crate) fn shared_folder() -> Option<PathBuf> {
    if cfg!(target_os = "ios") {
        Some(PathBuf::from(std::env::var_os("HOME")?).join("Documents"))
    } else if cfg!(target_os = "android") {
        Some(PathBuf::from("/storage/emulated/0/Android/data/app.capyvibe.listenook/files"))
    } else {
        None
    }
}

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

pub(crate) fn has_tray() -> bool {
    cfg!(any(target_os = "macos", target_os = "windows", target_os = "linux"))
}
