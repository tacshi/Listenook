//! The work the app does on the library: transcribing, asking the AI, downloading podcasts,
//! importing files, recording, syncing with other devices, and telling the person when
//! something they waited for is done. It drives the state and the services; nothing below it
//! knows it.

pub(crate) mod ai;
pub(crate) mod capture;
pub(crate) mod import;
pub(crate) mod notify;
pub(crate) mod podcasts;
pub(crate) mod sync;
pub(crate) mod transcribe;
pub(crate) mod updater;

use std::time::Duration;

use nsh_core::prelude::*;

use crate::state::{Store, activity::ActivityState, monitor::MonitorState, podcast::PodcastState, sleep::SleepState};

/// Starts what runs beside the store for as long as the app does: the features' states, the
/// work a run that ended mid-way left, and word when a recording is done.
pub(crate) fn install(store: Store) {
    PodcastState::install(store);
    ActivityState::install();
    SleepState::install();
    MonitorState::install();
    capture::CaptureState::install(store);
    sync::SyncState::install(store);
    store.when_status_changes(notify::job_changed);
    transcribe::clean_up_left(store);
    transcribe::resume_when_online(store);
    if std::env::var("LISTENOOK_START").as_deref() == Ok("import") {
        spawn(async {
            timer(Duration::from_millis(500)).await;
            import::import_shared();
        });
    }
}
