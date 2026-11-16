use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write},
    net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket},
    path::{Path, PathBuf},
    sync::{
        Condvar, Mutex, MutexGuard, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use listenook_core::{
    Job, LibraryCatalog, now_iso,
    sync::{
        Circle, Device, Entry, Index, Member, Members, Offer, PROTOCOL, Podcasts, Shelves, Transfer, digest, hex,
        is_code, is_sync_name, joins_answerer, media_extension, media_file_name, merge_members, pairing_secret,
        plan_with, proof, same, seal, unhex,
    },
};
use ring::{
    agreement,
    rand::{SecureRandom, SystemRandom},
};
use serde::{Deserialize, Serialize};

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
const CHALLENGE_WITHIN: Duration = Duration::from_secs(60);
const REPLIES_WITHIN: Duration = Duration::from_millis(1500);
const MANIFEST_LIMIT: u64 = 256 * 1024 * 1024;
pub(crate) const LARGE_MEDIA: u64 = 500 * 1024 * 1024;

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
    address: String,
    synced_at: String,
    mine: String,
    theirs: String,
}

struct Pairing {
    serial: u64,
    device: Device,
    code: String,
    nonce: String,
    theirs: String,
    shared: String,
    offer: Option<Offer>,
    attempts: u32,
    at: Instant,
}

#[derive(Clone)]
struct Asking {
    address: SocketAddr,
    device: Device,
    nonce: String,
    theirs: String,
    shared: String,
    offer: Option<Offer>,
}

struct Resumable {
    device: String,
    busy: HashSet<String>,
    at: Instant,
}

struct Session {
    token: String,
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
    starting: bool,
    serial: u64,
    incoming: Vec<Incoming>,
    events: Vec<Event>,
    announcer: Option<UdpSocket>,
    serving_on: Option<u16>,
    ledger: Ledger,
    pairing: Option<Pairing>,
    asking: Option<Asking>,
    challenges: Vec<(String, Instant)>,
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
        seen.address = address.to_string();
        if let Some((mine, theirs)) = revisions {
            seen.synced_at = now_iso();
            (seen.mine, seen.theirs) = (mine, theirs);
        }
        self.save();
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

fn key_pair() -> Option<(agreement::EphemeralPrivateKey, String)> {
    let private = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &SystemRandom::new()).ok()?;
    let public = hex(private.compute_public_key().ok()?.as_ref());
    Some((private, public))
}

fn agree(private: agreement::EphemeralPrivateKey, public: &str) -> Option<String> {
    let public = agreement::UnparsedPublicKey::new(&agreement::X25519, unhex(public)?);
    agreement::agree_ephemeral(private, &public, hex).ok()
}

fn new_circle() -> Circle {
    Circle { id: random_hex(8), key: random_hex(32), members: Members::new() }
}

fn join(circle: &mut Circle, devices: [&Device; 2]) {
    let at = now_iso();
    for device in devices {
        let member = Member {
            name: device.name.clone(),
            platform: device.platform.clone(),
            joined_at: at.clone(),
            removed_at: None,
        };
        circle.members.insert(device.id.clone(), member);
    }
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
    let turn = state.turn;
    drop(state);
    if was_visible {
        thread::spawn(move || wake(serving_on));
    }
    if visible {
        thread::spawn(move || serve(turn));
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
    member.removed_at = Some(now_iso());
    state.ledger.seen.remove(id);
    state.save();
}

pub(crate) fn leave() {
    let (circle, me, places) = {
        let mut state = state();
        let Some(circle) = state.ledger.circle.clone() else {
            return;
        };
        let places: Vec<SocketAddr> = circle
            .members
            .keys()
            .filter(|id| **id != state.me.id)
            .filter_map(|id| {
                state
                    .peers
                    .get(id)
                    .map(|(peer, _)| peer.address)
                    .or_else(|| state.ledger.seen.get(id).and_then(|seen| seen.address.parse().ok()))
            })
            .collect();
        let me = state.me.id.clone();
        state.leave();
        (circle, me, places)
    };
    for address in places {
        let (key, me) = (circle.key.clone(), me.clone());
        thread::spawn(move || {
            let base = format!("http://{address}/listenook");
            let Some(challenge) = ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(3))
                .build()
                .get(&format!("{base}/challenge"))
                .call()
                .ok()
                .and_then(|response| serde_json::from_reader::<_, Challenge>(response.into_reader().take(4096)).ok())
            else {
                return;
            };
            let leaving =
                Leaving { proof: proof(&key, &challenge.nonce, &me, "leave"), id: me, nonce: challenge.nonce };
            if let Ok(body) = serde_json::to_vec(&leaving) {
                let _ = agent(Duration::from_secs(3)).post(&format!("{base}/leave")).send_bytes(&body);
            }
        });
    }
}

fn take_challenge(state: &mut State, nonce: &str) -> bool {
    state.challenges.retain(|(_, at)| at.elapsed() < CHALLENGE_WITHIN);
    let asked = state.challenges.iter().position(|(known, _)| !nonce.is_empty() && known == nonce);
    asked.map(|at| state.challenges.remove(at)).is_some()
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
        let _ = TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, port)), Duration::from_millis(500));
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

