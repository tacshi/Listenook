//! The app's own updates on the desktops, through NSH's built-in prompt: it checks the releases
//! `nsh.json`'s `"updater"` names, shows what changed, downloads the update (only a patch from
//! this version when the release has one, resuming a download that broke off) and installs it
//! on a relaunch or as the app quits. Skip This Version and automatic updates are the user's to
//! choose in it. Phones and tablets update from their app store.

use std::time::Duration;

use nsh_core::{
    prelude::*,
    runtime::{UpdatePromptOptions, prompt_for_update},
};

use crate::state::store;

pub(crate) const SELF_UPDATING: bool = cfg!(any(target_os = "linux", target_os = "macos", windows));

/// How long after launch the first check waits, so it stays out of the way of startup.
const FIRST_CHECK: Duration = Duration::from_secs(10);
/// How often a running app looks for a newer version again: once a day, as Sparkle does, so a
/// prompt the user left open isn't asked again soon after.
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

/// A check `quiet`ly, as the app makes on its own, shows nothing unless there's a version the
/// user hasn't skipped; otherwise the user hears what it found, being up to date included.
fn options(quiet: bool) -> UpdatePromptOptions {
    UpdatePromptOptions::default().quiet(quiet).locale(store().lang().code())
}

/// Checks now, as the user asked to.
pub(crate) fn check() {
    if SELF_UPDATING {
        store().run(prompt_for_update(options(false)));
    }
}

/// Checks quietly a little after launch and then every day, for as long as the app runs.
pub(crate) fn watch() {
    if !SELF_UPDATING {
        return;
    }
    store().run(async move {
        timer(FIRST_CHECK).await;
        loop {
            prompt_for_update(options(true)).await;
            timer(CHECK_EVERY).await;
        }
    });
}
