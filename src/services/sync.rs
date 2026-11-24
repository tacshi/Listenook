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

use super::secure::{Identity, Wire};
use crate::state::persist;

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
        if let Some((mine, theirs)) = revisions {
            seen.synced_at = now_iso();
            (seen.mine, seen.theirs) = (mine, theirs);
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
    STATE.get_or_init(Mutex::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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
    state.ledger.seen.remove(id);
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
        let local = is_local(from.ip(), on_tailscale);
        if local && ANSWERING.fetch_add(1, Ordering::SeqCst) < HANDLERS {
            thread::spawn(move || {
                if let Err(error) = handle(stream, from.ip()) {
                    log::debug!("sync: {error}");
                }
                ANSWERING.fetch_sub(1, Ordering::SeqCst);
            });
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
            let hello: Hello = serde_json::from_slice(&read_body(call, 4 * 1024 * 1024)?)?;
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

fn answer_pairing(out: &mut Wire, me: Device, asked: PairAsk, asker: String) -> io::Result<()> {
    if asked.device.app != "listenook" || asked.device.id.is_empty() || asked.device.id == me.id {
        return reply(out, 400, b"{}");
    }
    if asked.device.protocol != PROTOCOL {
        return reply(out, 426, b"{}");
    }
    let mut state = state();
    if state.misses.waiting() {
        return reply(out, 429, b"{}");
    }
    let other = state
        .pairing
        .as_ref()
        .is_some_and(|pairing| pairing.device.id != asked.device.id && pairing.at.elapsed() < PAIR_WITHIN);
    if other || state.asking.is_some() {
        return reply(out, 409, b"{}");
    }
    if let Some(old) = state.pairing.take() {
        state.tell(Event::Paired { serial: old.serial, name: None });
    }
    state.serial += 1;
    let serial = state.serial;
    let code = new_code();
    let circle = state.ledger.circle.as_ref().map(Circle::offer);
    state.pairing = Some(Pairing {
        serial,
        device: asked.device.clone(),
        code: code.clone(),
        asker,
        offer: asked.circle,
        key: None,
        attempts: 0,
        at: Instant::now(),
    });
    state.tell(Event::Pairing { serial, device: asked.device, code });
    drop(state);
    reply_json(out, &PairAnswer { device: told(me), circle })
}

/// The pairing the device holding `asker` started, while it may still finish.
fn pairing_of<'a>(state: &'a mut State, id: &str, asker: &str) -> Option<&'a mut Pairing> {
    state
        .pairing
        .as_mut()
        .filter(|pairing| pairing.device.id == id && pairing.asker == asker && pairing.at.elapsed() < PAIR_WITHIN)
}

/// The asker's side of the code's key exchange: answers with this side. Whether the code was
/// right shows only at `finish_pairing`, where the try is counted.
fn confirm_pairing(out: &mut Wire, me: &Device, theirs: PairKey, asker: &str) -> io::Result<()> {
    let mine = state().identity.as_ref().map(|identity| identity.fingerprint.clone()).unwrap_or_default();
    let mut state = state();
    let Some(pairing) = pairing_of(&mut state, &theirs.id, asker) else {
        drop(state);
        return refuse(out, "expired");
    };
    let (pake, message) = Pake::start(&pairing.code, (&pairing.device.id, asker), (&me.id, &mine), false);
    let Some(key) = pake.finish(&theirs.message) else {
        drop(state);
        return reply(out, 400, b"{}");
    };
    pairing.key = Some(key);
    drop(state);
    reply_json(out, &PairKey { id: me.id.clone(), message })
}

fn finish_pairing(out: &mut Wire, me: &Device, finish: PairFinish, asker: &str) -> io::Result<()> {
    let mine = state().identity.as_ref().map(|identity| identity.fingerprint.clone()).unwrap_or_default();
    let mut state = state();
    let Some(pairing) = pairing_of(&mut state, &finish.id, asker) else {
        drop(state);
        return refuse(out, "expired");
    };
    let Some(key) = pairing.key.take() else {
        drop(state);
        return refuse(out, "expired");
    };
    if !same(&finish.proof, &pake_proof(&key, "asker")) {
        pairing.attempts += 1;
        let attempts = pairing.attempts;
        state.misses.miss();
        let waiting = state.misses.waiting();
        let spent = attempts >= PAIR_ATTEMPTS || waiting;
        if spent && let Some(pairing) = state.pairing.take() {
            state.tell(Event::Paired { serial: pairing.serial, name: None });
        }
        drop(state);
        let reason = if waiting {
            "wait"
        } else if spent {
            "expired"
        } else {
            "wrong"
        };
        return refuse(out, reason);
    }
    let Some(pairing) = state.pairing.take() else {
        return refuse(out, "expired");
    };
    state.misses = Misses::default();
    // Both circles end as one, with the devices of both; it keeps the name of the larger one.
    let mine_offer = state.ledger.circle.as_ref().map(Circle::offer);
    let joins = joins_answerer(pairing.offer.as_ref(), mine_offer.as_ref());
    let circle = state.ledger.circle.get_or_insert_with(new_circle);
    if let Some(theirs) = &finish.circle {
        if !joins && !theirs.id.is_empty() {
            circle.id = theirs.id.clone();
        }
        merge_members(&mut circle.members, &theirs.members);
    }
    join(circle, [(me, &mine), (&pairing.device, asker)]);
    let shared = Shared { id: circle.id.clone(), members: circle.members.clone() };
    let circle = circle.clone();
    state.adopt(circle);
    state.save();
    state.tell(Event::Paired { serial: pairing.serial, name: Some(pairing.device.name.clone()) });
    drop(state);
    reply_json(out, &PairDone { proof: pake_proof(&key, "answerer"), circle: shared })
}

pub(crate) fn pair(address: SocketAddr) -> Result<Device, &'static str> {
    let (me, offer) = {
        let state = state();
        (state.me.clone(), state.ledger.circle.as_ref().map(Circle::offer))
    };
    if me.id.is_empty() {
        return Err("sync_failed");
    }
    let seen = Arc::new(Mutex::new(String::new()));
    let asked = PairAsk { device: me, circle: offer };
    let answer: PairAnswer = identity()?
        .agent(None, Some(seen.clone()), Duration::from_secs(10))
        .post(&format!("https://{address}/listenook/pair"))
        .send_bytes(&serde_json::to_vec(&asked).map_err(|_| "sync_failed")?)
        .map_err(code_of)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(256 * 1024)).map_err(|_| "sync_failed")
        })?;
    if !answer.device.is_compatible() {
        return Err("sync_incompatible");
    }
    let answerer = seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
    if answerer.is_empty() {
        return Err("sync_failed");
    }
    remember(answer.device.clone(), address);
    state().asking = Some(Asking { address, device: answer.device.clone(), answerer });
    Ok(answer.device)
}