fn agent(read: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(4))
        .timeout_read(read)
        .timeout_write(Duration::from_secs(60))
        .build()
}

fn ask_within(address: SocketAddr, within: Duration) -> Option<Device> {
    let response = ureq::AgentBuilder::new()
        .timeout_connect(within)
        .timeout_read(Duration::from_secs(10))
        .build()
        .get(&format!("http://{address}/listenook/info"))
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
    let text = text.trim().trim_start_matches("http://").trim_end_matches('/');
    let with_port = if text.rsplit_once(':').is_some_and(|(_, port)| port.parse::<u16>().is_ok()) {
        text.to_owned()
    } else {
        format!("{text}:{PORT}")
    };
    let address = with_port.to_socket_addrs().ok()?.find(SocketAddr::is_ipv4)?;
    let device = ask(address)?;
    remember(device.clone(), address);
    Some(Peer { device, address })
}

fn is_local(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_private() || v4.is_loopback() || v4.is_link_local())
                || (v6.segments()[0] & 0xfe00) == 0xfc00
                || (v6.segments()[0] & 0xffc0) == 0xfe80
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
        if is_local(from.ip()) {
            thread::spawn(move || {
                if let Err(error) = handle(stream, from.ip()) {
                    log::debug!("sync: {error}");
                }
            });
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
    body: BufReader<TcpStream>,
}

fn read_call(stream: TcpStream, from: IpAddr) -> io::Result<Call> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    let mut body = BufReader::new(stream);
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
    Ok(Call { method, path, length, token, progress, offset, from, body })
}

