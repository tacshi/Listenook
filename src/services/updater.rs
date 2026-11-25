use nsh_core::prelude::*;

pub(crate) const SELF_UPDATING: bool = cfg!(any(target_os = "linux", target_os = "macos", windows));

#[derive(Debug, Clone, PartialEq, Default)]
#[cfg_attr(
    not(any(target_os = "linux", target_os = "macos", windows)),
    expect(dead_code, reason = "phones and tablets update from their app store, so only desktops leave Idle")
)]
pub(crate) enum UpdateState {
    #[default]
    Idle,
    Checking,
    UpToDate,
    /// A newer version is being downloaded and unpacked beside the app.
    Downloading(SharedString),
    /// A newer version waits beside the app: a restart, or quitting, puts it in place.
    Ready(SharedString),
    /// A newer version the app cannot put in place itself: its version and release page.
    Manual(SharedString, SharedString),
    Installing,
    Unpackaged,
    Failed(SharedString),
}

#[cfg(any(target_os = "linux", target_os = "macos", windows))]
mod desktop {
    use std::{path::PathBuf, sync::Mutex, time::Duration};

    use nsh_core::{element::desktop, prelude::*};
    use nsh_updater::{
        Available, CONFIG_ASSET, Config, Download,
        install::{Installation, Staged},
        platform,
    };

    use super::UpdateState;
    use crate::{
        state::{store, tr},
        ui::{Tone, toast_with_action},
    };

    /// How long after launch the first check waits, so it stays out of the way of startup.
    const FIRST_CHECK: Duration = Duration::from_secs(10);
    /// How often a running app looks for a newer version again.
    const CHECK_EVERY: Duration = Duration::from_secs(6 * 60 * 60);

    /// The update downloaded and unpacked beside the app, waiting for a restart or a quit.
    static STAGED: Mutex<Option<Staged>> = Mutex::new(None);

    fn packaged() -> Option<(Config, Vec<u8>)> {
        let executable = std::env::current_exe().ok()?;
        let beside = executable.parent()?;
        let resources =
            if cfg!(target_os = "macos") { beside.parent()?.join("Resources/nsh") } else { beside.join("nsh") };
        let bytes = std::fs::read(resources.join("assets").join(CONFIG_ASSET)).ok()?;
        Some((Config::parse(&bytes).ok()?, bytes))
    }

    async fn get(url: &str) -> Result<Vec<u8>, String> {
        let response = fetch(HttpRequest::get(url)).await?;
        if response.ok() { Ok(response.body) } else { Err(format!("HTTP {}", response.status())) }
    }

    /// The newer version, if any; an empty error for a development run, which has nothing to update.
    async fn find() -> Result<Option<(Config, Vec<u8>, Available)>, String> {
        let Some((config, bytes)) = packaged() else {
            return Err(String::new());
        };
        if let Some(installation) = Installation::current(&config.id, &bytes) {
            // What an earlier update left: Windows' old executable, or one staged by a run that crashed.
            drop(blocking(move || installation.remove_leftovers()).await);
        }
        let manifest = get(&config.manifest_url()).await?;
        let signature = match config.signature_url() {
            Some(url) => Some(get(&url).await?),
            None => None,
        };
        let available = config.check(&manifest, signature.as_deref(), &platform()).map_err(|e| e.to_string())?;
        Ok(available.map(|available| (config, bytes, available)))
    }

    /// Downloads `available`, checks it, and unpacks it beside the app without touching the app.
    async fn stage(installation: Installation, available: &Available) -> Result<Staged, String> {
        let archive = get(&available.url).await?;
        let mut download =
            Download::new(available.sha256.as_deref().ok_or("The release has no checksum.")?, available.size);
        download.update(&archive).map_err(|e| e.to_string())?;
        download.finish().map_err(|e| e.to_string())?;
        let name = available.url.rsplit('/').next().unwrap_or("update.tar.gz").to_owned();
        let path: PathBuf = std::env::temp_dir().join(format!("listenook-update-{name}"));
        blocking(move || {
            std::fs::write(&path, archive).map_err(|e| e.to_string())?;
            let result = installation.stage(&path).map_err(|e| e.to_string());
            let _ = std::fs::remove_file(&path);
            result
        })
        .await
        .map_err(|e| e.to_string())?
    }

