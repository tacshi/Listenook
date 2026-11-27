use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket},
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex, MutexGuard, OnceLock,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use listenook_core::{
    Job, LibraryCatalog, now_iso,
    sync::{
        Circle, Device, Entry, Index, Member, Members, Offer, PROTOCOL, Pake, Podcasts, Shelves, Transfer, digest, hex,
        is_code, is_sync_name, joins_answerer, media_extension, media_file_name, merge_members, pake_proof, plan_with,
        same,
    },
};
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};

use crate::services::persist;
use secure::{Identity, Wire};

mod exchange;
mod pairing;
pub(crate) mod secure;
#[cfg(test)]
mod tests;

use exchange::*;
pub(crate) use exchange::{round, sync_with};
use pairing::*;
pub(crate) use pairing::{abandon, confirm, pair};

pub(crate) const PORT: u16 = 47823;
const GROUP: Ipv4Addr = Ipv4Addr::new(239, 77, 76, 78);
const QUIET: Duration = Duration::from_secs(120);
const IDLE: Duration = Duration::from_secs(30);
const BROKEN: Duration = Duration::from_secs(8);
const RETRY_EVERY: Duration = Duration::from_secs(3);
const RETRY_FOR: Duration = Duration::from_secs(300);
const RESUME_WITHIN: Duration = Duration::from_secs(600);
const ANNOUNCE_WITHIN: Duration = Duration::from_millis(500);
const PEER_KEPT: Duration = Duration::from_secs(45);
const LISTEN_WAKES: Duration = Duration::from_secs(60);
const BIND_WITHIN: Duration = Duration::from_secs(6);
const REOPEN_AFTER: Duration = Duration::from_secs(1);
const PAIR_WITHIN: Duration = Duration::from_secs(180);
const PAIR_ATTEMPTS: u32 = 3;
const PAIR_COOLDOWN: Duration = Duration::from_secs(30);
const PAIR_FORGIVEN: Duration = Duration::from_secs(3600);
/// Connections answered at once; more wait for one to end.
const HANDLERS: usize = 32;
const REPLIES_WITHIN: Duration = Duration::from_millis(1500);
const MANIFEST_LIMIT: u64 = 256 * 1024 * 1024;
pub(crate) const LARGE_MEDIA: u64 = 500 * 1024 * 1024;

/// Which recordings over `LARGE_MEDIA` a sync copies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Large {
    /// None: the syncs that run on their own.
    Left,
    /// Those of a device on the same network. Over Tailscale, often a phone's data plan, they
    /// are left for a sync by hand on the same network, or for `All`.
    Nearby,
    /// All of them, over Tailscale too: the person asked for them.
    All,
}

