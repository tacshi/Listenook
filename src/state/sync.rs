use std::{
    collections::HashMap,
    sync::{Arc, atomic::Ordering},
    time::{Duration, Instant},
};

use listenook_core::sync::Device;
use nsh_core::{element::Lifecycle, prelude::*};

use super::{persist, store, tr};
use crate::{
    platform,
    services::sync::{self as service, Event, Incoming, Mate, Peer, Progress, Summary},
    ui::{Tone, toast},
};

const EVERY: Duration = Duration::from_secs(15 * 60);
const EVERY_AWAY: Duration = Duration::from_secs(60 * 60);
const BACK_AFTER: Duration = Duration::from_secs(2 * 60);
const SETTLED_AFTER: Duration = Duration::from_secs(15);
const CHANGES_EVERY: Duration = Duration::from_secs(30);
const IDLE_WAIT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) enum Phase {
    #[default]
    Choosing,
    Asking(Peer),
    Pairing(Peer),
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Code {
    pub(crate) serial: u64,
    pub(crate) device: Device,
    pub(crate) code: String,
}

#[derive(Default)]
struct Schedule {
    last: Option<Instant>,
    last_change: Option<Instant>,
    synced: u64,
    seen: u64,
    changed_at: Option<Instant>,
    back: bool,
    away: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct SyncState {
    pub(crate) open: Signal<bool>,
    peers: Signal<Vec<Peer>>,
    mates: Signal<Vec<Mate>>,
    phase: Signal<Phase>,
    copied: Signal<Copied>,
    connecting: Signal<bool>,
    checking: Signal<bool>,
    wrong: Signal<bool>,
    rounding: Signal<bool>,
    code: Signal<Option<Code>>,
    progress: Stored<Option<Arc<Progress>>>,
    map: Stored<HashMap<String, String>>,
    ticks: Stored<u32>,
    schedule: Stored<Schedule>,
}

impl SyncState {
    pub(super) fn new() -> Self {
        Self {
            open: signal(false),
            peers: signal(Vec::new()),
            mates: signal(Vec::new()),
            phase: signal(Phase::default()),
            copied: signal(Copied::default()),
            connecting: signal(false),
            checking: signal(false),
            wrong: signal(false),
            rounding: signal(false),
            code: signal(None),
            progress: stored(None),
            map: stored(HashMap::new()),
            ticks: stored(0),
            schedule: stored(Schedule::default()),
        }
    }

    pub(crate) fn strangers(&self) -> Vec<Peer> {
        let mates = self.mates.get();
        self.peers.get().into_iter().filter(|peer| !mates.iter().any(|mate| mate.id == peer.device.id)).collect()
    }

    pub(crate) fn mates(&self) -> Vec<Mate> {
        self.mates.get()
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

    pub(crate) fn checking(&self) -> bool {
        self.checking.get()
    }

    pub(crate) fn wrong(&self) -> bool {
        self.wrong.get()
    }

    pub(crate) fn rounding(&self) -> bool {
        self.rounding.get()
    }

    pub(crate) fn code(&self) -> Option<Code> {
        self.code.get()
    }

    pub(crate) fn busy(&self) -> bool {
        self.open.get()
            || self.connecting.get()
            || self.rounding.get()
            || self.code.with(Option::is_some)
            || self.phase.with(|phase| {
                matches!(phase, Phase::Asking(_) | Phase::Pairing(_) | Phase::Running(_) | Phase::Serving(_))
            })
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
        self.mates.set(service::mates());
        service::search();
    }

    pub(crate) fn refresh(&self) {
        let mates = service::mates();
        if self.mates.with_untracked(|known| *known != mates) {
            self.mates.set(mates);
        }
    }

    pub(crate) fn again(&self) {
        self.phase.set(Phase::Choosing);
        service::search();
    }

    pub(crate) fn search(&self) {
        service::search();
    }

    pub(crate) fn start(&self, peer: Peer) {
        if service::is_mate(&peer.device.id) { self.sync(peer) } else { self.pair(peer) }
    }

    fn pair(&self, peer: Peer) {
        if !matches!(self.phase.get_untracked(), Phase::Choosing) {
            return;
        }
        let state = *self;
        batch(|| {
            self.wrong.set(false);
            self.phase.set(Phase::Asking(peer.clone()));
        });
        store().run(async move {
            let address = peer.address;
            let asked = blocking(move || service::pair(address)).await;
            if state.phase.get_untracked() != Phase::Asking(peer.clone()) {
                service::abandon();
                return;
            }
            state.phase.set(match asked {
                Ok(Ok(device)) => Phase::Pairing(Peer { device, address }),
                Ok(Err(code)) => Phase::Failed(code),
                Err(_) => Phase::Failed("sync_failed"),
            });
        });
    }

    pub(crate) fn enter(&self, code: String) {
        let Phase::Pairing(peer) = self.phase.get_untracked() else {
            return;
        };
        if self.checking.get_untracked() {
            return;
        }
        let state = *self;
        batch(|| {
            self.checking.set(true);
            self.wrong.set(false);
        });
        store().run(async move {
            let confirmed = blocking(move || service::confirm(&code)).await;
            state.checking.set(false);
            if state.phase.get_untracked() != Phase::Pairing(peer.clone()) {
                return;
            }
            match confirmed {
                Ok(Ok(())) => {
                    state.mates.set(service::mates());
                    state.phase.set(Phase::Choosing);
                    state.sync(peer);
                }
                Ok(Err("sync_wrong_code")) => state.wrong.set(true),
                Ok(Err(code)) => state.phase.set(Phase::Failed(code)),
                Err(_) => state.phase.set(Phase::Failed("sync_failed")),
            }
        });
    }

    fn sync(&self, peer: Peer) {
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
            let outcome = blocking(move || service::sync_with(address, busy, &work, false, true)).await;
            state.take_in();
            state.progress.replace(None);
            state.mates.set(service::mates());
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
        match self.phase.get_untracked() {
            Phase::Serving(_) => {
                service::stop_serving();
                self.phase.set(Phase::Choosing);
            }
            Phase::Pairing(_) => {
                service::abandon();
                self.phase.set(Phase::Choosing);
            }
            Phase::Asking(_) if self.progress.with(|progress| progress.is_none()) => self.phase.set(Phase::Choosing),
            _ => {
                if let Some(progress) = self.progress.with(|progress| progress.clone()) {
                    progress.stop.store(true, Ordering::Relaxed);
                }
            }
        }
    }

    pub(crate) fn dismiss_code(&self) {
        if let Some(code) = self.code.get_untracked() {
            service::dismiss(code.serial);
            self.code.set(None);
        }
    }

    pub(crate) fn remove(&self, id: &str) {
        service::remove(id);
        self.mates.set(service::mates());
    }

    pub(crate) fn leave(&self) {
        service::leave();
        self.mates.set(service::mates());
    }

    pub(crate) fn sync_now(&self) {
        self.round(true);
    }

    fn round(&self, force: bool) {
        if self.rounding.get_untracked() {
            return;
        }
        let state = *self;
        let store = store();
        self.schedule.with(|schedule| {
            schedule.last = Some(Instant::now());
            schedule.back = false;
        });
        self.rounding.set(true);
        let busy = store.busy_ids();
        store.run(async move {
            let synced = blocking(move || service::round(&busy, force)).await.unwrap_or(0);
            state.take_in();
            state.settle();
            state.rounding.set(false);
            state.mates.set(service::mates());
            if force
                && synced == 0
                && state.mates.with_untracked(|mates| mates.iter().all(|mate| mate.nearby.is_none()))
            {
                toast(Tone::Info, tr("None of your devices answered. Open Listenook on them, on this network."));
            }
        });
    }

    fn settle(&self) {
        let generation = persist::generation();
        self.schedule.with(|schedule| {
            schedule.synced = generation;
            schedule.seen = generation;
            schedule.changed_at = None;
        });
    }

    pub(crate) fn lifecycle(&self, now: Lifecycle) {
        let leaving = self.schedule.with(|schedule| {
            let away = now == Lifecycle::Background;
            let leaving = away && !schedule.away;
            if schedule.away && !away {
                schedule.back = true;
            }
            schedule.away = away;
            leaving
        });
        if leaving && self.free() {
            self.round(false);
        } else if now == Lifecycle::Active {
            self.consider();
        }
    }

    pub(crate) fn waiting(&self) -> (Duration, u64) {
        let now = Instant::now();
        self.schedule.with(|schedule| {
            let within = match schedule.changed_at.filter(|_| schedule.seen != schedule.synced) {
                Some(at) => {
                    let settled = SETTLED_AFTER.saturating_sub(now - at);
                    let spaced =
                        schedule.last_change.map_or(Duration::ZERO, |last| CHANGES_EVERY.saturating_sub(now - last));
                    settled.max(spaced).clamp(Duration::from_secs(1), IDLE_WAIT)
                }
                None => IDLE_WAIT,
            };
            (within, schedule.seen)
        })
    }

    fn free(&self) -> bool {
        let store = store();
        !self.rounding.get_untracked()
            && untracked(|| store.sync_visible())
            && self.mates.with_untracked(|mates| !mates.is_empty())
            && matches!(self.phase.get_untracked(), Phase::Choosing | Phase::Done(..) | Phase::Failed(_))
    }

    fn consider(&self) {
        let now = Instant::now();
        let generation = persist::generation();
        self.schedule.with(|schedule| {
            if generation != schedule.seen {
                schedule.seen = generation;
                schedule.changed_at = Some(now);
            }
        });
        if !self.free() {
            return;
        }
        let due = self.schedule.with(|schedule| {
            if schedule.away && platform::is_phone() {
                return false;
            }
            let Some(last) = schedule.last else {
                return true;
            };
            let since = now - last;
            let changed = generation != schedule.synced
                && schedule.changed_at.is_some_and(|at| now - at >= SETTLED_AFTER)
                && schedule.last_change.is_none_or(|at| now - at >= CHANGES_EVERY);
            if changed {
                schedule.last_change = Some(now);
            }
            since >= if schedule.away { EVERY_AWAY } else { EVERY } || (schedule.back && since >= BACK_AFTER) || changed
        });
        if due {
            self.round(false);
        }
    }

    fn take_in(&self) {
        let store = store();
        let (incoming, events) = service::take();
        for incoming in incoming {
            match incoming {
                Incoming::Removed(removed) => store.adopt_removals(&removed),
                Incoming::Catalog(catalog) => drop(self.map.replace(store.adopt_catalog(&catalog))),
                Incoming::Podcasts(podcasts) => store.podcast.adopt(&podcasts),
                Incoming::Job(job) => self.map.with(|map| store.adopt_job(*job, map)),
                Incoming::Media { id, path } => store.adopt_media(&id, &path),
                Incoming::Name { id, name } => store.adopt_name(&id, &name),
                Incoming::Shelves(shelves) => store.adopt_shelves(&shelves),
            }
        }
        for event in events {
            match event {
                Event::Pairing { serial, device, code } => self.code.set(Some(Code { serial, device, code })),
                Event::Paired { serial, name } => {
                    if self.code.with_untracked(|code| code.as_ref().is_some_and(|code| code.serial == serial)) {
                        self.code.set(None);
                    }
                    if let Some(name) = name {
                        self.mates.set(service::mates());
                        toast(Tone::Success, format!("{} {name}", tr("Paired with")));
                    }
                }
                Event::Circle => {
                    let mates = service::mates();
                    if self.mates.with_untracked(|known| *known != mates) {
                        self.mates.set(mates);
                    }
                }
                Event::Served { complete: true, auto: true, .. } => self.settle(),
                Event::Served { auto: true, .. } => {}
                Event::Served { name, received, sent, complete, lost, auto: false } => {
                    if complete {
                        self.settle();
                    }
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
        service::set_busy(store().busy_ids());
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
        match (service::serving().filter(|serving| !serving.auto), self.phase.get_untracked()) {
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
            let mates = service::mates();
            if self.mates.with_untracked(|known| *known != mates) {
                self.mates.set(mates);
            }
            let ticks = self.ticks.with(|ticks| {
                *ticks += 1;
                *ticks
            });
            if ticks.is_multiple_of(24) {
                service::search();
            }
        }
        self.consider();
    }
}

pub(crate) fn counts(received: u32, sent: u32) -> String {
    if received == 0 && sent == 0 {
        return tr("nothing to copy, the Libraries already match.").to_string();
    }
    format!("{received} {}, {sent} {}", tr("received"), tr("sent"))
}