    fn busy(state: Signal<UpdateState>) -> bool {
        matches!(
            state.get_untracked(),
            UpdateState::Checking | UpdateState::Downloading(_) | UpdateState::Ready(_) | UpdateState::Installing
        )
    }

    /// Looks for a newer version and, when the app can replace itself, downloads it so that a
    /// restart applies it. Quiet, as the app checks on its own, it shows nothing until an update
    /// is ready, and a failure leaves the state as if it never ran.
    fn look(state: Signal<UpdateState>, quiet: bool) {
        if busy(state) {
            return;
        }
        let before = state.get_untracked();
        if !quiet {
            state.set(UpdateState::Checking);
        }
        store().run(async move {
            let failed = |message: String| {
                if quiet {
                    log::warn!("update check: {message}");
                    before.clone()
                } else {
                    UpdateState::Failed(message.into())
                }
            };
            let next = match find().await {
                Ok(None) => UpdateState::UpToDate,
                Ok(Some((config, bytes, available))) => {
                    let version: SharedString = available.version.clone().into();
                    match Installation::current(&config.id, &bytes).filter(Installation::can_install) {
                        Some(installation) => {
                            let _ = state.try_set(UpdateState::Downloading(version.clone()));
                            match stage(installation, &available).await {
                                Ok(staged) => {
                                    if let Ok(mut slot) = STAGED.lock() {
                                        *slot = Some(staged);
                                    }
                                    if quiet {
                                        toast_with_action(
                                            Tone::Info,
                                            format!("{} {version}", tr("An update is ready:")),
                                            tr("Restart to update"),
                                            move || install_and_restart(state),
                                        );
                                    }
                                    UpdateState::Ready(version)
                                }
                                Err(message) => failed(message),
                            }
                        }
                        None => {
                            let url: SharedString = available.url.into();
                            let told = matches!(&before, UpdateState::Manual(seen, _) if *seen == version);
                            if quiet && !told {
                                let page = url.clone();
                                toast_with_action(
                                    Tone::Info,
                                    format!("{} {version}", tr("A new version is available:")),
                                    tr("Open release page"),
                                    move || drop(open_url(page.to_string())),
                                );
                            }
                            UpdateState::Manual(version, url)
                        }
                    }
                }
                Err(message) if message.is_empty() => {
                    if quiet {
                        before.clone()
                    } else {
                        UpdateState::Unpackaged
                    }
                }
                Err(message) => failed(message),
            };
            let _ = state.try_set(next);
        });
    }

    /// Checks now, as the user asked to: every step shows.
    pub(crate) fn check(state: Signal<UpdateState>) {
        look(state, false);
    }

    /// Checks quietly a little after launch and then every few hours, for as long as the app runs.
    pub(crate) fn watch(state: Signal<UpdateState>) {
        store().run(async move {
            timer(FIRST_CHECK).await;
            loop {
                look(state, true);
                timer(CHECK_EVERY).await;
            }
        });
    }

    /// Puts the downloaded update in place and starts the new version.
    pub(crate) fn install_and_restart(state: Signal<UpdateState>) {
        if matches!(state.get_untracked(), UpdateState::Installing) {
            return;
        }
        state.set(UpdateState::Installing);
        store().run(async move {
            let staged = STAGED.lock().ok().and_then(|mut slot| slot.take());
            let result = match staged {
                Some(staged) => blocking(move || staged.finish().map_err(|e| e.to_string()))
                    .await
                    .map_err(|e| e.to_string())
                    .and_then(|finished| finished),
                None => Err(tr("The downloaded update is gone. Check for updates again.").to_string()),
            };
            match result {
                Ok(()) => desktop::restart(),
                Err(message) => drop(state.try_set(UpdateState::Failed(message.into()))),
            }
        });
    }

    /// As the app quits, puts a downloaded update in place, so the next start opens the new version.
    pub(crate) fn install_on_quit() {
        if let Some(staged) = STAGED.lock().ok().and_then(|mut slot| slot.take())
            && let Err(error) = staged.finish()
        {
            log::warn!("couldn't install the update on quit: {error}");
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "macos", windows))]
pub(crate) use desktop::{check, install_and_restart, install_on_quit, watch};

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub(crate) fn check(_: Signal<UpdateState>) {}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub(crate) fn watch(_: Signal<UpdateState>) {}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub(crate) fn install_and_restart(_: Signal<UpdateState>) {}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub(crate) fn install_on_quit() {}