impl Large {
    fn leaves(self, address: SocketAddr) -> bool {
        match self {
            Large::Left => true,
            Large::Nearby => is_tailscale(address.ip()),
            Large::All => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Peer {
    pub(crate) device: Device,
    pub(crate) address: SocketAddr,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Mate {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) platform: String,
    pub(crate) synced_at: Option<String>,
    pub(crate) nearby: Option<SocketAddr>,
}

#[derive(Debug)]
pub(crate) enum Incoming {
    Removed(listenook_core::sync::Removed),
    Catalog(LibraryCatalog),
    Podcasts(Box<Podcasts>),
    Job(Box<Job>),
    Media { id: String, path: PathBuf },
    Name { id: String, name: String },
    Shelves(Box<Shelves>),
    Activity(Box<listenook_core::activity::Activity>),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Event {
    Pairing { serial: u64, device: Device, code: String },
    Paired { serial: u64, name: Option<String> },
    Served { name: String, received: u32, sent: u32, complete: bool, lost: bool, auto: bool },
    Circle,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Serving {
    pub(crate) name: String,
    pub(crate) items: u64,
    pub(crate) items_total: u64,
    pub(crate) bytes: u64,
    pub(crate) bytes_total: u64,
    pub(crate) auto: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Summary {
    pub(crate) received: u32,
    pub(crate) sent: u32,
    /// Recordings whose media over `LARGE_MEDIA` was left because the sync went over Tailscale.
    pub(crate) left: u32,
}

#[derive(Debug, Default)]
pub(crate) struct Progress {
    pub(crate) accepted: AtomicBool,
    pub(crate) items: AtomicU64,
    pub(crate) items_total: AtomicU64,
    pub(crate) bytes: AtomicU64,
    pub(crate) bytes_total: AtomicU64,
    pub(crate) stop: AtomicBool,
    pub(crate) waiting: AtomicBool,
    /// The set-up of sync (`State::turn`) the sync started under.
    turn: AtomicU64,
}

impl Progress {
    /// Whether the sync is to stop: it was cancelled, or sync was set up again since it started
    /// (turned off and on, another library), and it is no longer this set-up's to finish.
    fn halted(&self) -> bool {
        self.stop.load(Ordering::Relaxed) || state().turn != self.turn.load(Ordering::Relaxed)
    }
}

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
struct Ledger {
    circle: Option<Circle>,
    seen: BTreeMap<String, Seen>,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
struct Seen {
    /// Where the device was last reached on a local network.
    address: String,
    /// Where it can be reached on Tailscale: the addresses it last gave, or where it was reached.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tailscale: Vec<String>,
    synced_at: String,
    mine: String,
    theirs: String,
}

impl Seen {
    /// Where the device can be reached, the local network first.
    fn places(&self) -> impl Iterator<Item = SocketAddr> + '_ {
        std::iter::once(&self.address).chain(&self.tailscale).filter_map(|place| place.parse().ok())
    }

    /// A round with the device ended now, each side's library at these revisions.
    fn synced(&mut self, (mine, theirs): (String, String)) {
        self.synced_at = now_iso();
        (self.mine, self.theirs) = (mine, theirs);
    }

    fn reached(&mut self, address: SocketAddr) {
        let place = address.to_string();
        if !is_tailscale(address.ip()) {
            self.address = place;
        } else if !self.tailscale.contains(&place) {
            self.tailscale.insert(0, place);
            self.tailscale.truncate(4);
        }
    }

    /// Keeps the Tailscale addresses `device` gave. None given, as when Tailscale is off there
    /// or it runs a version before them, keeps those known.
    fn learn(&mut self, device: &Device) -> bool {
        let given: Vec<String> = device
            .tailscale
            .iter()
            .filter(|ip| is_tailscale(**ip))
            .take(4)
            .map(|ip| SocketAddr::new(*ip, device.port).to_string())
            .collect();
        if given.is_empty() || given == self.tailscale {
            return false;
        }
        self.tailscale = given;
        true
    }
}

struct Pairing {
    serial: u64,
    device: Device,
    code: String,
    /// The fingerprint of the certificate the asking device showed.
    asker: String,
    offer: Option<Offer>,
    /// The key the code gave (SPAKE2), once the asker sent its side of it.
    key: Option<Vec<u8>>,
    attempts: u32,
    at: Instant,
}

#[derive(Clone)]
struct Asking {
    address: SocketAddr,
    device: Device,
    /// The fingerprint of the certificate the asked device showed.
    answerer: String,
}

struct Resumable {
    device: String,
    busy: HashSet<String>,
    at: Instant,
}

struct Session {
    token: String,
    /// The fingerprint of the certificate of the device syncing: the token is good only on its
    /// connections.
    peer: String,
    device: String,
    busy: HashSet<String>,
    name: String,
    auto: bool,
    address: String,
    mine: String,
    theirs: String,
    last: Instant,
    received: u32,
    sent: u32,
    calls: u32,
    broken: Option<Instant>,
    items: u64,
    items_total: u64,
    bytes: u64,
    bytes_total: u64,
}

impl Session {
    fn is_over(&self) -> bool {
        let quiet = self.last.elapsed();
        quiet > QUIET
            || (self.calls == 0 && quiet > IDLE)
            || (self.calls == 0 && self.broken.is_some_and(|at| at.elapsed() > BROKEN))
    }
}

#[derive(Clone)]
struct Library {
    root: PathBuf,
    generation: u64,
    index: Index,
    revision: String,
}

#[derive(Default)]
struct State {
    root: Option<PathBuf>,
    me: Device,
    visible: bool,
    turn: u64,
    peers: HashMap<String, (Peer, Instant)>,
    session: Option<Session>,
    resumable: Option<Resumable>,
    stopped: Option<String>,
    /// The sync this device started that is running, by its number; the next number.
    starting: Option<u64>,
    starts: u64,
    serial: u64,
    incoming: Vec<Incoming>,
    events: Vec<Event>,
    announcer: Option<UdpSocket>,
    serving_on: Option<u16>,
    ledger: Ledger,
    pairing: Option<Pairing>,
    asking: Option<Asking>,
    identity: Option<Arc<Identity>>,
    busy: HashSet<String>,
    library: Option<Library>,
    misses: Misses,
}

/// Wrong pairing codes, counted across pairings: asking again shows a new code but gives no new
/// guesses. Once `PAIR_ATTEMPTS` are wrong, pairing waits, longer after each further miss, up to
/// `PAIR_FORGIVEN`; an hour without a miss, or a pairing that succeeds, starts the count again.
#[derive(Default)]
struct Misses {
    count: u32,
    last: Option<Instant>,
}

impl Misses {
    fn miss(&mut self) {
        if self.last.is_some_and(|last| last.elapsed() >= PAIR_FORGIVEN) {
            self.count = 0;
        }
        self.count += 1;
        self.last = Some(Instant::now());
    }

    fn waiting(&self) -> bool {
        let Some(last) = self.last.filter(|_| self.count >= PAIR_ATTEMPTS) else {
            return false;
        };
        let wait = PAIR_COOLDOWN.saturating_mul(1 << (self.count - PAIR_ATTEMPTS).min(7)).min(PAIR_FORGIVEN);
        last.elapsed() < wait
    }
}

impl State {
    fn tell(&mut self, event: Event) {
        self.events.push(event);
        news().notify_all();
    }

    fn hand(&mut self, incoming: Incoming) {
        self.incoming.push(incoming);
        news().notify_all();
    }

    fn save(&mut self) {
        if let Some(root) = &self.root
            && let Ok(bytes) = serde_json::to_vec_pretty(&self.ledger)
            && let Err(error) = persist::write_atomic(&root.join("sync.json"), &bytes)
        {
            log::error!("sync: saving the paired devices: {error}");
        }
        self.tell(Event::Circle);
    }

    fn leave(&mut self) {
        self.ledger = Ledger::default();
        self.save();
    }

    fn saw(&mut self, id: &str, address: SocketAddr, revisions: Option<(String, String)>) {
        let seen = self.ledger.seen.entry(id.to_owned()).or_default();
        seen.reached(address);
        if let Some(revisions) = revisions {
            seen.synced(revisions);
        }
        self.save();
    }

    /// Where the paired device `id` may be: where it was seen last, then where it was reached
    /// before, the local network ahead of Tailscale.
    fn places(&self, id: &str) -> Vec<SocketAddr> {
        let mut places: Vec<SocketAddr> = self.peers.get(id).map(|(peer, _)| peer.address).into_iter().collect();
        for place in self.ledger.seen.get(id).into_iter().flat_map(Seen::places) {
            if !places.contains(&place) {
                places.push(place);
            }
        }
        places.sort_by_key(|place| is_tailscale(place.ip()));
        places
    }

    fn adopt(&mut self, circle: Circle) {
        self.ledger.seen.retain(|id, _| circle.members.contains_key(id));
        self.ledger.circle = Some(circle);
    }
}

fn state() -> MutexGuard<'static, State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE
        .get_or_init(|| {
            // What the library writes is news to a round waiting for something to send.
            persist::when_changed(poke);
            Mutex::default()
        })
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn news() -> &'static Condvar {
    static NEWS: OnceLock<Condvar> = OnceLock::new();
    NEWS.get_or_init(Condvar::new)
}

fn port() -> u16 {
    std::env::var("LISTENOOK_SYNC_PORT").ok().and_then(|port| port.parse().ok()).unwrap_or(PORT)
}

fn random_hex(length: usize) -> String {
    let mut bytes = vec![0_u8; length];
    SystemRandom::new().fill(&mut bytes).expect("the system gives random numbers");
    hex(&bytes)
}

fn new_code() -> String {
    let mut bytes = [0_u8; 4];
    SystemRandom::new().fill(&mut bytes).expect("the system gives random numbers");
    format!("{:06}", u32::from_be_bytes(bytes) % 1_000_000)
}

fn new_circle() -> Circle {
    Circle { id: random_hex(8), members: Members::new() }
}

/// Adds the two devices that paired, each with the fingerprint of its certificate.
fn join(circle: &mut Circle, devices: [(&Device, &str); 2]) {
    let at = now_iso();
    for (device, key) in devices {
        let member = Member {
            name: device.name.clone(),
            platform: device.platform.clone(),
            joined_at: at.clone(),
            removed_at: None,
            key: key.to_owned(),
        };
        circle.members.insert(device.id.clone(), member);
    }
}

fn identity() -> Result<Arc<Identity>, &'static str> {
    state().identity.clone().ok_or("sync_failed")
}

/// The fingerprint of the certificate of the paired device `id`.
fn key_of(id: &str) -> Result<String, &'static str> {
    let state = state();
    let circle = state.ledger.circle.as_ref().ok_or("sync_unpaired")?;
    circle
        .members
        .get(id)
        .filter(|member| member.is_in() && !member.key.is_empty())
        .map(|m| m.key.clone())
        .ok_or("sync_unpaired")
}

pub(crate) fn default_name() -> String {
    let run = |program: &str, arguments: &[&str]| {
        std::process::Command::new(program)
            .args(arguments)
            .output()
            .ok()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
            .filter(|name| !name.is_empty())
    };
    let named = if cfg!(target_os = "macos") {
        run("scutil", &["--get", "ComputerName"])
    } else if cfg!(target_os = "windows") {
        std::env::var("COMPUTERNAME").ok().filter(|name| !name.is_empty())
    } else if cfg!(target_os = "linux") {
        run("hostname", &[])
    } else {
        None
    };
    named.unwrap_or_else(|| {
        if cfg!(target_os = "ios") {
            "iPhone / iPad"
        } else if cfg!(target_os = "android") {
            "Android"
        } else {
            "Listenook"
        }
        .to_owned()
    })
}

pub(crate) fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "ios") {
        "ios"
    } else if cfg!(target_os = "android") {
        "android"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "linux"
    }
}

fn load_ledger(root: &Path) -> Ledger {
    persist::read_json(&root.join("sync.json")).unwrap_or_default()
}

pub(crate) fn configure(root: Option<PathBuf>, id: String, name: String, visible: bool) {
    let mut state = state();
    let visible = visible && root.is_some();
    let changed = state.visible != visible || state.root != root;
    if state.root != root {
        state.ledger = root.as_deref().map(load_ledger).unwrap_or_default();
        state.library = None;
        state.identity = root
            .as_deref()
            .and_then(|root| Identity::of(root).map_err(|error| log::error!("sync: this device's key: {error}")).ok());
        // Devices paired before sync ran over TLS are known by no certificate: they pair again.
        if state.ledger.circle.as_ref().is_some_and(|circle| !circle.is_keyed()) {
            state.ledger = Ledger::default();
        }
    }
    state.root = root;
    state.me = Device {
        app: "listenook".into(),
        protocol: PROTOCOL,
        id,
        name,
        platform: platform().into(),
        port: port(),
        revision: String::new(),
        tailscale: Vec::new(),
    };
    let me = state.me.clone();
    let renamed = state
        .ledger
        .circle
        .as_mut()
        .and_then(|circle| circle.members.get_mut(&me.id))
        .filter(|member| member.name != me.name)
        .map(|member| member.name = me.name.clone())
        .is_some();
    if renamed {
        state.save();
    }
    if !changed {
        return;
    }
    let was_visible = state.visible;
    let serving_on = state.serving_on.take();
    state.visible = visible;
    state.turn += 1;
    state.announcer = None;
    state.pairing = None;
    state.asking = None;
    state.session = None;
    state.starting = None;
    // Devices seen are found again by the next set-up's own listening: kept,
    // one that answered for another library could be synced with here.
    state.peers.clear();
    let turn = state.turn;
    drop(state);
    if was_visible {
        thread::spawn(move || wake(serving_on));
    }
    if visible {
        thread::spawn(move || serve(turn));
        thread::spawn(move || serve_v6(turn));
        thread::spawn(move || listen(turn));
    }
}

pub(crate) fn release(root: &Option<PathBuf>) {
    if state().root == *root {
        configure(None, String::new(), String::new(), false);
    }
}

pub(crate) fn set_busy(busy: HashSet<String>) {
    state().busy = busy;
}

pub(crate) fn peers() -> Vec<Peer> {
    let mut state = state();
    state.peers.retain(|_, (_, seen)| seen.elapsed() < PEER_KEPT);
    let mut peers: Vec<Peer> = state.peers.values().map(|(peer, _)| peer.clone()).collect();
    peers.sort_by(|a, b| {
        (a.device.name.to_lowercase(), &a.device.id).cmp(&(b.device.name.to_lowercase(), &b.device.id))
    });
    peers
}

pub(crate) fn mates() -> Vec<Mate> {
    let state = state();
    let Some(circle) = &state.ledger.circle else {
        return Vec::new();
    };
    let mut mates: Vec<Mate> = circle
        .members
        .iter()
        .filter(|(id, member)| member.is_in() && **id != state.me.id)
        .map(|(id, member)| Mate {
            id: id.clone(),
            name: member.name.clone(),
            platform: member.platform.clone(),
            synced_at: state.ledger.seen.get(id).map(|seen| seen.synced_at.clone()).filter(|at| !at.is_empty()),
            nearby: state.peers.get(id).filter(|(_, seen)| seen.elapsed() < PEER_KEPT).map(|(peer, _)| peer.address),
        })
        .collect();
    mates.sort_by(|a, b| (a.name.to_lowercase(), &a.id).cmp(&(b.name.to_lowercase(), &b.id)));
    mates
}

pub(crate) fn is_mate(id: &str) -> bool {
    let state = state();
    id != state.me.id && state.ledger.circle.as_ref().is_some_and(|circle| circle.has(id))
}

pub(crate) fn remove(id: &str) {
    let mut state = state();
    let Some(member) = state.ledger.circle.as_mut().and_then(|circle| circle.members.get_mut(id)) else {
        return;
    };
    member.remove();
    // No device counts as in step now: who is in the circle travels only in an exchange, and
    // the others are to hear of this at the next one, not at the next change to the library.
    state.ledger.seen.clear();
    state.save();
}

pub(crate) fn leave() {
    let (identity, places) = {
        let mut state = state();
        let Some(circle) = state.ledger.circle.clone() else {
            return;
        };
        let places: Vec<(Vec<SocketAddr>, String)> = circle
            .members
            .iter()
            .filter(|(id, member)| **id != state.me.id && !member.key.is_empty())
            .map(|(id, member)| (state.places(id), member.key.clone()))
            .filter(|(places, _)| !places.is_empty())
            .collect();
        let identity = state.identity.clone();
        state.leave();
        (identity, places)
    };
    let Some(identity) = identity else {
        return;
    };
    for (addresses, key) in places {
        let identity = identity.clone();
        thread::spawn(move || {
            let agent = identity.agent(Some(&key), None, Duration::from_secs(3));
            for address in addresses {
                let told = agent.post(&format!("https://{address}/listenook/leave")).send_bytes(b"{}");
                if !matches!(told, Err(ureq::Error::Transport(_))) {
                    break;
                }
            }
        });
    }
}

pub(crate) fn wait(within: Duration, seen: u64) {
    let state = state();
    if state.incoming.is_empty() && state.events.is_empty() && persist::generation() == seen {
        drop(news().wait_timeout(state, within));
    }
}

pub(crate) fn poke() {
    drop(state());
    news().notify_all();
}

pub(crate) fn take() -> (Vec<Incoming>, Vec<Event>) {
    let mut state = state();
    if state.session.as_ref().is_some_and(Session::is_over) {
        end_session(&mut state, false, true);
    }
    if let Some(pairing) = state.pairing.take_if(|pairing| pairing.at.elapsed() > PAIR_WITHIN) {
        state.tell(Event::Paired { serial: pairing.serial, name: None });
    }
    (std::mem::take(&mut state.incoming), std::mem::take(&mut state.events))
}

pub(crate) fn serving() -> Option<Serving> {
    state().session.as_ref().map(|session| Serving {
        name: session.name.clone(),
        items: session.items,
        items_total: session.items_total,
        bytes: session.bytes,
        bytes_total: session.bytes_total,
        auto: session.auto,
    })
}

pub(crate) fn stop_serving() {
    let mut state = state();
    state.stopped = state.session.take().map(|session| session.token);
    state.resumable = None;
}

pub(crate) fn dismiss(serial: u64) {
    let mut state = state();
    if state.pairing.as_ref().is_some_and(|pairing| pairing.serial == serial) {
        state.pairing = None;
    }
}

fn end_session(state: &mut State, complete: bool, lost: bool) {
    let Some(session) = state.session.take() else {
        return;
    };
    state.resumable =
        lost.then(|| Resumable { device: session.device.clone(), busy: session.busy, at: Instant::now() });
    if complete && let Ok(address) = session.address.parse() {
        state.saw(&session.device, address, Some((session.mine, session.theirs)));
    }
    state.tell(Event::Served {
        name: session.name,
        received: session.received,
        sent: session.sent,
        complete,
        lost,
        auto: session.auto,
    });
}

fn remember(device: Device, address: SocketAddr) {
    let mut state = state();
    if !device.is_compatible() || device.id == state.me.id {
        return;
    }
    state.peers.insert(device.id.clone(), (Peer { device, address }, Instant::now()));
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Announcement {
    device: Device,
    asking: bool,
}

fn wake(serving_on: Option<u16>) {
    if let Some(port) = serving_on {
        for host in [IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)] {
            let _ = TcpStream::connect_timeout(&SocketAddr::new(host, port), Duration::from_millis(500));
        }
    }
    if let Ok(socket) = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)) {
        let _ = socket.send_to(&[], (Ipv4Addr::LOCALHOST, PORT));
    }
}