pub(crate) fn confirm(code: &str) -> Result<(), &'static str> {
    let code: String = code.chars().filter(char::is_ascii_digit).collect();
    if !is_code(&code) {
        return Err("sync_wrong_code");
    }
    let identity = identity()?;
    let (asking, me, circle) = {
        let state = state();
        (state.asking.clone().ok_or("sync_code_expired")?, state.me.clone(), state.ledger.circle.clone())
    };
    // Only the device seen when asking: a certificate that changed is someone else.
    let agent = identity.agent(Some(&asking.answerer), None, Duration::from_secs(10));
    let base = format!("https://{}/listenook", asking.address);
    let refused = |error: ureq::Error| -> &'static str {
        match error {
            ureq::Error::Status(403, response) => {
                let reason = reason(response);
                if reason == "wrong" {
                    return "sync_wrong_code";
                }
                state().asking = None;
                if reason == "wait" { "sync_pair_wait" } else { "sync_code_expired" }
            }
            ureq::Error::Status(404 | 410, _) => {
                state().asking = None;
                "sync_code_expired"
            }
            error => code_of(error),
        }
    };
    let (pake, message) =
        Pake::start(&code, (&me.id, &identity.fingerprint), (&asking.device.id, &asking.answerer), true);
    let sent = PairKey { id: me.id.clone(), message };
    let theirs: PairKey = agent
        .post(&format!("{base}/pair/confirm"))
        .send_bytes(&serde_json::to_vec(&sent).map_err(|_| "sync_failed")?)
        .map_err(refused)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(64 * 1024)).map_err(|_| "sync_failed")
        })?;
    let key = pake.finish(&theirs.message).ok_or("sync_failed")?;
    let finish = PairFinish {
        id: me.id.clone(),
        proof: pake_proof(&key, "asker"),
        circle: circle.as_ref().map(|circle| Shared { id: circle.id.clone(), members: circle.members.clone() }),
    };
    let done: PairDone = agent
        .post(&format!("{base}/pair/finish"))
        .send_bytes(&serde_json::to_vec(&finish).map_err(|_| "sync_failed")?)
        .map_err(refused)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(4 * 1024 * 1024)).map_err(|_| "sync_failed")
        })?;
    let mut state = state();
    state.asking = None;
    if !same(&done.proof, &pake_proof(&key, "answerer")) {
        return Err("sync_failed");
    }
    let mut circle = circle.unwrap_or_else(new_circle);
    if !done.circle.id.is_empty() {
        circle.id = done.circle.id;
    }
    merge_members(&mut circle.members, &done.circle.members);
    join(&mut circle, [(&me, &identity.fingerprint), (&asking.device, &asking.answerer)]);
    state.adopt(circle);
    state.ledger.seen.entry(asking.device.id.clone()).or_default().learn(&asking.device);
    state.saw(&asking.device.id, asking.address, None);
    Ok(())
}

pub(crate) fn abandon() {
    let (asking, id, identity) = {
        let mut state = state();
        (state.asking.take(), state.me.id.clone(), state.identity.clone())
    };
    if let (Some(asking), Some(identity)) = (asking, identity) {
        thread::spawn(move || {
            let _ = identity
                .agent(Some(&asking.answerer), None, Duration::from_secs(3))
                .post(&format!("https://{}/listenook/pair/cancel/{id}", asking.address))
                .call();
        });
    }
}

fn reason(response: ureq::Response) -> String {
    serde_json::from_reader::<_, Refusal>(response.into_reader().take(4096))
        .map(|refusal| refusal.reason)
        .unwrap_or_default()
}

fn welcome(out: &mut Wire, root: &Path, me: Device, hello: Hello, from: IpAddr, peer: &str) -> io::Result<()> {
    if hello.device.app != "listenook" || hello.device.id.is_empty() {
        return reply(out, 400, b"{}");
    }
    if hello.device.protocol != PROTOCOL {
        return reply(out, 426, b"{}");
    }
    let id = hello.device.id.clone();
    let trusted = {
        let mut state = state();
        // The device is the one whose certificate it showed, and it has to be in the circle
        // before anything it says is taken: a device taken out cannot put itself back.
        let Some(circle) = state.ledger.circle.as_mut().filter(|circle| circle.holder(peer) == Some(id.as_str()))
        else {
            drop(state);
            return refuse(out, "unpaired");
        };
        if !circle.has(&id) {
            drop(state);
            return refuse(out, "removed");
        }
        let mut changed = merge_members(&mut circle.members, &hello.members);
        if let Some(member) = circle.members.get_mut(&id).filter(|member| member.is_in())
            && (member.name != hello.device.name || member.platform != hello.device.platform)
        {
            (member.name, member.platform) = (hello.device.name.clone(), hello.device.platform.clone());
            changed = true;
        }
        let verdict = if !circle.has(&me.id) {
            Err("unpaired")
        } else if !circle.has(&id) {
            Err("removed")
        } else {
            Ok(circle.members.clone())
        };
        let learned = verdict.is_ok() && state.ledger.seen.entry(id.clone()).or_default().learn(&hello.device);
        match verdict {
            Err("unpaired") => state.leave(),
            _ if changed || learned => state.save(),
            _ => {}
        }
        verdict
    };
    let members = match trusted {
        Ok(members) => members,
        Err(reason) => return refuse(out, reason),
    };
    let (_, revision) = library(root);
    let token = uuid::Uuid::new_v4().to_string();
    let busy = {
        let mut state = state();
        if state.session.as_ref().is_some_and(Session::is_over) {
            end_session(&mut state, false, true);
        }
        let same_device = state.session.as_ref().is_some_and(|session| session.device == id);
        if state.starting.is_some() || (state.session.is_some() && !same_device) {
            drop(state);
            return reply(out, 409, b"{}");
        }
        let (busy, counts) = match state.session.take() {
            Some(old) if hello.resume => (old.busy, (old.received, old.sent)),
            _ => match state.resumable.take() {
                Some(lost) if hello.resume && lost.device == id && lost.at.elapsed() < RESUME_WITHIN => {
                    (lost.busy, (0, 0))
                }
                _ => (state.busy.clone(), (0, 0)),
            },
        };
        let address = SocketAddr::new(from, hello.device.port).to_string();
        open_session(&mut state, &hello, (&token, peer), busy.clone(), counts, (address, revision.clone()));
        busy
    };
    let (index, _) = index_of(root, &busy);
    in_session(&token, |_| {});
    let sent = reply_json(out, &Welcome { token: token.clone(), device: told(me), index, revision, members });
    if sent.is_err() {
        in_session(&token, |session| session.broken = Some(Instant::now()));
    }
    sent
}

fn open_session(
    state: &mut State,
    hello: &Hello,
    (token, peer): (&str, &str),
    busy: HashSet<String>,
    (received, sent): (u32, u32),
    (address, mine): (String, String),
) {
    state.hand(Incoming::Removed(hello.removed.clone()));
    state.hand(Incoming::Catalog(hello.catalog.clone()));
    state.hand(Incoming::Podcasts(Box::new(hello.podcasts.clone())));
    state.hand(Incoming::Shelves(Box::new(hello.shelves.clone())));
    state.hand(Incoming::Activity(Box::new(hello.activity.clone())));
    for (id, name) in &hello.names {
        state.hand(Incoming::Name { id: id.clone(), name: name.clone() });
    }
    state.resumable = None;
    state.session = Some(Session {
        token: token.to_owned(),
        peer: peer.to_owned(),
        device: hello.device.id.clone(),
        busy,
        name: hello.device.name.clone(),
        auto: hello.auto,
        address,
        mine,
        theirs: hello.revision.clone(),
        last: Instant::now(),
        received,
        sent,
        calls: 0,
        broken: None,
        items: 0,
        items_total: 0,
        bytes: 0,
        bytes_total: 0,
    });
}

fn manifest_path(root: &Path, id: &str) -> PathBuf {
    root.join("jobs").join(id).join("manifest.json")
}

fn media_of(root: &Path, job: &Job) -> Option<PathBuf> {
    let path = PathBuf::from(
        persist::rehomed(&job.source_path, root, Path::is_file).unwrap_or_else(|| job.source_path.clone()),
    );
    (!persist::climbs(&path)).then_some(path)
}

