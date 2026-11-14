use nsh_core::prelude::*;

pub(crate) const SELF_UPDATING: bool = cfg!(any(target_os = "linux", target_os = "macos", windows));

#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) enum UpdateState {
    #[default]
    Idle,
    Checking,
    UpToDate,
    Available(SharedString),
    Manual(SharedString, SharedString),
    Installing,
    Unpackaged,
    Failed(SharedString),
}

#[cfg(any(target_os = "linux", target_os = "macos", windows))]
mod desktop {
    use std::path::PathBuf;

    use nsh_core::{element::desktop, prelude::*};
    use nsh_updater::{Available, CONFIG_ASSET, Config, Download, install::Installation, platform};

    use super::UpdateState;

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

    async fn find() -> Result<Option<(Config, Vec<u8>, Available)>, String> {
        let Some((config, bytes)) = packaged() else {
            return Err(String::new());
        };
        let manifest = get(&config.manifest_url()).await?;
        let signature = match config.signature_url() {
            Some(url) => Some(get(&url).await?),
            None => None,
        };
        let available = config.check(&manifest, signature.as_deref(), &platform()).map_err(|e| e.to_string())?;
        Ok(available.map(|available| (config, bytes, available)))
    }

    pub(crate) fn check(state: Signal<UpdateState>) {
        state.set(UpdateState::Checking);
        crate::state::store().run(async move {
            state.try_set(match find().await {
                Ok(None) => UpdateState::UpToDate,
                Ok(Some((config, bytes, available))) => {
                    let installable = Installation::current(&config.id, &bytes).is_some_and(|i| i.can_install());
                    if installable {
                        UpdateState::Available(available.version.into())
                    } else {
                        UpdateState::Manual(available.version.into(), available.url.into())
                    }
                }
                Err(message) if message.is_empty() => UpdateState::Unpackaged,
                Err(message) => UpdateState::Failed(message.into()),
            });
        });
    }

    async fn install() -> Result<(), String> {
        let (config, bytes, available) = find().await?.ok_or("Already up to date.")?;
        let installation = Installation::current(&config.id, &bytes).ok_or("This app cannot replace itself.")?;
        let archive = get(&available.url).await?;
        let mut download =
            Download::new(available.sha256.as_deref().ok_or("The release has no checksum.")?, available.size);
        download.update(&archive).map_err(|e| e.to_string())?;
        download.finish().map_err(|e| e.to_string())?;
        let name = available.url.rsplit('/').next().unwrap_or("update.tar.gz").to_owned();
        let path: PathBuf = std::env::temp_dir().join(format!("listenook-update-{name}"));
        let target = path.clone();
        blocking(move || {
            std::fs::write(&target, archive).map_err(|e| e.to_string())?;
            let result = installation.install(&target).map_err(|e| e.to_string());
            let _ = std::fs::remove_file(&target);
            result
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(crate) fn install_and_restart(state: Signal<UpdateState>) {
        state.set(UpdateState::Installing);
        crate::state::store().run(async move {
            match install().await {
                Ok(()) => desktop::restart(),
                Err(message) => drop(state.try_set(UpdateState::Failed(message.into()))),
            }
        });
    }
}

#[cfg(any(target_os = "linux", target_os = "macos", windows))]
pub(crate) use desktop::{check, install_and_restart};

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub(crate) fn check(_: Signal<UpdateState>) {}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub(crate) fn install_and_restart(_: Signal<UpdateState>) {}