fn bind_for<T>(turn: u64, what: &str, bind: impl Fn() -> io::Result<T>) -> Option<T> {
    let started = Instant::now();
    loop {
        if state().turn != turn {
            return None;
        }
        match bind() {
            Ok(bound) => return Some(bound),
            Err(error) if started.elapsed() > BIND_WITHIN => {
                log::warn!("sync: {what} is not free: {error}");
                return None;
            }
            Err(_) => thread::sleep(Duration::from_millis(100)),
        }
    }
}

fn listen(turn: u64) {
    while let Some(socket) = bind_for(turn, "the discovery port", || UdpSocket::bind((Ipv4Addr::UNSPECIFIED, PORT))) {
        let _ = socket.join_multicast_v4(&GROUP, &Ipv4Addr::UNSPECIFIED);
        let _ = socket.set_read_timeout(Some(LISTEN_WAKES));
        let _ = socket.set_write_timeout(Some(ANNOUNCE_WITHIN));
        if let Ok(announcer) = socket.try_clone() {
            state().announcer = Some(announcer);
        }
        announce(true);
        let Err(error) = hear(turn, &socket) else {
            return;
        };
        log::debug!("sync: the discovery port stopped working, opening it again: {error}");
        drop(socket);
        thread::sleep(REOPEN_AFTER);
    }
}

