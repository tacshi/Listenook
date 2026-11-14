#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple;
pub(crate) mod audio;
pub(crate) mod blas;
pub(crate) mod llm;
pub(crate) mod local;
pub(crate) mod login;
pub(crate) mod media;
pub(crate) mod notify;
pub(crate) mod playable;
pub(crate) mod podcasts;
pub(crate) mod remote;
pub(crate) mod sync;
pub(crate) mod transcribe;
pub(crate) mod updater;

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

pub(crate) fn take_picked() -> Vec<String> {
    #[cfg(target_os = "ios")]
    return apple::take_picked();
    #[cfg(not(target_os = "ios"))]
    Vec::new()
}

pub(crate) fn keep_keys() {
    #[cfg(target_os = "ios")]
    apple::keep_keys();
}
