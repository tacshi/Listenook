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

pub(crate) fn file_url(path: &str) -> String {
    let path = path.replace('\\', "/");
    let mut url = String::from("file://");
    if has_drive(&path) {
        url.push('/');
    }
    for (at, byte) in path.bytes().enumerate() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => url.push(byte as char),
            b':' if at == 1 && has_drive(&path) => url.push(':'),
            _ => url.push_str(&format!("%{byte:02X}")),
        }
    }
    url
}

fn has_drive(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

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
    let path = String::from_utf8_lossy(&out).into_owned();
    match path.strip_prefix('/') {
        Some(rest) if has_drive(rest) => rest.to_owned(),
        _ => path,
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

    #[test]
    fn windows_paths_make_file_urls_with_their_drive() {
        let url = file_url(r"C:\Users\me\My Talks\a.mp4");
        assert_eq!(url, "file:///C:/Users/me/My%20Talks/a.mp4");
        assert_eq!(path_of_url(&url), "C:/Users/me/My Talks/a.mp4");
    }
}
