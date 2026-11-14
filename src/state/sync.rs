use std::{
    collections::HashMap,
    sync::{Arc, atomic::Ordering},
};

use listenook_core::sync::Device;
use nsh_core::prelude::*;

use super::{store, tr};
use crate::{
    services::sync::{self as service, Event, Incoming, Peer, Progress, Summary},
    ui::{Tone, toast},
};

#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) enum Phase {
    #[default]
    Choosing,
    Asking(Peer),
    Running(Peer),
    Serving(String),
    Done(String, Summary),
    Failed(&'static str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Copied {
    pub(crate) items: u64,
    pub(crate) items_total: u64,
    pub(crate) bytes: u64,
    pub(crate) bytes_total: u64,
    pub(crate) waiting: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct SyncState {
    pub(crate) open: Signal<bool>,
    peers: Signal<Vec<Peer>>,
    phase: Signal<Phase>,
    copied: Signal<Copied>,
    connecting: Signal<bool>,
    request: Signal<Option<(u64, Device)>>,
    progress: Stored<Option<Arc<Progress>>>,
    map: Stored<HashMap<String, String>>,
    ticks: Stored<u32>,
}

impl SyncState {
    pub(super) fn new() -> Self {
        Self {
            open: signal(false),
            peers: signal(Vec::new()),
            phase: signal(Phase::default()),
            copied: signal(Copied::default()),
            connecting: signal(false),
            request: signal(None),
            progress: stored(None),
            map: stored(HashMap::new()),
            ticks: stored(0),
        }
    }

    pub(crate) fn peers(&self) -> Vec<Peer> {
        self.peers.get()
    }

    pub(crate) fn phase(&self) -> Phase {
        self.phase.get()
    }

    pub(crate) fn copied(&self) -> Copied {
        self.copied.get()
    }

    pub(crate) fn connecting(&self) -> bool {
        self.connecting.get()
    }

    pub(crate) fn request(&self) -> Option<(u64, Device)> {
        self.request.get()
    }

    pub(crate) fn show(&self) {
        let store = store();
        if !store.sync_decided() {
            store.set_sync_visible(true);
        }
        if matches!(self.phase.get_untracked(), Phase::Done(..) | Phase::Failed(_)) {
            self.phase.set(Phase::Choosing);
        }
        self.open.set(true);
        self.peers.set(service::peers());
        service::search();
    }

    pub(crate) fn again(&self) {
        self.phase.set(Phase::Choosing);
        service::search();
    }

    pub(crate) fn search(&self) {
        service::search();
    }

    pub(crate) fn start(&self, peer: Peer) {
        if !matches!(self.phase.get_untracked(), Phase::Choosing) {
            return;
        }
        let state = *self;
        let store = store();
        let progress = Arc::new(Progress::default());
        self.progress.replace(Some(progress.clone()));
        batch(|| {
            self.copied.set(Copied::default());
            self.phase.set(Phase::Asking(peer.clone()));
        });
        let busy = store.busy_ids();
        store.run(async move {
            let address = peer.address;
            let work = progress.clone();
            let outcome = blocking(move || service::sync_with(address, busy, &work)).await;
            state.take_in();
            state.progress.replace(None);
            let stopped = progress.stop.load(Ordering::Relaxed);
            state.phase.set(match outcome {
                Ok(Ok(summary)) => Phase::Done(peer.device.name, summary),
                _ if stopped => Phase::Choosing,
                Ok(Err(code)) => Phase::Failed(code),
                Err(_) => Phase::Failed("sync_failed"),
            });
        });
    }

    pub(crate) fn connect(&self, address: String) {
        if self.connecting.get_untracked() || address.trim().is_empty() {
            return;
        }
        let state = *self;
        self.connecting.set(true);
        store().run(async move {
            let found = blocking(move || service::find_at(&address)).await.ok().flatten();
            state.connecting.set(false);
            match found {
                Some(peer) => state.start(peer),
                None => toast(
                    Tone::Error,
                    tr("No Listenook answered at that address. Open Sync on the other device and check the address."),
                ),
            }
        });
    }

    pub(crate) fn cancel(&self) {
        if matches!(self.phase.get_untracked(), Phase::Serving(_)) {
            service::stop_serving();
            self.phase.set(Phase::Choosing);
            return;
        }
        let Some(progress) = self.progress.with(|progress| progress.clone()) else {
            return;
        };
        progress.stop.store(true, Ordering::Relaxed);
        if let Phase::Asking(peer) = self.phase.get_untracked() {
            service::withdraw(peer.address);
        }
    }

    pub(crate) fn answer(&self, accept: bool) {
        if let Some((serial, device)) = self.request.get_untracked() {
            service::answer(serial, accept.then(|| store().busy_ids()));
            self.request.set(None);
            if accept && !matches!(self.phase.get_untracked(), Phase::Asking(_) | Phase::Running(_)) {
                batch(|| {
                    self.copied.set(Copied::default());
                    self.phase.set(Phase::Serving(device.name));
                    self.open.set(true);
                });
            }
        }
    }

    fn take_in(&self) {
        let store = store();
        let (incoming, events) = service::take();
        for incoming in incoming {
            match incoming {
                Incoming::Removed(removed) => store.adopt_removals(&removed),
                Incoming::Catalog(catalog) => drop(self.map.replace(store.adopt_catalog(&catalog))),
                Incoming::Job(job) => self.map.with(|map| store.adopt_job(*job, map)),
                Incoming::Media { id, path } => store.adopt_media(&id, &path),
                Incoming::Name { id, name } => store.adopt_name(&id, &name),
            }
        }
        for event in events {
            match event {
                Event::Asked { serial, device } => self.request.set(Some((serial, device))),
                Event::Withdrawn { serial } => {
                    if self
                        .request
                        .with_untracked(|request| request.as_ref().is_some_and(|(asked, _)| *asked == serial))
                    {
                        self.request.set(None);
                    }
                }
                Event::Served { name, received, sent, complete, lost } => {
                    let shown = matches!(self.phase.get_untracked(), Phase::Serving(_));
                    if shown {
                        self.phase.set(if complete {
                            Phase::Done(name.clone(), Summary { received, sent })
                        } else if lost {
                            Phase::Failed("sync_interrupted")
                        } else {
                            Phase::Failed("sync_cancelled_there")
                        });
                    }
                    if !(shown && self.open.get_untracked()) {
                        toast(
                            if complete { Tone::Success } else { Tone::Error },
                            if complete {
                                format!("{} {name}: {}", tr("Synced with"), counts(received, sent))
                            } else {
                                format!(
                                    "{} {name} {}",
                                    tr("The sync with"),
                                    tr("did not finish. Sync again to complete it.")
                                )
                            },
                        );
                    }
                }
            }
        }
    }

    pub(crate) fn tick(&self) {
        self.take_in();
        if let Some(progress) = self.progress.with(|progress| progress.clone()) {
            if progress.accepted.load(Ordering::Relaxed)
                && let Phase::Asking(peer) = self.phase.get_untracked()
            {
                self.phase.set(Phase::Running(peer));
            }
            let copied = Copied {
                items: progress.items.load(Ordering::Relaxed),
                items_total: progress.items_total.load(Ordering::Relaxed),
                bytes: progress.bytes.load(Ordering::Relaxed),
                bytes_total: progress.bytes_total.load(Ordering::Relaxed),
                waiting: progress.waiting.load(Ordering::Relaxed),
            };
            if self.copied.get_untracked() != copied {
                self.copied.set(copied);
            }
        }
        match (service::serving(), self.phase.get_untracked()) {
            (Some(serving), phase) => {
                if matches!(phase, Phase::Choosing | Phase::Done(..) | Phase::Failed(_)) {
                    self.phase.set(Phase::Serving(serving.name.clone()));
                }
                let copied = Copied {
                    items: serving.items,
                    items_total: serving.items_total,
                    bytes: serving.bytes,
                    bytes_total: serving.bytes_total,
                    waiting: false,
                };
                if self.copied.get_untracked() != copied {
                    self.copied.set(copied);
                }
            }
            (None, Phase::Serving(_)) => self.phase.set(Phase::Choosing),
            _ => {}
        }
        if self.open.get_untracked() && matches!(self.phase.get_untracked(), Phase::Choosing) {
            let found = service::peers();
            if self.peers.with_untracked(|peers| *peers != found) {
                self.peers.set(found);
            }
            let ticks = self.ticks.with(|ticks| {
                *ticks += 1;
                *ticks
            });
            if ticks.is_multiple_of(24) {
                service::search();
            }
        }
    }
}

pub(crate) fn counts(received: u32, sent: u32) -> String {
    if received == 0 && sent == 0 {
        return tr("nothing to copy, the Libraries already match.").to_string();
    }
    format!("{received} {}, {sent} {}", tr("received"), tr("sent"))
}