fn names(entries: &[Entry]) -> impl Iterator<Item = (String, String)> + '_ {
    entries.iter().filter_map(|entry| {
        let name = entry.media_name.as_ref().filter(|name| !is_sync_name(&entry.id, name))?;
        Some((entry.id.clone(), name.clone()))
    })
}

fn library(root: &Path) -> (Index, String) {
    let (mut index, revision) = recordings(root);
    index.shelves = Shelves::of_settings(&persist::load_settings(root));
    let shelves = serde_json::to_string(&index.shelves).unwrap_or_default();
    let revision = digest(&[&revision, &shelves]);
    (index, revision)
}

fn recordings(root: &Path) -> (Index, String) {
    let generation = persist::generation();
    let cached = state()
        .library
        .clone()
        .filter(|library| library.root == root && library.generation == generation)
        .map(|library| (library.index, library.revision));
    if let Some(cached) = cached {
        return cached;
    }
    let entries = persist::load_jobs(root)
        .iter()
        .map(|job| {
            let size = media_of(root, job)
                .and_then(|path| fs::metadata(path).ok())
                .filter(fs::Metadata::is_file)
                .map(|file| file.len());
            Entry::of(job, size)
        })
        .collect();
    let index = Index {
        entries,
        catalog: persist::load_library_catalog(root),
        removed: persist::load_removed(root),
        podcasts: Podcasts::of(&persist::load_catalog(root), &persist::load_listening(root)),
        shelves: Shelves::default(),
        activity: persist::load_activity(root),
    };
    let revision = digest(&[&serde_json::to_string(&index).unwrap_or_default()]);
    state().library =
        Some(Library { root: root.to_owned(), generation, index: index.clone(), revision: revision.clone() });
    (index, revision)
}

fn index_of(root: &Path, busy: &HashSet<String>) -> (Index, String) {
    let (mut index, revision) = library(root);
    for entry in &mut index.entries {
        entry.busy |= busy.contains(&entry.id);
    }
    (index, revision)
}

fn copy(from: &mut impl Read, to: &mut impl Write, length: u64, mut alive: impl FnMut(u64) -> bool) -> io::Result<()> {
    let mut buffer = vec![0_u8; 128 * 1024];
    let mut left = length;
    while left > 0 {
        let want = buffer.len().min(left as usize);
        let read = from.read(&mut buffer[..want])?;
        if read == 0 {
            return Err(io::Error::other("the transfer ended early"));
        }
        to.write_all(&buffer[..read])?;
        left -= read as u64;
        if !alive(read as u64) {
            return Err(io::Error::other("stopped"));
        }
    }
    Ok(())
}

fn receive(
    from: &mut impl Read,
    path: &Path,
    length: u64,
    offset: u64,
    alive: impl FnMut(u64) -> bool,
) -> io::Result<()> {
    if let Some(folder) = path.parent() {
        fs::create_dir_all(folder)?;
    }
    let part = path.with_extension("part");
    let mut file = if offset > 0 {
        let file = fs::OpenOptions::new().append(true).open(&part)?;
        if file.metadata()?.len() != offset {
            return Err(io::Error::other("what is here of the file is not what the rest follows"));
        }
        file
    } else {
        fs::File::create(&part)?
    };
    copy(from, &mut file, length, alive)?;
    file.flush()?;
    drop(file);
    fs::rename(&part, path)
}

fn code_of(error: ureq::Error) -> &'static str {
    match error {
        ureq::Error::Status(409, _) => "sync_peer_busy",
        ureq::Error::Status(426, _) => "sync_incompatible",
        ureq::Error::Status(429, _) => "sync_pair_wait",
        ureq::Error::Status(..) => "sync_failed",
        ureq::Error::Transport(_) => "sync_unreachable",
    }
}

/// Syncs with each paired device that answers; `large` other than `Left` syncs even with those
/// already in step. How many it synced with, and how many recordings over `LARGE_MEDIA` it left
/// because it went over Tailscale.
pub(crate) fn round(busy: &HashSet<String>, large: Large) -> (u32, u32) {
    let force = large != Large::Left;
    let (root, turn) = {
        let state = state();
        match &state.root {
            Some(root) if state.visible && state.ledger.circle.is_some() => (root.clone(), state.turn),
            _ => return (0, 0),
        }
    };
    let mut mates = mates();
    mates.sort_by(|a, b| a.synced_at.cmp(&b.synced_at));
    let mut looked = false;
    let (mut synced, mut left) = (0, 0);
    for mate in mates {
        // A round belongs to the library and devices it started with: once sync is set up
        // again (turned off and on, another library), it stops rather than go on with theirs.
        let Some((address, device)) = reach(&mate.id, &mut looked, turn) else {
            continue;
        };
        if state().turn != turn {
            break;
        }
        let seen = state().ledger.seen.get(&mate.id).cloned().unwrap_or_default();
        let (_, mine) = library(&root);
        if !force && !device.revision.is_empty() && seen.mine == mine && seen.theirs == device.revision {
            continue;
        }
        match sync_with(address, &mate.id, busy.clone(), &Progress::default(), true, large) {
            Ok(summary) => {
                synced += 1;
                left += summary.left;
            }
            Err(code) => log::debug!("sync: with {}: {code}", mate.name),
        }
    }
    (synced, left)
}

fn reach(id: &str, looked: &mut bool, turn: u64) -> Option<(SocketAddr, Device)> {
    loop {
        let places: Vec<SocketAddr> = {
            let state = state();
            if state.turn != turn {
                return None;
            }
            state.places(id)
        };
        for address in places {
            if let Some(device) = ask_within(address, Duration::from_millis(1500)).filter(|device| device.id == id) {
                remember(device.clone(), address);
                return Some((address, device));
            }
        }
        if std::mem::replace(looked, true) {
            return None;
        }
        announce(true);
        thread::sleep(REPLIES_WITHIN);
    }
}

pub(crate) fn sync_with(
    address: SocketAddr,
    id: &str,
    busy: HashSet<String>,
    progress: &Progress,
    auto: bool,
    large: Large,
) -> Result<Summary, &'static str> {
    let (identity, key) = (identity()?, key_of(id)?);
    let (root, me, mine) = {
        let mut state = state();
        if state.session.is_some() || state.starting.is_some() {
            return Err("sync_peer_busy");
        }
        state.starts += 1;
        let mine = state.starts;
        state.starting = Some(mine);
        progress.turn.store(state.turn, Ordering::Relaxed);
        (state.root.clone(), state.me.clone(), mine)
    };
    let result = match root {
        Some(root) => persist_with((address, &key, &identity), &root, &me, &busy, progress, (auto, large)),
        None => Err("sync_failed"),
    };
    progress.waiting.store(false, Ordering::Relaxed);
    // Only this sync's own mark: once sync was set up again, another may be running.
    let mut state = state();
    if state.starting == Some(mine) {
        state.starting = None;
    }
    drop(state);
    result
}