fn hear(turn: u64, socket: &UdpSocket) -> io::Result<()> {
    let mut buffer = [0_u8; 2048];
    loop {
        let me = {
            let state = state();
            if state.turn != turn {
                return Ok(());
            }
            state.me.clone()
        };
        let (length, from) = match socket.recv_from(&mut buffer) {
            Ok(received) => received,
            Err(error) if waited(&error) => continue,
            Err(error) => return Err(error),
        };
        let Ok(heard) = serde_json::from_slice::<Announcement>(&buffer[..length]) else {
            continue;
        };
        if heard.device.id == me.id || !heard.device.is_compatible() {
            continue;
        }
        let asked = heard.asking;
        remember(heard.device.clone(), SocketAddr::new(from.ip(), heard.device.port));
        if asked && let Ok(reply) = serde_json::to_vec(&Announcement { device: me, asking: false }) {
            let _ = socket.send_to(&reply, from);
        }
    }
}

fn waited(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted)
}

fn announce(asking: bool) {
    let (socket, me) = {
        let state = state();
        (state.announcer.as_ref().and_then(|socket| socket.try_clone().ok()), state.me.clone())
    };
    if let Some(socket) = socket
        && let Ok(message) = serde_json::to_vec(&Announcement { device: me, asking })
    {
        let _ = socket.send_to(&message, (GROUP, PORT));
    }
}