fn reply(stream: &mut TcpStream, status: u16, body: &[u8]) -> io::Result<()> {
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

fn reply_json(stream: &mut TcpStream, value: &impl Serialize) -> io::Result<()> {
    reply(stream, 200, &serde_json::to_vec(value).map_err(io::Error::other)?)
}

fn refuse(stream: &mut TcpStream, reason: &str) -> io::Result<()> {
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
    nonce: String,
    proof: String,
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
    proof: String,
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
struct Challenge {
    nonce: String,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Leaving {
    id: String,
    nonce: String,
    proof: String,
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
    nonce: String,
    public: String,
    circle: Option<Offer>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairAnswer {
    device: Device,
    nonce: String,
    public: String,
    circle: Option<Offer>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Sealed {
    id: String,
    key: String,
    members: Members,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairConfirm {
    id: String,
    proof: String,
    circle: Option<Sealed>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct PairDone {
    proof: String,
    circle: Option<Sealed>,
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
    let mut out = stream.try_clone()?;
    let mut call = read_call(stream, from)?;
    let token = call.token.clone();
    let progress = call.progress;
    let counted = in_session(&token, |session| {
        session.calls += 1;
        if let Some((items, items_total, bytes_total)) = progress {
            (session.items, session.items_total, session.bytes_total) = (items, items_total, bytes_total);
        }
    });
    let result = route(&mut out, &mut call);
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

fn route(out: &mut TcpStream, call: &mut Call) -> io::Result<()> {
    let (root, me) = {
        let state = state();
        (state.root.clone(), state.me.clone())
    };
    let Some(root) = root else {
        return reply(out, 404, b"{}");
    };
    let path = call.path.clone();
    let parts: Vec<&str> = path.trim_start_matches("/listenook/").split('/').collect();
    if !path.starts_with("/listenook/") {
        return reply(out, 404, b"{}");
    }
    let method = call.method.clone();
    match (method.as_str(), parts.as_slice()) {
        ("GET", ["info"]) => reply_json(out, &Device { revision: library(&root).1, ..me }),
        ("GET", ["challenge"]) => {
            let nonce = random_hex(16);
            let mut state = state();
            state.challenges.retain(|(_, at)| at.elapsed() < CHALLENGE_WITHIN);
            if state.challenges.len() >= 64 {
                state.challenges.remove(0);
            }
            state.challenges.push((nonce.clone(), Instant::now()));
            drop(state);
            reply_json(out, &Challenge { nonce })
        }
        ("POST", ["pair"]) => {
            let asked: PairAsk = serde_json::from_slice(&read_body(call, 256 * 1024)?)?;
            answer_pairing(out, me, asked)
        }
        ("POST", ["pair", "confirm"]) => {
            let confirm: PairConfirm = serde_json::from_slice(&read_body(call, 4 * 1024 * 1024)?)?;
            confirm_pairing(out, me, confirm)
        }
        ("POST", ["pair", "cancel", id]) => {
            let mut state = state();
            if let Some(pairing) = state.pairing.take_if(|pairing| pairing.device.id == *id) {
                state.tell(Event::Paired { serial: pairing.serial, name: None });
            }
            drop(state);
            reply(out, 200, b"{}")
        }
        ("POST", ["leave"]) => {
            let leaving: Leaving = serde_json::from_slice(&read_body(call, 64 * 1024)?)?;
            let mut state = state();
            let fresh = take_challenge(&mut state, &leaving.nonce);
            let member = state.ledger.circle.as_mut().filter(|circle| {
                fresh && same(&leaving.proof, &proof(&circle.key, &leaving.nonce, &leaving.id, "leave"))
            });
            let Some(member) = member.and_then(|circle| circle.members.get_mut(&leaving.id)) else {
                drop(state);
                return refuse(out, "unpaired");
            };
            member.removed_at = Some(now_iso());
            state.ledger.seen.remove(&leaving.id);
            state.save();
            drop(state);
            reply(out, 200, b"{}")
        }
        ("POST", ["sync"]) => {
            let hello: Hello = serde_json::from_slice(&read_body(call, 4 * 1024 * 1024)?)?;
            welcome(out, &root, me, hello, call.from)
        }
        _ if !in_session(&call.token, |_| {}) => {
            let ended = !call.token.is_empty() && state().stopped.as_deref() == Some(call.token.as_str());
            reply(out, if ended { 403 } else { 410 }, b"{}")
        }
        ("POST", ["done"]) => {
            let done: Done = serde_json::from_slice(&read_body(call, 64 * 1024)?).unwrap_or_default();
            end_session(&mut state(), done.complete, false);
            reply(out, 200, b"{}")
        }
        (_, [_, id, ..]) if !Job::is_valid_id(id) => reply(out, 400, b"{}"),
        ("GET", ["manifest", id]) => match fs::read(manifest_path(&root, id)) {
            Ok(bytes) => {
                in_session(&call.token, |session| session.sent += 1);
                reply(out, 200, &bytes)
            }
            Err(_) => reply(out, 404, b"{}"),
        },
        ("PUT", ["manifest", id]) => {
            let job: Job = serde_json::from_slice(&read_body(call, MANIFEST_LIMIT)?)?;
            if job.id != *id {
                return reply(out, 400, b"{}");
            }
            let mut state = state();
            state.hand(Incoming::Job(Box::new(job)));
            if let Some(session) = &mut state.session {
                session.received += 1;
            }
            drop(state);
            reply(out, 200, b"{}")
        }
        ("GET", ["media", id]) => {
            let source = persist::load_job(&root, id).and_then(|job| media_of(&root, &job));
            let Some(mut file) = source.and_then(|path| fs::File::open(path).ok()) else {
                return reply(out, 404, b"{}");
            };
            let length = file.metadata()?.len();
            let offset = if call.offset < length { call.offset } else { 0 };
            file.seek(SeekFrom::Start(offset))?;
            let resumed = if offset > 0 { format!("X-Listenook-Offset: {offset}\r\n") } else { String::new() };
            write!(
                out,
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\n{resumed}Connection: close\r\n\r\n",
                length - offset
            )?;
            let token = call.token.clone();
            in_session(&token, |session| session.bytes += offset);
            copy(&mut file, out, length - offset, |count| in_session(&token, |session| session.bytes += count))?;
            out.flush()
        }
        ("GET", ["part", id, extension]) => {
            let path = root.join("media").join(media_file_name(id, &format!("x.{extension}")));
            let size = fs::metadata(path.with_extension("part")).map(|file| file.len()).unwrap_or(0);
            reply_json(out, &Part { size })
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
            reply(out, 200, b"{}")
        }
        _ => reply(out, 404, b"{}"),
    }
}

fn answer_pairing(out: &mut TcpStream, me: Device, asked: PairAsk) -> io::Result<()> {
    if asked.device.app != "listenook" || asked.device.id.is_empty() || asked.device.id == me.id {
        return reply(out, 400, b"{}");
    }
    if asked.device.protocol != PROTOCOL {
        return reply(out, 426, b"{}");
    }
    let Some((private, public)) = key_pair() else {
        return reply(out, 400, b"{}");
    };
    let Some(shared) = agree(private, &asked.public).filter(|_| !asked.nonce.is_empty()) else {
        return reply(out, 400, b"{}");
    };
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
    let (code, nonce) = (new_code(), random_hex(16));
    let circle = state.ledger.circle.as_ref().map(Circle::offer);
    state.pairing = Some(Pairing {
        serial,
        device: asked.device.clone(),
        code: code.clone(),
        nonce: nonce.clone(),
        theirs: asked.nonce,
        shared,
        offer: asked.circle,
        attempts: 0,
        at: Instant::now(),
    });
    state.tell(Event::Pairing { serial, device: asked.device, code });
    drop(state);
    reply_json(out, &PairAnswer { device: me, nonce, public, circle })
}

fn confirm_pairing(out: &mut TcpStream, me: Device, confirm: PairConfirm) -> io::Result<()> {
    let mut state = state();
    let Some(pairing) =
        state.pairing.as_mut().filter(|pairing| pairing.device.id == confirm.id && pairing.at.elapsed() < PAIR_WITHIN)
    else {
        drop(state);
        return refuse(out, "expired");
    };
    let secret =
        pairing_secret(&pairing.code, &pairing.shared, (&pairing.device.id, &pairing.theirs), (&me.id, &pairing.nonce));
    if !same(&confirm.proof, &proof(&secret, "", &pairing.device.id, "asker")) {
        pairing.attempts += 1;
        let attempts = pairing.attempts;
        state.misses.miss();
        let waiting = state.misses.waiting();
        let spent = attempts >= PAIR_ATTEMPTS || waiting;
        if spent && let Some(pairing) = state.pairing.take() {
            state.tell(Event::Paired { serial: pairing.serial, name: None });
        }
        drop(state);
        return refuse(
            out,
            if waiting {
                "wait"
            } else if spent {
                "expired"
            } else {
                "wrong"
            },
        );
    }
    let Some(pairing) = state.pairing.take() else {
        return refuse(out, "expired");
    };
    state.misses = Misses::default();
    let mine = state.ledger.circle.as_ref().map(Circle::offer);
    let sealed = if joins_answerer(pairing.offer.as_ref(), mine.as_ref()) {
        let circle = state.ledger.circle.get_or_insert_with(new_circle);
        join(circle, [&me, &pairing.device]);
        seal(&circle.key, &secret, "answerer circle").map(|key| Sealed {
            id: circle.id.clone(),
            key,
            members: circle.members.clone(),
        })
    } else {
        let theirs = confirm.circle.and_then(|sealed| {
            let key = seal(&sealed.key, &secret, "asker circle")?;
            Some(Circle { id: sealed.id, key, members: sealed.members })
        });
        let Some(mut circle) = theirs else {
            state.tell(Event::Paired { serial: pairing.serial, name: None });
            drop(state);
            return reply(out, 400, b"{}");
        };
        join(&mut circle, [&me, &pairing.device]);
        state.adopt(circle);
        None
    };
    state.save();
    state.tell(Event::Paired { serial: pairing.serial, name: Some(pairing.device.name.clone()) });
    drop(state);
    reply_json(out, &PairDone { proof: proof(&secret, "", &me.id, "answerer"), circle: sealed })
}

pub(crate) fn pair(address: SocketAddr) -> Result<Device, &'static str> {
    let (me, offer) = {
        let state = state();
        (state.me.clone(), state.ledger.circle.as_ref().map(Circle::offer))
    };
    if me.id.is_empty() {
        return Err("sync_failed");
    }
    let (private, public) = key_pair().ok_or("sync_failed")?;
    let nonce = random_hex(16);
    let asked = PairAsk { device: me, nonce: nonce.clone(), public, circle: offer };
    let answer: PairAnswer = agent(Duration::from_secs(10))
        .post(&format!("http://{address}/listenook/pair"))
        .send_bytes(&serde_json::to_vec(&asked).map_err(|_| "sync_failed")?)
        .map_err(code_of)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(256 * 1024)).map_err(|_| "sync_failed")
        })?;
    if !answer.device.is_compatible() {
        return Err("sync_incompatible");
    }
    let shared = agree(private, &answer.public).ok_or("sync_failed")?;
    remember(answer.device.clone(), address);
    state().asking = Some(Asking {
        address,
        device: answer.device.clone(),
        nonce,
        theirs: answer.nonce,
        shared,
        offer: answer.circle,
    });
    Ok(answer.device)
}

pub(crate) fn confirm(code: &str) -> Result<(), &'static str> {
    let code: String = code.chars().filter(char::is_ascii_digit).collect();
    if !is_code(&code) {
        return Err("sync_wrong_code");
    }
    let (asking, me, circle) = {
        let state = state();
        (state.asking.clone().ok_or("sync_code_expired")?, state.me.clone(), state.ledger.circle.clone())
    };
    let secret = pairing_secret(&code, &asking.shared, (&me.id, &asking.nonce), (&asking.device.id, &asking.theirs));
    let joins = joins_answerer(circle.as_ref().map(Circle::offer).as_ref(), asking.offer.as_ref());
    let sealed = match (&circle, joins) {
        (Some(circle), false) => Some(Sealed {
            id: circle.id.clone(),
            key: seal(&circle.key, &secret, "asker circle").ok_or("sync_failed")?,
            members: circle.members.clone(),
        }),
        _ => None,
    };
    let confirmed = PairConfirm { id: me.id.clone(), proof: proof(&secret, "", &me.id, "asker"), circle: sealed };
    let done = agent(Duration::from_secs(10))
        .post(&format!("http://{}/listenook/pair/confirm", asking.address))
        .send_bytes(&serde_json::to_vec(&confirmed).map_err(|_| "sync_failed")?);
    let done: PairDone = match done {
        Ok(response) => {
            serde_json::from_reader(response.into_reader().take(4 * 1024 * 1024)).map_err(|_| "sync_failed")?
        }
        Err(ureq::Error::Status(403, response)) => {
            let reason = reason(response);
            if reason == "wrong" {
                return Err("sync_wrong_code");
            }
            state().asking = None;
            return Err(if reason == "wait" { "sync_pair_wait" } else { "sync_code_expired" });
        }
        Err(ureq::Error::Status(404 | 410, _)) => {
            state().asking = None;
            return Err("sync_code_expired");
        }
        Err(error) => return Err(code_of(error)),
    };
    let mut state = state();
    state.asking = None;
    if !same(&done.proof, &proof(&secret, "", &asking.device.id, "answerer")) {
        return Err("sync_failed");
    }
    let mut circle = if joins {
        let sealed = done.circle.ok_or("sync_failed")?;
        let key = seal(&sealed.key, &secret, "answerer circle").ok_or("sync_failed")?;
        Circle { id: sealed.id, key, members: sealed.members }
    } else {
        circle.ok_or("sync_failed")?
    };
    join(&mut circle, [&me, &asking.device]);
    state.adopt(circle);
    state.saw(&asking.device.id, asking.address, None);
    Ok(())
}

pub(crate) fn abandon() {
    let (asking, id) = {
        let mut state = state();
        (state.asking.take(), state.me.id.clone())
    };
    if let Some(asking) = asking {
        thread::spawn(move || {
            let _ = agent(Duration::from_secs(3))
                .post(&format!("http://{}/listenook/pair/cancel/{id}", asking.address))
                .call();
        });
    }
}

fn reason(response: ureq::Response) -> String {
    serde_json::from_reader::<_, Refusal>(response.into_reader().take(4096))
        .map(|refusal| refusal.reason)
        .unwrap_or_default()
}

fn welcome(out: &mut TcpStream, root: &Path, me: Device, hello: Hello, from: IpAddr) -> io::Result<()> {
    if hello.device.app != "listenook" || hello.device.id.is_empty() {
        return reply(out, 400, b"{}");
    }
    if hello.device.protocol != PROTOCOL {
        return reply(out, 426, b"{}");
    }
    let id = hello.device.id.clone();
    let trusted = {
        let mut state = state();
        let fresh = take_challenge(&mut state, &hello.nonce);
        let Some(circle) = state
            .ledger
            .circle
            .as_mut()
            .filter(|circle| fresh && same(&hello.proof, &proof(&circle.key, &hello.nonce, &id, "hello")))
        else {
            drop(state);
            return refuse(out, "unpaired");
        };
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
            Ok((circle.key.clone(), circle.members.clone()))
        };
        match verdict {
            Err("unpaired") => state.leave(),
            _ if changed => state.save(),
            _ => {}
        }
        verdict
    };
    let (key, members) = match trusted {
        Ok(trusted) => trusted,
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
        if state.starting || (state.session.is_some() && !same_device) {
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
        open_session(&mut state, &hello, &token, busy.clone(), counts, (address, revision.clone()));
        busy
    };
    let (index, _) = index_of(root, &busy);
    in_session(&token, |_| {});
    let sent = reply_json(
        out,
        &Welcome {
            token: token.clone(),
            proof: proof(&key, &hello.nonce, &me.id, "welcome"),
            device: me,
            index,
            revision,
            members,
        },
    );
    if sent.is_err() {
        in_session(&token, |session| session.broken = Some(Instant::now()));
    }
    sent
}

fn open_session(
    state: &mut State,
    hello: &Hello,
    token: &str,
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

pub(crate) fn round(busy: &HashSet<String>, force: bool) -> u32 {
    let root = {
        let state = state();
        match &state.root {
            Some(root) if state.visible && state.ledger.circle.is_some() => root.clone(),
            _ => return 0,
        }
    };
    let mut mates = mates();
    mates.sort_by(|a, b| a.synced_at.cmp(&b.synced_at));
    let mut looked = false;
    let mut synced = 0;
    for mate in mates {
        let Some((address, device)) = reach(&mate.id, &mut looked) else {
            continue;
        };
        let seen = state().ledger.seen.get(&mate.id).cloned().unwrap_or_default();
        let (_, mine) = library(&root);
        if !force && !device.revision.is_empty() && seen.mine == mine && seen.theirs == device.revision {
            continue;
        }
        match sync_with(address, busy.clone(), &Progress::default(), true, force) {
            Ok(_) => synced += 1,
            Err(code) => log::debug!("sync: with {}: {code}", mate.name),
        }
    }
    synced
}

fn reach(id: &str, looked: &mut bool) -> Option<(SocketAddr, Device)> {
    loop {
        let places: Vec<SocketAddr> = {
            let state = state();
            let mut places: Vec<SocketAddr> = state.peers.get(id).map(|(peer, _)| peer.address).into_iter().collect();
            if let Some(known) = state.ledger.seen.get(id).and_then(|seen| seen.address.parse().ok())
                && !places.contains(&known)
            {
                places.push(known);
            }
            places
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
    busy: HashSet<String>,
    progress: &Progress,
    auto: bool,
    whole: bool,
) -> Result<Summary, &'static str> {
    let (root, me) = {
        let mut state = state();
        if state.session.is_some() || state.starting {
            return Err("sync_peer_busy");
        }
        state.starting = true;
        (state.root.clone(), state.me.clone())
    };
    let result = match root {
        Some(root) => persist_with(address, &root, &me, &busy, progress, (auto, whole)),
        None => Err("sync_failed"),
    };
    progress.waiting.store(false, Ordering::Relaxed);
    state().starting = false;
    result
}

fn persist_with(
    address: SocketAddr,
    root: &Path,
    me: &Device,
    busy: &HashSet<String>,
    progress: &Progress,
    (auto, whole): (bool, bool),
) -> Result<Summary, &'static str> {
    let mut summary = Summary::default();
    let mut lost: Option<Instant> = None;
    loop {
        let again = lost.is_some();
        let code = match exchange(address, root, me.clone(), busy, progress, (again, auto, whole), &mut summary) {
            Ok(()) => return Ok(summary),
            Err(code) => code,
        };
        let stopped = || progress.stop.load(Ordering::Relaxed);
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

fn leave_large_media(plan: &mut listenook_core::sync::Plan) {
    for transfer in plan.pull.iter_mut().chain(plan.push.iter_mut()) {
        transfer.media &= transfer.media_size <= LARGE_MEDIA;
    }
    plan.pull.retain(|transfer| transfer.manifest || transfer.media);
    plan.push.retain(|transfer| transfer.manifest || transfer.media);
}

fn recoverable(code: &str) -> bool {
    matches!(code, "sync_interrupted" | "sync_unreachable")
}

fn exchange(
    address: SocketAddr,
    root: &Path,
    me: Device,
    busy: &HashSet<String>,
    progress: &Progress,
    (resume, auto, whole): (bool, bool, bool),
    summary: &mut Summary,
) -> Result<(), &'static str> {
    let base = format!("http://{address}/listenook");
    let circle = state().ledger.circle.clone().ok_or("sync_unpaired")?;
    let challenge: Challenge =
        agent(Duration::from_secs(10)).get(&format!("{base}/challenge")).call().map_err(code_of).and_then(
            |response| serde_json::from_reader(response.into_reader().take(4096)).map_err(|_| "sync_failed"),
        )?;
    let (local, revision) = index_of(root, busy);
    let hello = Hello {
        proof: proof(&circle.key, &challenge.nonce, &me.id, "hello"),
        nonce: challenge.nonce.clone(),
        device: me,
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
    if !same(&welcome.proof, &proof(&circle.key, &challenge.nonce, &welcome.device.id, "welcome")) {
        return Err("sync_unpaired");
    }
    {
        let mut state = state();
        let Some(mine) = state.ledger.circle.as_mut().filter(|mine| mine.id == circle.id) else {
            return Err("sync_unpaired");
        };
        merge_members(&mut mine.members, &welcome.members);
        let trusted = mine.has(&welcome.device.id);
        state.saw(&welcome.device.id, address, None);
        if !trusted {
            return Err("sync_unpaired");
        }
    }
    if progress.stop.load(Ordering::Relaxed) {
        return Err("sync_cancelled");
    }
    progress.accepted.store(true, Ordering::Relaxed);
    progress.waiting.store(false, Ordering::Relaxed);
    progress.items.store(0, Ordering::Relaxed);
    progress.bytes.store(0, Ordering::Relaxed);
    let http = agent(Duration::from_secs(30));
    let token = welcome.token.as_str();
    let mut plan = plan_with(&local.entries, &welcome.index.entries, &local.removed, &welcome.index.removed);
    if !whole {
        leave_large_media(&mut plan);
    }
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
        !progress.stop.load(Ordering::Relaxed)
    };
    let failed = |error: ureq::Error| match error {
        ureq::Error::Status(403, _) => "sync_cancelled_there",
        ureq::Error::Status(410, _) => "sync_interrupted",
        other => code_of(other),
    };
    let stopped = |_: io::Error| {
        if progress.stop.load(Ordering::Relaxed) { "sync_cancelled" } else { "sync_interrupted" }
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
            request.set("Content-Length", &(length - have).to_string()).send(&mut counted).map_err(|error| {
                if progress.stop.load(Ordering::Relaxed) { "sync_cancelled" } else { failed(error) }
            })?;
        }
        if transfer.manifest {
            let manifest = fs::read(manifest_path(root, id)).map_err(|_| "sync_failed")?;
            call(http.put(&format!("{base}/manifest/{id}"))).send_bytes(&manifest).map_err(failed)?;
        }
        Ok(())
    };

    let mut outcome = Ok(());
    for (transfer, pulling) in plan.pull.iter().map(|t| (t, true)).chain(plan.push.iter().map(|t| (t, false))) {
        if progress.stop.load(Ordering::Relaxed) {
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
    if matches!(outcome, Err(code) if recoverable(code)) && !progress.stop.load(Ordering::Relaxed) {
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

    fn paired(root: &Path, ids: &[&str]) -> Circle {
        let members = ids
            .iter()
            .map(|id| ((*id).to_owned(), Member { name: (*id).into(), joined_at: now_iso(), ..Member::default() }))
            .collect();
        let circle = Circle { id: "circle".into(), key: digest(&["key"]), members };
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

    #[allow(clippy::result_large_err)]
    fn post(url: &str, body: &impl Serialize) -> Result<ureq::Response, ureq::Error> {
        agent(Duration::from_secs(2)).post(url).send_bytes(&serde_json::to_vec(body).unwrap())
    }

    fn json<T: serde::de::DeserializeOwned>(response: ureq::Response) -> T {
        serde_json::from_reader(response.into_reader()).unwrap()
    }

    fn asker() -> Device {
        Device { app: "listenook".into(), protocol: PROTOCOL, id: "device-here".into(), ..Device::default() }
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
        paired(&there, &["device-there", "device-here"]);
        let address = started(&there, 47931);

        let progress = Progress::default();
        let mut summary = Summary::default();
        exchange(address, &here, asker(), &HashSet::new(), &progress, (false, true, true), &mut summary).unwrap();
        assert_eq!(summary, Summary { received: 2, sent: 2 });
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

        let refused = agent(Duration::from_secs(2)).get(&format!("http://{address}/listenook/manifest/both")).call();
        assert!(matches!(refused, Err(ureq::Error::Status(410, _))));
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here));
    }

    #[test]
    fn a_device_without_the_circles_key_is_refused_and_copies_nothing() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let there = library("refusing");
        recording(&there, "kept", "2026-01-01T00:00:00.000Z", None);
        paired(&there, &["device-there", "device-here"]);
        let address = started(&there, 47932);
        let base = format!("http://{address}/listenook");
        take();
        let challenge: Challenge =
            json(agent(Duration::from_secs(2)).get(&format!("{base}/challenge")).call().unwrap());
        let hello = Hello {
            device: asker(),
            nonce: challenge.nonce.clone(),
            proof: proof(&digest(&["another key"]), &challenge.nonce, "device-here", "hello"),
            ..Hello::default()
        };
        let refused = post(&format!("{base}/sync"), &hello);
        let Err(ureq::Error::Status(403, response)) = refused else {
            panic!("a wrong key is refused");
        };
        assert_eq!(reason(response), "unpaired");
        let replayed = Hello { proof: proof(&digest(&["key"]), &challenge.nonce, "device-here", "hello"), ..hello };
        let again = post(&format!("{base}/sync"), &replayed);
        assert!(matches!(again, Err(ureq::Error::Status(403, _))), "a challenge answers once");
        assert!(take().0.is_empty());
        assert!(state().ledger.circle.is_some(), "a refusal does not leave the circle");
        configure(None, String::new(), String::new(), false);
        let _ = fs::remove_dir_all(there);
    }

    #[test]
    fn the_code_shown_here_pairs_the_device_that_asked_and_a_wrong_one_does_not() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let there = library("pairing");
        let address = started(&there, 47933);
        let base = format!("http://{address}/listenook");
        take();
        let (private, public) = key_pair().unwrap();
        let asker = Device { name: "Here".into(), ..asker() };
        let asked = PairAsk { device: asker.clone(), nonce: "asker-nonce".into(), public, circle: None };
        let answer: PairAnswer = json(post(&format!("{base}/pair"), &asked).unwrap());
        let shared = agree(private, &answer.public).unwrap();
        let code = take()
            .1
            .into_iter()
            .find_map(|event| match event {
                Event::Pairing { code, device, .. } if device.id == "device-here" => Some(code),
                _ => None,
            })
            .expect("a code is shown");
        assert!(is_code(&code));
        let secret_of =
            |code: &str| pairing_secret(code, &shared, ("device-here", "asker-nonce"), ("device-there", &answer.nonce));
        let wrong = if code == "000000" { "111111" } else { "000000" };
        let guess = PairConfirm {
            id: "device-here".into(),
            proof: proof(&secret_of(wrong), "", "device-here", "asker"),
            circle: None,
        };
        let refused = post(&format!("{base}/pair/confirm"), &guess);
        let Err(ureq::Error::Status(403, response)) = refused else {
            panic!("a wrong code is refused");
        };
        assert_eq!(reason(response), "wrong");
        assert!(state().ledger.circle.is_none());

        let secret = secret_of(&code);
        let right =
            PairConfirm { id: "device-here".into(), proof: proof(&secret, "", "device-here", "asker"), circle: None };
        let done: PairDone = json(post(&format!("{base}/pair/confirm"), &right).unwrap());
        assert!(
            same(&done.proof, &proof(&secret, "", "device-there", "answerer")),
            "the device proves it knew the code"
        );
        let sealed = done.circle.expect("its circle comes sealed");
        let circle = state().ledger.circle.clone().expect("a circle was made");
        assert_ne!(sealed.key, circle.key, "the key does not travel in the clear");
        assert_eq!(seal(&sealed.key, &secret, "answerer circle").unwrap(), circle.key);
        assert!(circle.has("device-here") && circle.has("device-there"));
        let told =
            take().1.into_iter().any(|event| matches!(event, Event::Paired { name: Some(name), .. } if name == "Here"));
        assert!(told && is_mate("device-here"), "the pairing is told and remembered");
        let saved: Ledger = serde_json::from_slice(&fs::read(there.join("sync.json")).unwrap()).unwrap();
        assert_eq!(saved.circle.map(|circle| circle.key), Some(circle.key));
        configure(None, String::new(), String::new(), false);
        let _ = fs::remove_dir_all(there);
    }

    #[test]
    fn asking_again_for_a_code_gives_no_new_guesses_at_it() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let there = library("pairing-guesses");
        let address = started(&there, 47935);
        let base = format!("http://{address}/listenook");
        take();
        let asked = || {
            let (private, public) = key_pair().unwrap();
            let asked = PairAsk { device: asker(), nonce: "asker-nonce".into(), public, circle: None };
            let answer: PairAnswer = json(post(&format!("{base}/pair"), &asked).unwrap());
            let shared = agree(private, &answer.public).unwrap();
            let code = take()
                .1
                .into_iter()
                .find_map(|event| match event {
                    Event::Pairing { code, .. } => Some(code),
                    _ => None,
                })
                .expect("a code is shown");
            (shared, answer.nonce, code)
        };
        let guess = |(shared, nonce, code): &(String, String, String), right: bool| {
            let code = match (right, code.as_str()) {
                (true, _) => code.clone(),
                (false, "000000") => "111111".into(),
                (false, _) => "000000".into(),
            };
            let secret = pairing_secret(&code, shared, ("device-here", "asker-nonce"), ("device-there", nonce));
            let confirm = PairConfirm {
                id: "device-here".into(),
                proof: proof(&secret, "", "device-here", "asker"),
                circle: None,
            };
            match post(&format!("{base}/pair/confirm"), &confirm) {
                Ok(_) => "paired".to_owned(),
                Err(ureq::Error::Status(403, response)) => reason(response),
                Err(error) => panic!("{error}"),
            }
        };

        let first = asked();
        assert_eq!(guess(&first, false), "wrong");
        assert_eq!(guess(&first, false), "wrong");
        let again = asked();
        assert_eq!(guess(&again, false), "wait", "a new code does not start the guesses again");
        assert_eq!(guess(&again, true), "expired", "the code that was shown is spent");
        let (_, public) = key_pair().unwrap();
        let asking = PairAsk { device: asker(), nonce: "asker-nonce".into(), public, circle: None };
        let refused = post(&format!("{base}/pair"), &asking);
        assert!(matches!(refused, Err(ureq::Error::Status(429, _))), "no code is shown while pairing waits");
        assert!(state().ledger.circle.is_none());

        state().misses = Misses::default();
        configure(None, String::new(), String::new(), false);
        let _ = fs::remove_dir_all(there);
    }

    #[test]
    fn a_device_that_leaves_is_forgotten_by_the_others() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let there = library("leaving");
        let circle = paired(&there, &["device-there", "device-here"]);
        let address = started(&there, 47934);
        let base = format!("http://{address}/listenook");
        assert!(is_mate("device-here"));
        let nonce =
            || json::<Challenge>(agent(Duration::from_secs(2)).get(&format!("{base}/challenge")).call().unwrap()).nonce;
        let forged = nonce();
        let forged = Leaving {
            proof: proof(&digest(&["other"]), &forged, "device-here", "leave"),
            id: "device-here".into(),
            nonce: forged,
        };
        assert!(matches!(post(&format!("{base}/leave"), &forged), Err(ureq::Error::Status(403, _))));
        assert!(is_mate("device-here"), "only a device of the circle can say it leaves");
        let nonce = nonce();
        let leaving =
            Leaving { proof: proof(&circle.key, &nonce, "device-here", "leave"), id: "device-here".into(), nonce };
        post(&format!("{base}/leave"), &leaving).unwrap();
        assert!(!is_mate("device-here"));
        assert!(mates().is_empty());
        configure(None, String::new(), String::new(), false);
        let _ = fs::remove_dir_all(there);
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
        leave_large_media(&mut plan);
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
    fn only_local_addresses_are_answered() {
        assert!(is_local("192.168.1.4".parse().unwrap()));
        assert!(is_local("127.0.0.1".parse().unwrap()));
        assert!(is_local("fe80::1".parse().unwrap()));
        assert!(!is_local("8.8.8.8".parse().unwrap()));
        assert!(!is_local("2001:4860:4860::8888".parse().unwrap()));
    }

    #[test]
    fn turning_sync_off_frees_its_port_at_once() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let root = library("off");
        started(&root, 47941);
        configure(None, String::new(), String::new(), false);
        let freed = (0..20).any(|_| {
            thread::sleep(Duration::from_millis(50));
            TcpListener::bind((Ipv4Addr::UNSPECIFIED, 47941)).is_ok()
        });
        assert!(freed);
        let _ = fs::remove_dir_all(root);
    }
}