fn persist_with(
    (address, key, identity): (SocketAddr, &str, &Identity),
    root: &Path,
    me: &Device,
    busy: &HashSet<String>,
    progress: &Progress,
    (auto, large): (bool, Large),
) -> Result<Summary, &'static str> {
    let mut summary = Summary::default();
    let mut lost: Option<Instant> = None;
    loop {
        let again = lost.is_some();
        let code = match exchange(
            (address, key, identity),
            root,
            me.clone(),
            busy,
            progress,
            (again, auto, large),
            &mut summary,
        ) {
            Ok(()) => return Ok(summary),
            Err(code) => code,
        };
        let stopped = || progress.halted();
        let worth = recoverable(code) || (again && code == "sync_peer_busy");
        if auto || stopped() || !worth || !progress.accepted.load(Ordering::Relaxed) {
            return Err(code);
        }
        if !progress.waiting.load(Ordering::Relaxed) {
            lost = None;
        }
        if lost.get_or_insert_with(Instant::now).elapsed() > RETRY_FOR {
            return Err(code);
        }
        progress.waiting.store(true, Ordering::Relaxed);
        log::debug!("sync: {code}, trying again");
        let wait = Instant::now();
        while wait.elapsed() < RETRY_EVERY {
            if stopped() {
                return Err("sync_cancelled");
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}

/// Leaves out of `plan` the media over `LARGE_MEDIA`: how many recordings' media it left.
fn leave_large_media(plan: &mut listenook_core::sync::Plan) -> u32 {
    let mut left = 0;
    for transfer in plan.pull.iter_mut().chain(plan.push.iter_mut()) {
        if transfer.media && transfer.media_size > LARGE_MEDIA {
            transfer.media = false;
            left += 1;
        }
    }
    plan.pull.retain(|transfer| transfer.manifest || transfer.media);
    plan.push.retain(|transfer| transfer.manifest || transfer.media);
    left
}

fn recoverable(code: &str) -> bool {
    matches!(code, "sync_interrupted" | "sync_unreachable")
}

/// Syncs with the device at `address` whose certificate has the fingerprint `key`, as the
/// device `identity` is.
fn exchange(
    (address, key, identity): (SocketAddr, &str, &Identity),
    root: &Path,
    me: Device,
    busy: &HashSet<String>,
    progress: &Progress,
    (resume, auto, large): (bool, bool, Large),
    summary: &mut Summary,
) -> Result<(), &'static str> {
    let base = format!("https://{address}/listenook");
    let agent = |read: Duration| identity.agent(Some(key), None, read);
    let circle = state().ledger.circle.clone().ok_or("sync_unpaired")?;
    let (local, revision) = index_of(root, busy);
    let hello = Hello {
        device: told(me),
        catalog: local.catalog.clone(),
        resume,
        auto,
        revision: revision.clone(),
        members: circle.members.clone(),
        names: names(&local.entries).collect(),
        removed: local.removed.clone(),
        podcasts: local.podcasts.clone(),
        shelves: local.shelves.clone(),
        activity: local.activity.clone(),
    };
    let answered = agent(Duration::from_secs(120))
        .post(&format!("{base}/sync"))
        .send_bytes(&serde_json::to_vec(&hello).map_err(|_| "sync_failed")?);
    let welcome: Welcome = match answered {
        Ok(response) => {
            serde_json::from_reader(response.into_reader().take(MANIFEST_LIMIT)).map_err(|_| "sync_failed")?
        }
        Err(ureq::Error::Status(403, response)) => {
            return Err(if reason(response) == "removed" {
                state().leave();
                "sync_removed"
            } else {
                "sync_unpaired"
            });
        }
        Err(error) => return Err(code_of(error)),
    };
    {
        let mut state = state();
        let Some(mine) = state.ledger.circle.as_mut().filter(|mine| mine.id == circle.id) else {
            return Err("sync_unpaired");
        };
        merge_members(&mut mine.members, &welcome.members);
        let trusted = mine.has(&welcome.device.id) && mine.holder(key) == Some(welcome.device.id.as_str());
        if !trusted {
            state.saw(&welcome.device.id, address, None);
            return Err("sync_unpaired");
        }
        state.ledger.seen.entry(welcome.device.id.clone()).or_default().learn(&welcome.device);
        state.saw(&welcome.device.id, address, None);
    }
    if progress.halted() {
        return Err("sync_cancelled");
    }
    progress.accepted.store(true, Ordering::Relaxed);
    progress.waiting.store(false, Ordering::Relaxed);
    progress.items.store(0, Ordering::Relaxed);
    progress.bytes.store(0, Ordering::Relaxed);
    let http = agent(Duration::from_secs(30));
    let token = welcome.token.as_str();
    let mut plan = plan_with(&local.entries, &welcome.index.entries, &local.removed, &welcome.index.removed);
    let left = if large.leaves(address) { leave_large_media(&mut plan) } else { 0 };
    summary.left = if large == Large::Nearby { left } else { 0 };
    progress.items_total.store((plan.pull.len() + plan.push.len()) as u64, Ordering::Relaxed);
    progress.bytes_total.store(plan.media_bytes(), Ordering::Relaxed);
    {
        let mut state = state();
        state.hand(Incoming::Removed(welcome.index.removed.clone()));
        state.hand(Incoming::Catalog(welcome.index.catalog.clone()));
        state.hand(Incoming::Podcasts(Box::new(welcome.index.podcasts.clone())));
        state.hand(Incoming::Shelves(Box::new(welcome.index.shelves.clone())));
        state.hand(Incoming::Activity(Box::new(welcome.index.activity.clone())));
        for (id, name) in names(&welcome.index.entries) {
            state.hand(Incoming::Name { id, name });
        }
    }

    let call = |request: ureq::Request| {
        request.set("X-Listenook-Token", token).set(
            "X-Listenook-Progress",
            &format!(
                "{} {} {}",
                progress.items.load(Ordering::Relaxed),
                progress.items_total.load(Ordering::Relaxed),
                progress.bytes_total.load(Ordering::Relaxed)
            ),
        )
    };
    let moved = |count: u64| {
        progress.bytes.fetch_add(count, Ordering::Relaxed);
        !progress.halted()
    };
    let failed = |error: ureq::Error| match error {
        ureq::Error::Status(403, _) => "sync_cancelled_there",
        ureq::Error::Status(410, _) => "sync_interrupted",
        other => code_of(other),
    };
    let stopped = |_: io::Error| {
        if progress.halted() { "sync_cancelled" } else { "sync_interrupted" }
    };
    let pull = |transfer: &Transfer| -> Result<(), &'static str> {
        let id = &transfer.id;
        let path = root.join("media").join(media_file_name(id, &transfer.media_name));
        if transfer.media {
            let part = path.with_extension("part");
            let have = fs::metadata(&part).map(|file| file.len()).unwrap_or(0);
            let have = if have < transfer.media_size { have } else { 0 };
            let mut request = call(http.get(&format!("{base}/media/{id}")));
            if have > 0 {
                request = request.set("X-Listenook-Offset", &have.to_string());
            }
            let response = request.call().map_err(failed)?;
            let length: u64 =
                response.header("Content-Length").and_then(|length| length.parse().ok()).ok_or("sync_failed")?;
            let from: u64 = response.header("X-Listenook-Offset").and_then(|from| from.parse().ok()).unwrap_or(0);
            if from > 0 && (from != have || from + length != transfer.media_size) {
                let _ = fs::remove_file(&part);
                return Err("sync_interrupted");
            }
            progress.bytes.fetch_add(from, Ordering::Relaxed);
            receive(&mut response.into_reader(), &path, length, from, moved).map_err(stopped)?;
        }
        if transfer.manifest {
            let response = call(http.get(&format!("{base}/manifest/{id}"))).call().map_err(failed)?;
            let job: Job = serde_json::from_reader(response.into_reader().take(MANIFEST_LIMIT))
                .ok()
                .filter(|job: &Job| &job.id == id)
                .ok_or("sync_failed")?;
            state().hand(Incoming::Job(Box::new(job)));
        } else if transfer.media {
            state().hand(Incoming::Media { id: id.clone(), path });
        }
        Ok(())
    };
    let push = |transfer: &Transfer| -> Result<(), &'static str> {
        let id = &transfer.id;
        if transfer.media {
            let source = persist::load_job(root, id).and_then(|job| media_of(root, &job)).ok_or("sync_failed")?;
            let mut file = fs::File::open(&source).map_err(|_| "sync_failed")?;
            let length = file.metadata().map_err(|_| "sync_failed")?.len();
            let extension = media_extension(&transfer.media_name);
            let have = call(http.get(&format!("{base}/part/{id}/{extension}")))
                .call()
                .ok()
                .and_then(|response| serde_json::from_reader::<_, Part>(response.into_reader().take(1024)).ok())
                .map_or(0, |part| part.size);
            let have = if have < length { have } else { 0 };
            file.seek(SeekFrom::Start(have)).map_err(|_| "sync_failed")?;
            progress.bytes.fetch_add(have, Ordering::Relaxed);
            let mut counted = Counted { inner: file, moved: &moved };
            let mut request = call(http.put(&format!("{base}/media/{id}/{extension}")));
            if have > 0 {
                request = request.set("X-Listenook-Offset", &have.to_string());
            }
            request
                .set("Content-Length", &(length - have).to_string())
                .send(&mut counted)
                .map_err(|error| if progress.halted() { "sync_cancelled" } else { failed(error) })?;
        }
        if transfer.manifest {
            let manifest = fs::read(manifest_path(root, id)).map_err(|_| "sync_failed")?;
            call(http.put(&format!("{base}/manifest/{id}"))).send_bytes(&manifest).map_err(failed)?;
        }
        Ok(())
    };

    let mut outcome = Ok(());
    for (transfer, pulling) in plan.pull.iter().map(|t| (t, true)).chain(plan.push.iter().map(|t| (t, false))) {
        if progress.halted() {
            outcome = Err("sync_cancelled");
            break;
        }
        outcome = if pulling { pull(transfer) } else { push(transfer) };
        if outcome.is_err() {
            break;
        }
        if pulling {
            summary.received += 1;
        } else {
            summary.sent += 1;
        }
        progress.items.fetch_add(1, Ordering::Relaxed);
    }
    if matches!(outcome, Err(code) if recoverable(code)) && !progress.halted() {
        return outcome;
    }
    let told = call(agent(Duration::from_secs(5)).post(&format!("{base}/done")))
        .send_bytes(&serde_json::to_vec(&Done { complete: outcome.is_ok() }).unwrap_or_default());
    if matches!(told, Err(ureq::Error::Status(403, _))) && matches!(outcome, Err(code) if code != "sync_cancelled") {
        outcome = Err("sync_cancelled_there");
    }
    if outcome.is_ok() {
        state().saw(&welcome.device.id, address, Some((revision, welcome.revision)));
    }
    outcome
}

