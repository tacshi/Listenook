#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple;
pub(crate) mod artwork;
pub(crate) mod audio;
pub(crate) mod blas;
pub(crate) mod capture;
pub(crate) mod local;
pub(crate) mod login;
pub(crate) mod media;
pub(crate) mod persist;
pub(crate) mod playable;
pub(crate) mod remote;
pub(crate) mod secrets;

pub(crate) mod sync;

use nsh_core::prelude::Spawned;

pub(crate) struct Ends(Option<Spawned<()>>);

impl Ends {
    pub(crate) fn with(task: Spawned<()>) -> Self {
        Self(Some(task))
    }
}

impl Drop for Ends {
    fn drop(&mut self) {
        if let Some(task) = self.0.take() {
            task.cancel();
        }
    }
}

pub(crate) fn http() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(30))
        .timeout_read(std::time::Duration::from_secs(60))
        .build()
}

pub(crate) fn set_dock_icon(visible: bool) {
    #[cfg(target_os = "macos")]
    apple::set_dock_icon(visible);
    #[cfg(not(target_os = "macos"))]
    let _ = visible;
}

/// How far behind the player the listener hears it: what has reached the
/// headphones plays on after a pause or a seek.
pub(crate) fn output_latency_ms() -> f64 {
    #[cfg(target_os = "ios")]
    return apple::output_latency_ms();
    #[cfg(not(target_os = "ios"))]
    0.0
}

/// A swipe on a video that may change the screen's brightness or the system
/// volume begins: reads where they are ([`levels`]). False where the app
/// cannot change them (it then dims the picture and turns the player down).
pub(crate) fn begin_levels() -> bool {
    #[cfg(target_os = "ios")]
    {
        apple::begin_levels();
        true
    }
    #[cfg(not(target_os = "ios"))]
    false
}

/// The screen's brightness and the system volume, 0..1, once [`begin_levels`]
/// has read them.
pub(crate) fn levels() -> Option<(f32, f32)> {
    #[cfg(target_os = "ios")]
    return apple::levels();
    #[cfg(not(target_os = "ios"))]
    None
}

pub(crate) fn set_brightness(value: f32) {
    #[cfg(target_os = "ios")]
    apple::set_brightness(value.clamp(0.0, 1.0));
    #[cfg(not(target_os = "ios"))]
    let _ = value;
}

pub(crate) fn set_volume(value: f32) {
    #[cfg(target_os = "ios")]
    apple::set_volume(value.clamp(0.0, 1.0));
    #[cfg(not(target_os = "ios"))]
    let _ = value;
}

/// The swipe that [`begin_levels`] began ended.
pub(crate) fn end_levels() {
    #[cfg(target_os = "ios")]
    apple::end_levels();
}

pub(crate) fn pick_documents() -> bool {
    #[cfg(target_os = "ios")]
    {
        apple::pick_documents();
        true
    }
    #[cfg(not(target_os = "ios"))]
    false
}

pub(crate) fn copy_opened(from: &str, to: &std::path::Path) -> bool {
    #[cfg(target_os = "ios")]
    return apple::copy_opened(from, to);
    #[cfg(not(target_os = "ios"))]
    std::fs::copy(from, to).is_ok()
}

static WOKEN: tokio::sync::Notify = tokio::sync::Notify::const_new();

#[cfg_attr(not(any(target_os = "macos", target_os = "ios")), allow(dead_code))]
pub(crate) fn wake() {
    WOKEN.notify_one();
}

pub(crate) async fn woken() {
    WOKEN.notified().await;
}

pub(crate) fn take_picked() -> Vec<String> {
    #[cfg(target_os = "ios")]
    return apple::take_picked();
    #[cfg(not(target_os = "ios"))]
    Vec::new()
}

pub(crate) fn keep_scroll_on_status_bar_taps() {
    #[cfg(target_os = "ios")]
    apple::keep_scroll_on_status_bar_taps();
}

pub(crate) fn keep_keys() {
    #[cfg(target_os = "ios")]
    apple::keep_keys();
}
