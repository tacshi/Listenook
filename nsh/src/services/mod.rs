//! What the app asks of the network and the machine.

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
pub(crate) mod transcribe;
pub(crate) mod updater;

use nsh_core::prelude::Spawned;

/// A task that ends when this is dropped: for a helper running beside
/// work that may itself be dropped, which a plain handle would outlive.
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

/// Requests that give up on a connection that has gone quiet, instead of
/// waiting on it for ever.
pub(crate) fn http() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(30))
        .timeout_read(std::time::Duration::from_secs(60))
        .build()
}

/// Shows the app's Dock icon or hides it (a Mac's Dock only).
pub(crate) fn set_dock_icon(visible: bool) {
    #[cfg(target_os = "macos")]
    apple::set_dock_icon(visible);
    #[cfg(not(target_os = "macos"))]
    let _ = visible;
}

/// Shows the system's file picker on an iPhone or iPad; false elsewhere,
/// where there is none to show this way.
pub(crate) fn pick_documents() -> bool {
    #[cfg(target_os = "ios")]
    {
        apple::pick_documents();
        true
    }
    #[cfg(not(target_os = "ios"))]
    false
}

/// The files picked there since the last call.
pub(crate) fn take_picked() -> Vec<String> {
    #[cfg(target_os = "ios")]
    return apple::take_picked();
    #[cfg(not(target_os = "ios"))]
    Vec::new()
}

/// Keeps a hardware keyboard's keys coming to the app's shortcuts on an
/// iPhone or iPad; nothing elsewhere.
pub(crate) fn keep_keys() {
    #[cfg(target_os = "ios")]
    apple::keep_keys();
}