struct Counted<'a, R, F: Fn(u64) -> bool> {
    inner: R,
    moved: &'a F,
}

impl<R: Read, F: Fn(u64) -> bool> Read for Counted<'_, R, F> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.inner.read(buffer)?;
        if (self.moved)(read as u64) { Ok(read) } else { Err(io::Error::other("stopped")) }
    }
}

#[cfg(test)]
mod tests {
    use listenook_core::{JobStatus, Named};

    use super::*;

    static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

    fn library(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("listenook-sync-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn recording(root: &Path, id: &str, updated: &str, media: Option<&[u8]>) -> Job {
        let source = root.join("originals").join(format!("{id}.mp3"));
        if let Some(bytes) = media {
            fs::create_dir_all(source.parent().unwrap()).unwrap();
            fs::write(&source, bytes).unwrap();
        }
        let job = Job {
            id: id.into(),
            source_path: source.to_string_lossy().into_owned(),
            updated_at: updated.into(),
            status: JobStatus::Completed,
            display_title: Some(format!("Title of {id} at {updated}")),
            ..Job::default()
        };
        persist::save_job(root, &job).unwrap();
        job
    }

    fn fingerprint_of(library: &Path) -> String {
        Identity::of(library).unwrap().fingerprint.clone()
    }

    /// Pairs the devices in `root`'s ledger, each known by the key kept in its library.
    fn paired(root: &Path, devices: &[(&str, &Path)]) -> Circle {
        let members = devices
            .iter()
            .map(|(id, library)| {
                let member = Member {
                    name: (*id).into(),
                    joined_at: now_iso(),
                    key: fingerprint_of(library),
                    ..Member::default()
                };
                ((*id).to_owned(), member)
            })
            .collect();
        let circle = Circle { id: "circle".into(), members };
        let ledger = Ledger { circle: Some(circle.clone()), ..Ledger::default() };
        fs::write(root.join("sync.json"), serde_json::to_vec(&ledger).unwrap()).unwrap();
        circle
    }

    fn started(root: &Path, port: u16) -> SocketAddr {
        unsafe { std::env::set_var("LISTENOOK_SYNC_PORT", port.to_string()) };
        state().misses = Misses::default();
        configure(Some(root.to_owned()), "device-there".into(), "There".into(), true);
        let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
        let found = (0..50).find_map(|_| {
            thread::sleep(Duration::from_millis(50));
            ask(address)
        });
        assert_eq!(found.expect("the device answers").name, "There");
        address
    }

    /// Another device, with the key kept in `library`, that goes on only with the device whose
    /// key is kept in `there` (with any device when `None`).
    fn client(library: &Path, there: Option<&Path>) -> ureq::Agent {
        Identity::of(library).unwrap().agent(there.map(fingerprint_of).as_deref(), None, Duration::from_secs(2))
    }

    #[allow(clippy::result_large_err)]
    fn post(agent: &ureq::Agent, url: &str, body: &impl Serialize) -> Result<ureq::Response, ureq::Error> {
        agent.post(url).send_bytes(&serde_json::to_vec(body).unwrap())
    }

    fn json<T: serde::de::DeserializeOwned>(response: ureq::Response) -> T {
        serde_json::from_reader(response.into_reader()).unwrap()
    }

    fn asker() -> Device {
        Device { app: "listenook".into(), protocol: PROTOCOL, id: "device-here".into(), ..Device::default() }
    }

    fn shown_code() -> String {
        take()
            .1
            .into_iter()
            .find_map(|event| match event {
                Event::Pairing { code, device, .. } if device.id == "device-here" => Some(code),
                _ => None,
            })
            .expect("a code is shown")
    }

    /// Asks the device at `base` to pair as "device-here" with the key in `library`, and tries
    /// `code`: what it answered, or why it refused.
    fn try_code(base: &str, library: &Path, there: &str, code: &str) -> Result<PairDone, String> {
        let here = Identity::of(library).unwrap();
        let agent = here.agent(Some(there), None, Duration::from_secs(2));
        let (pake, message) = Pake::start(code, ("device-here", &here.fingerprint), ("device-there", there), true);
        let theirs = match post(&agent, &format!("{base}/pair/confirm"), &PairKey { id: "device-here".into(), message })
        {
            Ok(response) => json::<PairKey>(response),
            Err(ureq::Error::Status(403, response)) => return Err(reason(response)),
            Err(error) => panic!("{error}"),
        };
        let key = pake.finish(&theirs.message).expect("a key exchange message");
        let finish = PairFinish { id: "device-here".into(), proof: pake_proof(&key, "asker"), circle: None };
        match post(&agent, &format!("{base}/pair/finish"), &finish) {
            Ok(response) => {
                let done: PairDone = json(response);
                assert!(same(&done.proof, &pake_proof(&key, "answerer")), "the device proves it knew the code");
                Ok(done)
            }
            Err(ureq::Error::Status(403, response)) => Err(reason(response)),
            Err(error) => panic!("{error}"),
        }
    }

    /// Asks the device at `base` for a code, as "device-here" with the key in `library`: the
    /// fingerprint of the certificate the device showed.
    #[allow(clippy::result_large_err)]
    fn ask_for_code(base: &str, library: &Path) -> Result<String, ureq::Error> {
        let seen = Arc::new(Mutex::new(String::new()));
        let agent = Identity::of(library).unwrap().agent(None, Some(seen.clone()), Duration::from_secs(2));
        post(
            &agent,
            &format!("{base}/pair"),
            &PairAsk { device: Device { name: "Here".into(), ..asker() }, circle: None },
        )?;
        Ok(seen.lock().unwrap().clone())
    }

    #[test]
    #[cfg_attr(windows, ignore = "iOS container paths")]
    fn media_is_offered_from_where_the_apps_folder_is_now() {
        let root = library("moved").join("Library/Application Support");
        fs::create_dir_all(root.join("media/one")).unwrap();
        fs::write(root.join("media/one/Talk.m4a"), b"sound").unwrap();
        let job = Job {
            id: "moved".into(),
            source_path: "@container/Library/Application Support/media/one/Talk.m4a".into(),
            status: JobStatus::Completed,
            ..Job::default()
        };
        persist::save_job(&root, &job).unwrap();
        let (index, _) = index_of(&root, &HashSet::new());
        assert_eq!(index.entries[0].media_size, 5);
        assert_eq!(index.entries[0].media_name.as_deref(), Some("Talk.m4a"));
        assert_eq!(media_of(&root, &job), Some(root.join("media/one/Talk.m4a")));
        let _ = fs::remove_dir_all(root.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn two_paired_libraries_end_as_their_union_without_asking() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (there, here) = (library("there"), library("here"));
        recording(&there, "only-there", "2026-01-01T00:00:00.000Z", Some(b"remote media"));
        recording(&there, "both", "2026-03-01T00:00:00.000Z", None);
        recording(&here, "both", "2026-02-01T00:00:00.000Z", Some(b"local media"));
        recording(&here, "only-here", "2026-01-01T00:00:00.000Z", Some(b"pushed media"));
        recording(&here, "gone-there", "2026-01-01T00:00:00.000Z", Some(b"unwanted there"));
        recording(&there, "gone-here", "2026-01-01T00:00:00.000Z", Some(b"unwanted here"));
        let removed = |id: &str| [(id.to_owned(), "2026-02-01T00:00:00.000Z".to_owned())].into();
        persist::save_removed(&there, &removed("gone-there")).unwrap();
        persist::save_removed(&here, &removed("gone-here")).unwrap();
        let catalog =
            LibraryCatalog { tags: vec![Named { id: "t1".into(), name: "todo".into() }], ..Default::default() };
        persist::save_library_catalog(&there, &catalog).unwrap();
        let shows = listenook_core::podcast::Catalog {
            followed: vec![listenook_core::podcast::Followed {
                feed_url: "https://example.com/there.xml".into(),
                followed_at: "2026-01-01T00:00:00.000Z".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        persist::save_catalog(&there, &shows, &[]).unwrap();
        let heard = listenook_core::podcast::ListenProgress {
            episode_id: "heard-here".into(),
            position_ms: 42_000,
            updated_at: Some("2026-01-01T00:00:00.000Z".into()),
            ..Default::default()
        };
        persist::save_listening(&here, &[heard]).unwrap();
        paired(&there, &[("device-there", &there), ("device-here", &here)]);
        let address = started(&there, 47931);

        let progress = Progress::default();
        progress.turn.store(state().turn, Ordering::Relaxed);
        let mut summary = Summary::default();
        let (key, identity) = (fingerprint_of(&there), Identity::of(&here).unwrap());
        let reached = (address, key.as_str(), &*identity);
        exchange(reached, &here, asker(), &HashSet::new(), &progress, (false, true, Large::All), &mut summary).unwrap();
        assert_eq!(summary, Summary { received: 2, sent: 2, left: 0 });
        assert_eq!(progress.items.load(Ordering::Relaxed), 4);

        let (incoming, events) = take();
        assert!(events.iter().any(|event| matches!(
            event,
            Event::Served { received: 1, sent: 2, complete: true, lost: false, auto: true, .. }
        )));
        let jobs: Vec<&Job> = incoming
            .iter()
            .filter_map(|incoming| match incoming {
                Incoming::Job(job) => Some(&**job),
                _ => None,
            })
            .collect();
        let titles: Vec<String> = jobs.iter().map(|job| job.title()).collect();
        assert!(titles.contains(&"Title of only-there at 2026-01-01T00:00:00.000Z".to_owned()));
        assert!(titles.contains(&"Title of both at 2026-03-01T00:00:00.000Z".to_owned()));
        assert!(titles.contains(&"Title of only-here at 2026-01-01T00:00:00.000Z".to_owned()));
        assert_eq!(fs::read(here.join("media/sync-only-there.mp3")).unwrap(), b"remote media");
        assert_eq!(fs::read(there.join("media/sync-only-here.mp3")).unwrap(), b"pushed media");
        assert_eq!(fs::read(there.join("media/sync-both.mp3")).unwrap(), b"local media");
        assert!(incoming.iter().any(|incoming| matches!(incoming, Incoming::Media { id, .. } if id == "both")));
        assert!(incoming.iter().any(|incoming| matches!(incoming, Incoming::Catalog(c) if c.tags.len() == 1)));
        let shows_arrive = incoming.iter().any(|incoming| {
            matches!(incoming, Incoming::Podcasts(p) if p.followed.iter().any(|f| f.feed_url.ends_with("there.xml")))
        });
        assert!(shows_arrive, "the shows followed there come here");
        let places_go = incoming.iter().any(|incoming| {
            matches!(incoming, Incoming::Podcasts(p) if p.listened.iter().any(|e| e.episode_id == "heard-here"))
        });
        assert!(places_go, "where an episode was left here goes there");
        assert!(!titles.iter().any(|title| title.contains("gone-")), "{titles:?}");
        assert!(!here.join("media/sync-gone-here.mp3").exists() && !there.join("media/sync-gone-there.mp3").exists());
        for id in ["gone-here", "gone-there"] {
            let told = incoming.iter().any(|incoming| matches!(incoming, Incoming::Removed(r) if r.contains_key(id)));
            assert!(told, "{id} is told as removed");
        }
        let seen = state().ledger.seen.get("device-here").cloned().unwrap_or_default();
        assert!(!seen.synced_at.is_empty() && !seen.mine.is_empty(), "when and what was synced is kept");

        let refused = client(&here, Some(&there)).get(&format!("https://{address}/listenook/manifest/both")).call();
        assert!(matches!(refused, Err(ureq::Error::Status(410, _))));
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here));
    }

    #[test]
    fn a_device_not_paired_is_refused_and_copies_nothing() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (there, here, stranger) = (library("refusing"), library("refusing-here"), library("stranger"));
        recording(&there, "kept", "2026-01-01T00:00:00.000Z", None);
        paired(&there, &[("device-there", &there), ("device-here", &here)]);
        let address = started(&there, 47932);
        let base = format!("https://{address}/listenook");
        take();
        let hello = Hello { device: asker(), ..Hello::default() };
        let Err(ureq::Error::Status(403, response)) =
            post(&client(&stranger, Some(&there)), &format!("{base}/sync"), &hello)
        else {
            panic!("a device with another key is refused");
        };
        assert_eq!(reason(response), "unpaired");
        let posing = Hello { device: Device { id: "device-there".into(), ..asker() }, ..Hello::default() };
        let refused = post(&client(&here, Some(&there)), &format!("{base}/sync"), &posing);
        assert!(matches!(refused, Err(ureq::Error::Status(403, _))), "a paired device cannot pass for another");
        let elsewhere = post(&client(&here, Some(&stranger)), &format!("{base}/sync"), &hello);
        assert!(
            matches!(elsewhere, Err(ureq::Error::Transport(_))),
            "a device with another certificate is not trusted"
        );
        assert!(take().0.is_empty());
        assert!(state().ledger.circle.is_some(), "a refusal does not leave the circle");
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here), fs::remove_dir_all(stranger));
    }