fn local_address() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect((Ipv4Addr::new(10, 254, 254, 254), 9)).ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(address) if address.is_private() => Some(address),
        _ => None,
    }
}

fn ask_within(address: SocketAddr, within: Duration) -> Option<Device> {
    let response = identity()
        .ok()?
        .builder(None, None)
        .timeout_connect(within)
        .timeout_read(Duration::from_secs(10))
        .build()
        .get(&format!("https://{address}/listenook/info"))
        .call()
        .ok()?;
    let device: Device = serde_json::from_reader(response.into_reader().take(64 * 1024)).ok()?;
    device.is_compatible().then_some(device)
}

fn ask(address: SocketAddr) -> Option<Device> {
    ask_within(address, Duration::from_secs(4))
}

pub(crate) fn search() {
    static SEARCHING: AtomicBool = AtomicBool::new(false);
    static ANNOUNCING: AtomicBool = AtomicBool::new(false);
    if !ANNOUNCING.swap(true, Ordering::SeqCst) {
        thread::spawn(|| {
            announce(true);
            ANNOUNCING.store(false, Ordering::SeqCst);
        });
    }
    if SEARCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    thread::spawn(|| {
        let mine = local_address();
        log::debug!("sync: looking for devices from {mine:?}");
        if let Some(mine) = mine {
            let [a, b, c, _] = mine.octets();
            let port = PORT;
            let probes: Vec<_> = (1..255_u8)
                .map(|host| SocketAddr::from((Ipv4Addr::new(a, b, c, host), port)))
                .filter(|address| !(address.ip() == IpAddr::V4(mine) && self::port() == port))
                .filter_map(|address| {
                    thread::Builder::new()
                        .stack_size(256 * 1024)
                        .spawn(move || match TcpStream::connect_timeout(&address, Duration::from_millis(700)) {
                            Ok(_) => match ask(address) {
                                Some(device) => {
                                    log::debug!("sync: found {} at {address}", device.name);
                                    remember(device, address);
                                }
                                None => log::debug!("sync: {address} is open but is not Listenook"),
                            },
                            Err(error) if address.ip() == IpAddr::V4(mine) => {
                                log::debug!("sync: {address}: {error}")
                            }
                            Err(_) => {}
                        })
                        .ok()
                })
                .collect();
            for probe in probes {
                let _ = probe.join();
            }
        }
        SEARCHING.store(false, Ordering::SeqCst);
    });
}

pub(crate) fn find_at(text: &str) -> Option<Peer> {
    places_at(text).into_iter().find_map(|address| {
        let device = ask(address)?;
        remember(device.clone(), address);
        Some(Peer { device, address })
    })
}

/// The places `text` names, IPv4 first: an IP address, or a name, MagicDNS names on Tailscale
/// among them; with a port or without.
fn places_at(text: &str) -> Vec<SocketAddr> {
    let text = text.trim().trim_start_matches("http://").trim_start_matches("https://").trim_end_matches('/');
    let mut places: Vec<SocketAddr> = if let Ok(ip) = text.trim_start_matches('[').trim_end_matches(']').parse() {
        vec![SocketAddr::new(ip, PORT)]
    } else if let Ok(address) = text.parse() {
        vec![address]
    } else if text.rsplit_once(':').is_some_and(|(_, port)| port.parse::<u16>().is_ok()) {
        text.to_socket_addrs().map(Iterator::collect).unwrap_or_default()
    } else {
        (text, PORT).to_socket_addrs().map(Iterator::collect).unwrap_or_default()
    };
    places.sort_by_key(SocketAddr::is_ipv6);
    places.dedup();
    places
}

