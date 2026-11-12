//! Syncing with another device, as the app's surface sees it: the devices
//! found, the sync this device started and how far it is, and the request
//! of another device waiting for an answer. The network side is
//! `services::sync`; what it brings is taken into the store here.

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

/// Where the sync this device started is.
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) enum Phase {
    /// Choosing a device.
    #[default]
    Choosing,
    /// Waiting for the other device's user to accept.
    Asking(Peer),
    /// Copying.
    Running(Peer),
    /// Done, with what was copied.
    Done(Peer, Summary),
    /// It did not finish: the error's code.
    Failed(&'static str),
}

/// How much a running sync has copied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Copied {
    pub(crate) items: u64,
    pub(crate) items_total: u64,
    pub(crate) bytes: u64,
    pub(crate) bytes_total: u64,
}

/// The sync part of the store.
#[derive(Clone, Copy)]
pub(crate) struct SyncState {
    /// Whether the Sync dialog is up.
    pub(crate) open: Signal<bool>,
    peers: Signal<Vec<Peer>>,
    phase: Signal<Phase>,
    copied: Signal<Copied>,
    /// Looking for the device at an address the user typed.
    connecting: Signal<bool>,
    /// Another device's request, waiting for this device's user.
    request: Signal<Option<(u64, Device)>>,
    progress: Stored<Option<Arc<Progress>>>,
    /// Where the other device's group and tag ids lead here.
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

    /// The devices found on the network.
    pub(crate) fn peers(&self) -> Vec<Peer> {
        self.peers.get()
    }

    /// Where the sync this device started is.
    pub(crate) fn phase(&self) -> Phase {
        self.phase.get()
    }

    /// How much the running sync has copied.
    pub(crate) fn copied(&self) -> Copied {
        self.copied.get()
    }

    /// Whether an address the user typed is being tried.
    pub(crate) fn connecting(&self) -> bool {
        self.connecting.get()
    }

    /// The request of another device waiting for an answer.
    pub(crate) fn request(&self) -> Option<(u64, Device)> {
        self.request.get()
    }

    /// Opens the Sync dialog and looks for devices. The first time, this
    /// device becomes visible to them: a sync needs both to be.
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

    /// Back to choosing a device, after a sync ended.
    pub(crate) fn again(&self) {
        self.phase.set(Phase::Choosing);
        service::search();
    }

    /// Looks for devices again.
    pub(crate) fn search(&self) {
        service::search();
    }

    /// Syncs with a device: asks it, and copies once its user accepts.
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
            // What it brought is in the Library before it is called done.
            state.take_in();
            state.progress.replace(None);
            let stopped = progress.stop.load(Ordering::Relaxed);
            state.phase.set(match outcome {
                Ok(Ok(summary)) => Phase::Done(peer, summary),
                _ if stopped => Phase::Choosing,
                Ok(Err(code)) => Phase::Failed(code),
                Err(_) => Phase::Failed("sync_failed"),
            });
        });
    }

    /// Syncs with the device at an address the user typed.
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

    /// Ends the sync this device started.
    pub(crate) fn cancel(&self) {
        let Some(progress) = self.progress.with(|progress| progress.clone()) else {
            return;
        };
        progress.stop.store(true, Ordering::Relaxed);
        // Still waiting for an answer: the question is taken back.
        if let Phase::Asking(peer) = self.phase.get_untracked() {
            service::withdraw(peer.address);
        }
    }

    /// Answers another device's request.
    pub(crate) fn answer(&self, accept: bool) {
        if let Some((serial, device)) = self.request.get_untracked() {
            service::answer(serial, accept.then(|| store().busy_ids()));
            self.request.set(None);
            if accept {
                toast(Tone::Info, format!("{} {}…", tr("Syncing with"), device.name));
            }
        }
    }

    fn take_in(&self) {
        let store = store();
        let (incoming, events) = service::take();
        for incoming in incoming {
            match incoming {
                Incoming::Catalog(catalog) => drop(self.map.replace(store.adopt_catalog(&catalog))),
                Incoming::Job(job) => self.map.with(|map| store.adopt_job(*job, map)),
                Incoming::Media { id, path } => store.adopt_media(&id, &path),
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
                Event::Served { name, received, sent, complete } => toast(
                    if complete { Tone::Success } else { Tone::Error },
                    if complete {
                        format!("{} {name}: {}", tr("Synced with"), counts(received, sent))
                    } else {
                        format!("{} {name} {}", tr("The sync with"), tr("did not finish. Sync again to complete it."))
                    },
                ),
            }
        }
    }

    /// Called a few times a second by the shell: takes in what syncs
    /// brought, and follows the one that is running.
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
            };
            if self.copied.get_untracked() != copied {
                self.copied.set(copied);
            }
        }
        if self.open.get_untracked() && matches!(self.phase.get_untracked(), Phase::Choosing) {
            let found = service::peers();
            if self.peers.with_untracked(|peers| *peers != found) {
                self.peers.set(found);
            }
            // Devices come and go: asked again every few seconds.
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

/// "3 received, 2 sent", in the interface language.
pub(crate) fn counts(received: u32, sent: u32) -> String {
    if received == 0 && sent == 0 {
        return tr("nothing to copy, the Libraries already match.").to_string();
    }
    format!("{received} {}, {sent} {}", tr("received"), tr("sent"))
}