    #[test]
    fn a_paired_device_that_syncs_is_remembered_at_its_tailscale_addresses() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (there, here) = (library("tailscale"), library("tailscale-here"));
        paired(&there, &[("device-there", &there), ("device-here", &here)]);
        let address = started(&there, 47937);
        let on_tailscale = Device {
            port: 47823,
            tailscale: vec!["100.101.102.103".parse().unwrap(), "fd7a:115c:a1e0::5".parse().unwrap()],
            ..asker()
        };
        let hello = Hello { device: on_tailscale, ..Hello::default() };
        post(&client(&here, Some(&there)), &format!("https://{address}/listenook/sync"), &hello).unwrap();
        let known = ["100.101.102.103:47823", "[fd7a:115c:a1e0::5]:47823"];
        assert_eq!(state().ledger.seen["device-here"].tailscale, known);
        let saved: Ledger = serde_json::from_slice(&fs::read(there.join("sync.json")).unwrap()).unwrap();
        assert_eq!(saved.seen["device-here"].tailscale, known, "kept for the next time");
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here));
    }

    #[test]
    fn the_code_shown_here_pairs_the_device_that_asked_and_a_wrong_one_does_not() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (there, here, relay) = (library("pairing"), library("pairing-here"), library("pairing-relay"));
        let address = started(&there, 47933);
        let base = format!("https://{address}/listenook");
        take();
        let seen = ask_for_code(&base, &here).unwrap();
        assert_eq!(seen, fingerprint_of(&there));
        let code = shown_code();
        assert!(is_code(&code));
        let wrong = if code == "000000" { "111111" } else { "000000" };
        assert_eq!(try_code(&base, &here, &seen, wrong).err().as_deref(), Some("wrong"));
        assert!(state().ledger.circle.is_none());
        assert_eq!(
            try_code(&base, &relay, &seen, &code).err().as_deref(),
            Some("expired"),
            "only the device that asked can finish, even with the code"
        );

        let done = try_code(&base, &here, &seen, &code).unwrap();
        let circle = state().ledger.circle.clone().expect("a circle was made");
        assert!(circle.has("device-here") && circle.has("device-there"));
        assert_eq!(circle.members["device-here"].key, fingerprint_of(&here), "known by its certificate");
        assert_eq!(done.circle.members["device-there"].key, fingerprint_of(&there));
        let told =
            take().1.into_iter().any(|event| matches!(event, Event::Paired { name: Some(name), .. } if name == "Here"));
        assert!(told && is_mate("device-here"), "the pairing is told and remembered");
        let saved: Ledger = serde_json::from_slice(&fs::read(there.join("sync.json")).unwrap()).unwrap();
        assert_eq!(saved.circle, Some(circle));
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here), fs::remove_dir_all(relay));
    }

    #[test]
    fn asking_again_for_a_code_gives_no_new_guesses_at_it() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (there, here) = (library("pairing-guesses"), library("pairing-guesses-here"));
        let address = started(&there, 47935);
        let base = format!("https://{address}/listenook");
        take();
        let wrong = |code: &str| if code == "000000" { "111111" } else { "000000" }.to_owned();

        let seen = ask_for_code(&base, &here).unwrap();
        let first = shown_code();
        assert_eq!(try_code(&base, &here, &seen, &wrong(&first)).err().as_deref(), Some("wrong"));
        assert_eq!(try_code(&base, &here, &seen, &wrong(&first)).err().as_deref(), Some("wrong"));
        ask_for_code(&base, &here).unwrap();
        let again = shown_code();
        let third = try_code(&base, &here, &seen, &wrong(&again)).err();
        assert_eq!(third.as_deref(), Some("wait"), "a new code does not start the guesses again");
        assert_eq!(try_code(&base, &here, &seen, &again).err().as_deref(), Some("expired"), "the code shown is spent");
        let refused = ask_for_code(&base, &here);
        assert!(matches!(refused, Err(ureq::Error::Status(429, _))), "no code is shown while pairing waits");
        assert!(state().ledger.circle.is_none());

        state().misses = Misses::default();
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here));
    }

    #[test]
    fn a_device_that_leaves_is_forgotten_by_the_others() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (there, here, stranger) = (library("leaving"), library("leaving-here"), library("leaving-stranger"));
        paired(&there, &[("device-there", &there), ("device-here", &here)]);
        let address = started(&there, 47934);
        let base = format!("https://{address}/listenook");
        assert!(is_mate("device-here"));
        let forged = client(&stranger, Some(&there)).post(&format!("{base}/leave")).send_bytes(b"{}");
        assert!(matches!(forged, Err(ureq::Error::Status(403, _))));
        assert!(is_mate("device-here"), "only a device of the circle can say it leaves");
        client(&here, Some(&there)).post(&format!("{base}/leave")).send_bytes(b"{}").unwrap();
        assert!(!is_mate("device-here"));
        assert!(mates().is_empty());
        let back =
            post(&client(&here, Some(&there)), &format!("{base}/sync"), &Hello { device: asker(), ..Hello::default() });
        assert!(matches!(back, Err(ureq::Error::Status(403, _))), "a device that left cannot sync again");
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here), fs::remove_dir_all(stranger));
    }

    #[test]
    fn a_sync_stops_once_sync_is_set_up_again_and_leaves_the_next_one_alone() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let root = library("set-up-again");
        started(&root, 47936);
        let progress = Progress::default();
        progress.turn.store(state().turn, Ordering::Relaxed);
        state().starting = Some(1);
        let seen =
            Peer { device: Device { id: "other".into(), ..Device::default() }, address: ([127, 0, 0, 1], 9).into() };
        state().peers.insert("other".into(), (seen, Instant::now()));
        assert!(!progress.halted(), "a sync of this set-up goes on");
        configure(None, String::new(), String::new(), false);
        assert!(progress.halted(), "turning sync off ends it");
        assert_eq!(state().starting, None, "and what it marked as running");
        assert!(state().peers.is_empty(), "and the devices it saw, found again by the next");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn media_over_500_mb_waits_for_a_sync_started_by_hand() {
        let transfer = |id: &str, manifest: bool, size: u64| Transfer {
            id: id.into(),
            manifest,
            media: true,
            media_name: "talk.m4a".into(),
            media_size: size,
        };
        let mut plan = listenook_core::sync::Plan {
            pull: vec![transfer("small", true, 10), transfer("large-new", true, LARGE_MEDIA + 1)],
            push: vec![transfer("large-media-only", false, LARGE_MEDIA + 1)],
        };
        assert_eq!(leave_large_media(&mut plan), 2, "the recordings whose media was left are counted");
        assert!(plan.pull[0].media, "small media still goes");
        assert!(plan.pull[1].manifest && !plan.pull[1].media, "the transcript goes without the large media");
        assert!(plan.push.is_empty(), "nothing is left to send for large media alone");
    }

    #[test]
    fn a_change_here_wakes_the_wait_for_news_at_once() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        take();
        let seen = persist::generation();
        let changing = thread::spawn(|| {
            thread::sleep(Duration::from_millis(100));
            persist::changed();
        });
        let started = Instant::now();
        wait(Duration::from_secs(10), seen);
        changing.join().unwrap();
        assert!(started.elapsed() < Duration::from_secs(5), "woken after {:?}", started.elapsed());
        let started = Instant::now();
        wait(Duration::from_secs(10), seen);
        assert!(started.elapsed() < Duration::from_millis(100), "a change already made is not waited for");
    }

    #[test]
    fn media_over_500_mb_waits_over_tailscale_unless_asked_for() {
        let (home, away): (SocketAddr, SocketAddr) =
            ("192.168.1.20:47823".parse().unwrap(), "100.101.102.103:47823".parse().unwrap());
        let away_v6: SocketAddr = "[fd7a:115c:a1e0::1]:47823".parse().unwrap();
        assert!(Large::Left.leaves(home) && Large::Left.leaves(away), "a sync on its own never copies it");
        assert!(!Large::Nearby.leaves(home), "a sync by hand on the same network copies it");
        assert!(Large::Nearby.leaves(away) && Large::Nearby.leaves(away_v6), "over Tailscale it waits");
        assert!(!Large::All.leaves(away), "unless it was asked for");
    }

    #[test]
    fn only_local_and_tailscale_addresses_are_answered() {
        let answered = |address: &str, on_tailscale: bool| is_local(address.parse().unwrap(), || on_tailscale);
        assert!(answered("192.168.1.4", false));
        assert!(answered("127.0.0.1", false));
        assert!(answered("fe80::1", false));
        assert!(answered("::ffff:10.0.0.2", false));
        assert!(!answered("8.8.8.8", true));
        assert!(!answered("2001:4860:4860::8888", true));
        assert!(answered("100.101.102.103", true), "Tailscale, while this device is on it");
        assert!(answered("100.64.0.1", true) && answered("100.127.255.254", true));
        assert!(answered("::ffff:100.101.102.103", true));
        assert!(!answered("100.101.102.103", false), "a carrier's, while this device is not on Tailscale");
        assert!(!answered("100.128.0.1", true) && !answered("100.63.255.255", true), "outside 100.64.0.0/10");
        assert!(answered("fd7a:115c:a1e0::1", false), "Tailscale's IPv6 range is a local one");
    }

    #[test]
    fn tailscale_addresses_are_told_from_a_carriers() {
        let ip = |text: &str| -> IpAddr { text.parse().unwrap() };
        assert!(is_tailscale(ip("100.64.0.1")) && is_tailscale(ip("fd7a:115c:a1e0:ab12::1")));
        assert!(!is_tailscale(ip("192.168.1.20")) && !is_tailscale(ip("fd7a:115c:a1e1::1")));
        let interfaces = |list: &[(&str, &str)]| {
            tailscale_of(
                list.iter().map(|(name, address)| ((*name).to_owned(), ip(address))).collect::<Vec<_>>().into_iter(),
            )
        };
        let phone = [
            ("pdp_ip0", "100.70.1.2"),
            ("en0", "192.168.1.20"),
            ("utun4", "fd7a:115c:a1e0::5"),
            ("utun4", "100.101.102.103"),
        ];
        assert_eq!(interfaces(&phone), [ip("100.101.102.103"), ip("fd7a:115c:a1e0::5")], "IPv4 first, no carrier's");
        let no_ipv6 = [("en0", "192.168.1.20"), ("tailscale0", "100.101.102.103")];
        assert_eq!(interfaces(&no_ipv6), [ip("100.101.102.103")]);
        assert!(interfaces(&[("en0", "192.168.1.20")]).is_empty());
    }

    #[test]
    fn an_address_typed_is_found_with_or_without_a_port() {
        let at = |text: &str| -> Vec<String> { places_at(text).iter().map(ToString::to_string).collect() };
        assert_eq!(at(" 192.168.1.20 "), ["192.168.1.20:47823"]);
        assert_eq!(at("http://100.101.102.103:5000/"), ["100.101.102.103:5000"]);
        assert_eq!(at("fd7a:115c:a1e0::1"), ["[fd7a:115c:a1e0::1]:47823"]);
        assert_eq!(at("[fd7a:115c:a1e0::1]"), ["[fd7a:115c:a1e0::1]:47823"]);
        assert_eq!(at("[fd7a:115c:a1e0::1]:5000"), ["[fd7a:115c:a1e0::1]:5000"]);
        let named = at("localhost");
        assert!(!named.is_empty() && named.iter().all(|place| place.ends_with(":47823")), "{named:?}");
        assert!(places_at("localhost")[0].is_ipv4(), "IPv4 is tried first: {named:?}");
    }

    #[test]
    fn a_paired_device_is_sought_on_the_local_network_then_on_tailscale() {
        let device = Device {
            port: 47823,
            tailscale: vec!["100.101.102.103".parse().unwrap(), "fd7a:115c:a1e0::5".parse().unwrap()],
            ..asker()
        };
        let mut seen = Seen { address: "192.168.1.20:47823".into(), ..Seen::default() };
        assert!(seen.learn(&device) && !seen.learn(&device), "learned once");
        seen.reached("100.101.102.103:47823".parse().unwrap());
        assert_eq!(seen.address, "192.168.1.20:47823", "reaching it on Tailscale keeps its local address");
        seen.reached("10.0.0.7:47823".parse().unwrap());
        let places: Vec<String> = seen.places().map(|place| place.to_string()).collect();
        assert_eq!(places, ["10.0.0.7:47823", "100.101.102.103:47823", "[fd7a:115c:a1e0::5]:47823"]);
        assert!(!seen.learn(&Device { tailscale: Vec::new(), ..device }), "none given keeps those known");
        assert_eq!(seen.tailscale.len(), 2);

        let older: Seen = serde_json::from_str(r#"{"address":"192.168.1.20:47823","synced_at":"x"}"#).unwrap();
        assert_eq!(older.places().count(), 1, "a ledger from before reads as it was");
        let mut state = State::default();
        state.ledger.seen.insert("mate".into(), seen);
        let live = Peer { device: asker(), address: "100.101.102.103:47823".parse().unwrap() };
        state.peers.insert("mate".into(), (live, Instant::now()));
        let places: Vec<String> = state.places("mate").iter().map(ToString::to_string).collect();
        assert_eq!(places, ["10.0.0.7:47823", "100.101.102.103:47823", "[fd7a:115c:a1e0::5]:47823"]);
    }

    #[test]
    fn turning_sync_off_frees_its_ports_at_once() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let root = library("off");
        started(&root, 47941);
        let on_ipv6 = ask(SocketAddr::from((Ipv6Addr::LOCALHOST, 47941)));
        assert_eq!(on_ipv6.expect("the device answers on IPv6 too").name, "There");
        configure(None, String::new(), String::new(), false);
        let freed = (0..20).any(|_| {
            thread::sleep(Duration::from_millis(50));
            TcpListener::bind((Ipv4Addr::UNSPECIFIED, 47941)).is_ok() && listen_v6(47941).is_ok()
        });
        assert!(freed);
        let _ = fs::remove_dir_all(root);
    }
}