/// Whether `ip` is in the ranges Tailscale gives its devices addresses from: 100.64.0.0/10,
/// which carriers use too, and fd7a:115c:a1e0::/48.
pub(crate) fn is_tailscale(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => is_shared(v4),
        IpAddr::V6(v6) => v6.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

/// 100.64.0.0/10, shared by carriers and Tailscale.
fn is_shared(v4: Ipv4Addr) -> bool {
    let [first, second, ..] = v4.octets();
    first == 100 && second & 0xc0 == 64
}

/// This device's addresses on Tailscale, IPv4 first.
fn tailscale_addresses() -> Vec<IpAddr> {
    let interfaces = if_addrs::get_if_addrs().unwrap_or_default();
    tailscale_of(interfaces.into_iter().filter(|interface| !interface.is_loopback()).map(|i| (i.name.clone(), i.ip())))
}

/// The Tailscale addresses among `interfaces`, by name and address. A carrier's address in
/// 100.64.0.0/10 is told from Tailscale's by its interface: Tailscale's has an address in
/// Tailscale's IPv6 range too, unless IPv6 is turned off in the tailnet.
fn tailscale_of(interfaces: impl Iterator<Item = (String, IpAddr)>) -> Vec<IpAddr> {
    let interfaces: Vec<(String, IpAddr)> = interfaces.collect();
    let tunnels: HashSet<&str> =
        interfaces.iter().filter(|(_, ip)| ip.is_ipv6() && is_tailscale(*ip)).map(|(name, _)| name.as_str()).collect();
    let mut addresses: Vec<IpAddr> = interfaces
        .iter()
        .filter(|(name, ip)| {
            is_tailscale(*ip) && (ip.is_ipv6() || tunnels.is_empty() || tunnels.contains(name.as_str()))
        })
        .map(|(_, ip)| *ip)
        .collect();
    addresses.sort_by_key(IpAddr::is_ipv6);
    addresses.dedup();
    addresses
}

/// Whether this device is on Tailscale, with an IPv4 address there.
fn on_tailscale() -> bool {
    tailscale_addresses().iter().any(IpAddr::is_ipv4)
}

/// This device as it tells of itself to the devices it calls or that call it, with its
/// Tailscale addresses as they are now.
fn told(me: Device) -> Device {
    Device { tailscale: tailscale_addresses(), ..me }
}

/// Whether a call from `address` is answered: from this device's own network, or from
/// Tailscale. Carriers give out addresses in Tailscale's 100.64.0.0/10 too, so a call from there
/// is answered only while this device is on Tailscale itself (`on_tailscale`, asked only then).
/// Either way, a device has to pair with the code shown here, or show a paired device's
/// certificate, before it gets anything.
fn is_local(address: IpAddr, on_tailscale: impl FnOnce() -> bool) -> bool {
    match address.to_canonical() {
        IpAddr::V4(v4) if is_shared(v4) => on_tailscale(),
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00 || (v6.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

fn serve(turn: u64) {
    let what = format!("port {}", port());
    while let Some(listener) = bind_for(turn, &what, || TcpListener::bind((Ipv4Addr::UNSPECIFIED, port()))) {
        {
            let mut state = state();
            if state.turn != turn {
                return;
            }
            state.serving_on = listener.local_addr().ok().map(|address| address.port());
        }
        let Err(error) = accept_from(turn, &listener) else {
            return;
        };
        log::debug!("sync: {what} stopped working, opening it again: {error}");
        drop(listener);
        thread::sleep(REOPEN_AFTER);
    }
}

/// Answers calls to this device's IPv6 addresses, Tailscale's among them, on a port of their
/// own beside the IPv4 one. A device without IPv6 goes without.
fn serve_v6(turn: u64) {
    let what = format!("IPv6 port {}", port());
    while let Some(listener) = bind_for(turn, &what, || listen_v6(port())) {
        if state().turn != turn {
            return;
        }
        let Err(error) = accept_from(turn, &listener) else {
            return;
        };
        log::debug!("sync: {what} stopped working, opening it again: {error}");
        drop(listener);
        thread::sleep(REOPEN_AFTER);
    }
}

/// A listener on IPv6 alone, which leaves IPv4 to `serve`'s on every system.
fn listen_v6(port: u16) -> io::Result<TcpListener> {
    let socket = socket2::Socket::new(socket2::Domain::IPV6, socket2::Type::STREAM, Some(socket2::Protocol::TCP))?;
    socket.set_only_v6(true)?;
    // As std does for its own listeners: a port just closed can be opened again at once.
    if cfg!(unix) {
        socket.set_reuse_address(true)?;
    }
    socket.bind(&SocketAddr::from((Ipv6Addr::UNSPECIFIED, port)).into())?;
    socket.listen(128)?;
    Ok(socket.into())
}

fn accept_from(turn: u64, listener: &TcpListener) -> io::Result<()> {
    loop {
        if state().turn != turn {
            return Ok(());
        }
        let (stream, from) = match listener.accept() {
            Ok(accepted) => accepted,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if state().turn != turn {
            return Ok(());
        }
        static ANSWERING: AtomicUsize = AtomicUsize::new(0);
        struct Slot(&'static AtomicUsize);
        impl Drop for Slot {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let local = is_local(from.ip(), on_tailscale);
        if local && ANSWERING.fetch_add(1, Ordering::SeqCst) < HANDLERS {
            let slot = Slot(&ANSWERING);
            if let Err(error) = thread::Builder::new().spawn(move || {
                let _slot = slot;
                if let Err(error) = handle(stream, from.ip()) {
                    log::debug!("sync: {error}");
                }
            }) {
                log::warn!("sync: could not start handler thread: {error}");
            }
        } else if local {
            ANSWERING.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

struct Call {
    method: String,
    path: String,
    length: u64,
    token: String,
    progress: Option<(u64, u64, u64)>,
    offset: u64,
    from: IpAddr,
    /// The fingerprint of the certificate the caller showed.
    peer: String,
    body: BufReader<Wire>,
}

impl Call {
    /// Where the answer goes, once what the call sent was read.
    fn out(&mut self) -> &mut Wire {
        self.body.get_mut()
    }
}

fn read_call(wire: Wire, from: IpAddr, peer: String) -> io::Result<Call> {
    let mut body = BufReader::new(wire);
    let (mut method, mut path, mut length, mut token) = (String::new(), String::new(), 0, String::new());
    let (mut progress, mut offset) = (None, 0);
    let mut head = (&mut body).take(16 * 1024);
    let mut line = String::new();
    loop {
        line.clear();
        if head.read_line(&mut line)? == 0 {
            return Err(io::Error::other("the request ended early"));
        }
        let text = line.trim_end();
        if method.is_empty() {
            let mut parts = text.split(' ');
            method = parts.next().unwrap_or("").to_owned();
            path = parts.next().unwrap_or("").to_owned();
            if method.is_empty() || path.is_empty() {
                return Err(io::Error::other("not a request"));
            }
        } else if text.is_empty() {
            break;
        } else if let Some((name, value)) = text.split_once(':') {
            match name.to_ascii_lowercase().as_str() {
                "content-length" => length = value.trim().parse().map_err(io::Error::other)?,
                "x-listenook-token" => token = value.trim().to_owned(),
                "x-listenook-offset" => offset = value.trim().parse().unwrap_or(0),
                "x-listenook-progress" => {
                    let mut numbers = value.split_whitespace().map(|number| number.parse::<u64>().ok());
                    if let (Some(Some(items)), Some(Some(items_total)), Some(Some(bytes_total))) =
                        (numbers.next(), numbers.next(), numbers.next())
                    {
                        progress = Some((items, items_total, bytes_total));
                    }
                }
                _ => {}
            }
        }
    }
    Ok(Call { method, path, length, token, progress, offset, from, peer, body })
}

fn reply(stream: &mut impl Write, status: u16, body: &[u8]) -> io::Result<()> {
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        410 => "Gone",
        426 => "Upgrade Required",
        429 => "Too Many Requests",
        _ => "Bad Request",
    };
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)?;
    stream.flush()
}

fn reply_json(stream: &mut impl Write, value: &impl Serialize) -> io::Result<()> {
    reply(stream, 200, &serde_json::to_vec(value).map_err(io::Error::other)?)
}

fn refuse(stream: &mut impl Write, reason: &str) -> io::Result<()> {
    reply(stream, 403, &serde_json::to_vec(&Refusal { reason: reason.to_owned() }).map_err(io::Error::other)?)
}

fn in_session(token: &str, count: impl FnOnce(&mut Session)) -> bool {
    let mut state = state();
    match state.session.as_mut().filter(|session| !token.is_empty() && session.token == token) {
        Some(session) => {
            session.last = Instant::now();
            count(session);
            true
        }
        None => false,
    }
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Hello {
    device: Device,
    catalog: LibraryCatalog,
    resume: bool,
    auto: bool,
    revision: String,
    members: Members,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    names: HashMap<String, String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    removed: listenook_core::sync::Removed,
    podcasts: Podcasts,
    shelves: Shelves,
    #[serde(skip_serializing_if = "listenook_core::activity::Activity::is_empty")]
    activity: listenook_core::activity::Activity,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Part {
    size: u64,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Welcome {
    token: String,
    device: Device,
    index: Index,
    revision: String,
    members: Members,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Done {
    complete: bool,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Refusal {
    reason: String,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairAsk {
    device: Device,
    circle: Option<Offer>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairAnswer {
    device: Device,
    circle: Option<Offer>,
}

/// A side of the code's key exchange (SPAKE2).
#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairKey {
    id: String,
    message: String,
}

/// The devices of a circle, as pairing shares them.
#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Shared {
    id: String,
    members: Members,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairFinish {
    id: String,
    proof: String,
    circle: Option<Shared>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairDone {
    proof: String,
    circle: Shared,
}

fn read_body(call: &mut Call, limit: u64) -> io::Result<Vec<u8>> {
    if call.length > limit {
        return Err(io::Error::other("the body is too large"));
    }
    // Grown as bytes arrive, not sized from the length the caller declared: a stated length
    // costs nothing until the bytes are really sent.
    let mut bytes = Vec::with_capacity(call.length.min(64 * 1024) as usize);
    (&mut call.body).take(call.length).read_to_end(&mut bytes)?;
    if (bytes.len() as u64) < call.length {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(bytes)
}

fn handle(stream: TcpStream, from: IpAddr) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    let identity = state().identity.clone().ok_or_else(|| io::Error::other("this device has no key"))?;
    let (wire, peer) = identity.accept(stream)?;
    let mut call = read_call(wire, from, peer.clone()).inspect_err(|_| lost(&peer))?;
    // A token is good only on connections of the device it was given to.
    if state().session.as_ref().is_some_and(|session| session.token == call.token && session.peer != call.peer) {
        call.token.clear();
    }
    let token = call.token.clone();
    let progress = call.progress;
    let counted = in_session(&token, |session| {
        session.calls += 1;
        if let Some((items, items_total, bytes_total)) = progress {
            (session.items, session.items_total, session.bytes_total) = (items, items_total, bytes_total);
        }
    });
    let result = route(&mut call);
    let wire = call.out();
    wire.conn.send_close_notify();
    let _ = wire.conn.complete_io(&mut wire.sock);
    if counted {
        in_session(&token, |session| {
            session.calls = session.calls.saturating_sub(1);
            if result.is_err() {
                session.broken = Some(Instant::now());
            }
        });
    }
    result
}

/// A connection from the device being synced with that fails before its call is read breaks
/// the sync as one that fails midway does. On Windows a connection the other side gives up on
/// is reset, and the reset takes the request this side had not yet read with it.
fn lost(peer: &str) {
    if let Some(session) = state().session.as_mut().filter(|session| session.peer == peer) {
        session.broken = Some(Instant::now());
    }
}

fn route(call: &mut Call) -> io::Result<()> {
    let (root, me) = {
        let state = state();
        (state.root.clone(), state.me.clone())
    };
    let Some(root) = root else {
        return reply(call.out(), 404, b"{}");
    };
    let path = call.path.clone();
    let parts: Vec<&str> = path.trim_start_matches("/listenook/").split('/').collect();
    if !path.starts_with("/listenook/") {
        return reply(call.out(), 404, b"{}");
    }
    let (method, peer) = (call.method.clone(), call.peer.clone());
    match (method.as_str(), parts.as_slice()) {
        ("GET", ["info"]) => reply_json(call.out(), &Device { revision: library(&root).1, ..told(me) }),
        ("POST", ["pair"]) => {
            let asked: PairAsk = serde_json::from_slice(&read_body(call, 256 * 1024)?)?;
            answer_pairing(call.out(), me, asked, peer)
        }
        ("POST", ["pair", "confirm"]) => {
            let theirs: PairKey = serde_json::from_slice(&read_body(call, 64 * 1024)?)?;
            confirm_pairing(call.out(), &me, theirs, &peer)
        }
        ("POST", ["pair", "finish"]) => {
            let finish: PairFinish = serde_json::from_slice(&read_body(call, 4 * 1024 * 1024)?)?;
            finish_pairing(call.out(), &me, finish, &peer)
        }
        ("POST", ["pair", "cancel", id]) => {
            let mut state = state();
            if let Some(pairing) = state.pairing.take_if(|pairing| pairing.device.id == *id && pairing.asker == peer) {
                state.tell(Event::Paired { serial: pairing.serial, name: None });
            }
            drop(state);
            reply(call.out(), 200, b"{}")
        }
        ("POST", ["leave"]) => {
            read_body(call, 64 * 1024)?;
            let mut state = state();
            let holder = state.ledger.circle.as_ref().and_then(|circle| circle.holder(&peer)).map(str::to_owned);
            let member = holder
                .as_ref()
                .and_then(|holder| state.ledger.circle.as_mut().and_then(|circle| circle.members.get_mut(holder)));
            let Some(member) = member else {
                drop(state);
                return refuse(call.out(), "unpaired");
            };
            member.remove();
            if let Some(holder) = holder {
                state.ledger.seen.remove(&holder);
            }
            state.save();
            drop(state);
            reply(call.out(), 200, b"{}")
        }
        ("POST", ["sync"]) => {
            // As large as the index sent back: both hold the same library.
            let hello: Hello = serde_json::from_slice(&read_body(call, MANIFEST_LIMIT)?)?;
            let from = call.from;
            welcome(call.out(), &root, me, hello, from, &peer)
        }
        _ if !in_session(&call.token, |_| {}) => {
            let ended = !call.token.is_empty() && state().stopped.as_deref() == Some(call.token.as_str());
            reply(call.out(), if ended { 403 } else { 410 }, b"{}")
        }
        ("POST", ["done"]) => {
            let done: Done = serde_json::from_slice(&read_body(call, 64 * 1024)?).unwrap_or_default();
            end_session(&mut state(), done.complete, false);
            reply(call.out(), 200, b"{}")
        }
        (_, [_, id, ..]) if !Job::is_valid_id(id) => reply(call.out(), 400, b"{}"),
        ("GET", ["manifest", id]) => match fs::read(manifest_path(&root, id)) {
            Ok(bytes) => {
                in_session(&call.token, |session| session.sent += 1);
                reply(call.out(), 200, &bytes)
            }
            Err(_) => reply(call.out(), 404, b"{}"),
        },
        ("PUT", ["manifest", id]) => {
            let job: Job = serde_json::from_slice(&read_body(call, MANIFEST_LIMIT)?)?;
            if job.id != *id {
                return reply(call.out(), 400, b"{}");
            }
            let mut state = state();
            state.hand(Incoming::Job(Box::new(job)));
            if let Some(session) = &mut state.session {
                session.received += 1;
            }
            drop(state);
            reply(call.out(), 200, b"{}")
        }
        ("GET", ["media", id]) => {
            let source = persist::load_job(&root, id).and_then(|job| media_of(&root, &job));
            let Some(mut file) = source.and_then(|path| fs::File::open(path).ok()) else {
                return reply(call.out(), 404, b"{}");
            };
            let length = file.metadata()?.len();
            let offset = if call.offset < length { call.offset } else { 0 };
            file.seek(SeekFrom::Start(offset))?;
            let resumed = if offset > 0 { format!("X-Listenook-Offset: {offset}\r\n") } else { String::new() };
            write!(
                call.out(),
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\n{resumed}Connection: close\r\n\r\n",
                length - offset
            )?;
            let token = call.token.clone();
            in_session(&token, |session| session.bytes += offset);
            copy(&mut file, call.out(), length - offset, |count| in_session(&token, |session| session.bytes += count))?;
            call.out().flush()
        }
        ("GET", ["part", id, extension]) => {
            let path = root.join("media").join(media_file_name(id, &format!("x.{extension}")));
            let size = fs::metadata(path.with_extension("part")).map(|file| file.len()).unwrap_or(0);
            reply_json(call.out(), &Part { size })
        }
        ("PUT", ["media", id, extension]) => {
            let path = root.join("media").join(media_file_name(id, &format!("x.{extension}")));
            let token = call.token.clone();
            let (length, offset) = (call.length, call.offset);
            in_session(&token, |session| session.bytes += offset);
            receive(&mut call.body, &path, length, offset, |count| {
                in_session(&token, |session| session.bytes += count)
            })?;
            state().hand(Incoming::Media { id: (*id).to_owned(), path });
            reply(call.out(), 200, b"{}")
        }
        _ => reply(call.out(), 404, b"{}"),
    }
}

fn reason(response: ureq::Response) -> String {
    serde_json::from_reader::<_, Refusal>(response.into_reader().take(4096))
        .map(|refusal| refusal.reason)
        .unwrap_or_default()
}
