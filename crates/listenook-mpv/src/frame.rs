//! One picture of a video, as mpv decodes it: a cover for videos the system cannot open itself,
//! such as MKV files on Apple devices.

use std::{
    path::Path,
    time::{Duration, Instant},
};

use crate::mpv::{Event, Mpv};

/// The longest side of the picture, in pixels.
const LONGEST_SIDE: u32 = 640;

/// How long a picture may take before it is given up on.
const GIVE_UP: Duration = Duration::from_secs(30);

/// A picture: `width` × `height` pixels, RGBA, row by row.
pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// The picture `at_ms` into the video at `source`, at most 640 pixels on its longer side.
/// Blocks until it is decoded: `None` if it could not be.
pub fn picture(source: &Path, at_ms: i64) -> Option<Picture> {
    let start = format!("{:.3}", at_ms.max(0) as f64 / 1000.0);
    let scale = format!("scale=w={LONGEST_SIDE}:h={LONGEST_SIDE}:force_original_aspect_ratio=decrease");
    let options = [
        ("vo", "null"),
        ("pause", "yes"),
        ("start", &start),
        ("aid", "no"),
        ("sid", "no"),
        ("hwdec", "no"),
        ("vf", &scale),
    ];
    let mpv =
        Mpv::start(&options, None, Box::new(())).inspect_err(|why| log::warn!("mpv for a picture: {why}")).ok()?;
    mpv.command(&["loadfile", &source.to_string_lossy()]);
    let deadline = Instant::now() + GIVE_UP;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            log::warn!("mpv took over {GIVE_UP:?} for a picture of {}", source.display());
            return None;
        }
        match mpv.wait_event(left.as_secs_f64()) {
            Event::Restarted => break,
            Event::Ended(_) | Event::Shutdown => return None,
            _ => {}
        }
    }
    let (width, height, rgba) = mpv.picture()?;
    Some(Picture { width, height, rgba })
}
