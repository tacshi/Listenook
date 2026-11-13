//! Syncing the Library with another device on the local network.
//!
//! A device that is visible answers on one port: who it is (`/info`), and,
//! once its user accepts, a sync another device drives (`/sync`, then the
//! manifests and media either way, then `/done`). Devices find each other
//! by a multicast announcement where the system lets one through, and by
//! asking every address of the local /24 otherwise. Nothing here runs on
//! the engine thread: what a sync brings waits in [`take`] for the store.
//!
//! The traffic is plain HTTP, as on any local network share: a sync is
//! only ever answered after the user of this device accepts it.

use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write},
    net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket},
    path::{Path, PathBuf},
    sync::{
        Mutex, MutexGuard, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use listenook_core::{
    Job, LibraryCatalog,
    sync::{Device, Entry, Index, PROTOCOL, Transfer, media_extension, media_file_name, plan},
};
use serde::{Deserialize, Serialize};

use crate::state::persist;

/// The port a visible device answers on (`LISTENOOK_SYNC_PORT` overrides
/// it, for a second copy of the app on one machine).
pub(crate) const PORT: u16 = 47823;
const GROUP: Ipv4Addr = Ipv4Addr::new(239, 77, 76, 78);
/// How long the other device's user has to answer.
const ANSWER_WITHIN: Duration = Duration::from_secs(60);
/// A sync that has been quiet this long is over.
const QUIET: Duration = Duration::from_secs(120);
/// So is one whose device asks for nothing this long between two calls:
/// it makes the next as soon as one ends.
const IDLE: Duration = Duration::from_secs(30);
/// After a call that broke off, the device that drives the sync says it
/// is over at once; one that says nothing this long is gone.
const BROKEN: Duration = Duration::from_secs(8);
/// A sync whose connection was lost is tried again this often, for this
/// long without getting through.
const RETRY_EVERY: Duration = Duration::from_secs(3);
const RETRY_FOR: Duration = Duration::from_secs(300);
/// The device whose sync was lost is let back in without asking for this long.
const RESUME_WITHIN: Duration = Duration::from_secs(600);
/// How long a datagram may wait to be sent.
const ANNOUNCE_WITHIN: Duration = Duration::from_millis(500);
/// A device not heard from for this long is no longer listed.
const PEER_KEPT: Duration = Duration::from_secs(45);
const MANIFEST_LIMIT: u64 = 256 * 1024 * 1024;

/// A device found on the network.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Peer {
    pub(crate) device: Device,
    pub(crate) address: SocketAddr,
}

/// What a sync brought, for the store to take in.
#[derive(Debug)]
pub(crate) enum Incoming {
    /// The other device's groups and tags. Comes before its recordings.
    Catalog(LibraryCatalog),
    /// A recording's manifest, new or newer than the one here.
    Job(Box<Job>),
    /// The media of a recording that is here without its file.
    Media { id: String, path: PathBuf },
}

/// What happened while this device answered another's sync.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Event {
    /// A device asks to sync; `serial` names the request in [`answer`].
    Asked { serial: u64, device: Device },
    /// The request was withdrawn, or waited too long.
    Withdrawn { serial: u64 },
    /// The sync this device accepted ended: `complete`, or else `lost`
    /// when the other device was no longer heard from (it said so itself
    /// otherwise).
    Served { name: String, received: u32, sent: u32, complete: bool, lost: bool },
}

/// The sync this device is answering, as the page shows it. The totals
/// are the other device's, and zero when it does not tell them.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Serving {
    pub(crate) name: String,
    pub(crate) items: u64,
    pub(crate) items_total: u64,
    pub(crate) bytes: u64,
    pub(crate) bytes_total: u64,
}

/// What a sync copied, as the device that started it counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Summary {
    pub(crate) received: u32,
    pub(crate) sent: u32,
}

/// How far a sync is, read by the page while it runs.
#[derive(Debug, Default)]
pub(crate) struct Progress {
    /// Set once the other device has accepted.
    pub(crate) accepted: AtomicBool,
    pub(crate) items: AtomicU64,
    pub(crate) items_total: AtomicU64,
    pub(crate) bytes: AtomicU64,
    pub(crate) bytes_total: AtomicU64,
    /// Set to end the sync early.
    pub(crate) stop: AtomicBool,
    /// The connection was lost, and is being looked for again.
    pub(crate) waiting: AtomicBool,
}

struct Request {
    serial: u64,
    device: Device,
    /// The ids of the recordings being worked on here, once accepted;
    /// `Some(None)` once declined.
    answer: Option<Option<HashSet<String>>>,
}

/// The device whose sync was lost: it may take it up again.
struct Resumable {
    device: String,
    busy: HashSet<String>,
    at: Instant,
}

struct Session {
    token: String,
    /// The id of the device that drives it.
    device: String,
    /// The recordings left out, as when it was accepted.
    busy: HashSet<String>,
    name: String,
    last: Instant,
    received: u32,
    sent: u32,
    /// The calls being answered now.
    calls: u32,
    /// When a call last broke off.
    broken: Option<Instant>,
    items: u64,
    items_total: u64,
    bytes: u64,
    bytes_total: u64,
}

impl Session {
    /// Whether the device that drives it is gone.
    fn is_over(&self) -> bool {
        let quiet = self.last.elapsed();
        quiet > QUIET
            || (self.calls == 0 && quiet > IDLE)
            || (self.calls == 0 && self.broken.is_some_and(|at| at.elapsed() > BROKEN))
    }
}

#[derive(Default)]
struct State {
    root: Option<PathBuf>,
    me: Device,
    visible: bool,
    /// Bumped whenever visibility changes: threads of an older turn end.
    turn: u64,
    peers: HashMap<String, (Peer, Instant)>,
    request: Option<Request>,
    session: Option<Session>,
    resumable: Option<Resumable>,
    /// The token of the sync this device's user ended.
    stopped: Option<String>,
    /// This device is itself syncing with another.
    starting: bool,
    serial: u64,
    incoming: Vec<Incoming>,
    events: Vec<Event>,
    announcer: Option<UdpSocket>,
}

fn state() -> MutexGuard<'static, State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(Mutex::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn port() -> u16 {
    std::env::var("LISTENOOK_SYNC_PORT").ok().and_then(|port| port.parse().ok()).unwrap_or(PORT)
}

/// A name for this device, until its user gives it one.
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

/// This device's platform, as [`Device::platform`] names it.
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

/// Says whose Library this is and where it is kept, and whether other
/// devices may find it. Visible, it answers on its port until told otherwise.
pub(crate) fn configure(root: Option<PathBuf>, id: String, name: String, visible: bool) {
    let mut state = state();
    let visible = visible && root.is_some();
    let changed = state.visible != visible || state.root != root;
    state.root = root;
    state.me =
        Device { app: "listenook".into(), protocol: PROTOCOL, id, name, platform: platform().into(), port: port() };
    if !changed {
        return;
    }
    state.visible = visible;
    state.turn += 1;
    state.announcer = None;
    state.request = None;
    state.session = None;
    let turn = state.turn;
    drop(state);
    if visible {
        thread::spawn(move || serve(turn));
        thread::spawn(move || listen(turn));
    }
}

/// The app whose Library is at `root` is gone: its port is given back,
/// unless another has the service by now (the next of a test's apps).
pub(crate) fn release(root: &Option<PathBuf>) {
    if state().root == *root {
        configure(None, String::new(), String::new(), false);
    }
}

/// The devices heard from lately, by name.
pub(crate) fn peers() -> Vec<Peer> {
    let mut state = state();
    state.peers.retain(|_, (_, seen)| seen.elapsed() < PEER_KEPT);
    let mut peers: Vec<Peer> = state.peers.values().map(|(peer, _)| peer.clone()).collect();
    peers.sort_by(|a, b| {
        (a.device.name.to_lowercase(), &a.device.id).cmp(&(b.device.name.to_lowercase(), &b.device.id))
    });
    peers
}

/// What syncs brought since the last call, and what happened meanwhile.
pub(crate) fn take() -> (Vec<Incoming>, Vec<Event>) {
    let mut state = state();
    if state.session.as_ref().is_some_and(Session::is_over) {
        end_session(&mut state, false, true);
    }
    (std::mem::take(&mut state.incoming), std::mem::take(&mut state.events))
}

/// The sync this device is answering, if any.
pub(crate) fn serving() -> Option<Serving> {
    let state = state();
    // Accepted a moment ago, it is one already.
    let accepted = || {
        let request = state.request.as_ref().filter(|request| matches!(request.answer, Some(Some(_))))?;
        Some(Serving { name: request.device.name.clone(), ..Serving::default() })
    };
    state
        .session
        .as_ref()
        .map(|session| Serving {
            name: session.name.clone(),
            items: session.items,
            items_total: session.items_total,
            bytes: session.bytes,
            bytes_total: session.bytes_total,
        })
        .or_else(accepted)
}

/// Ends the sync this device is answering: the other device is refused
/// from here on, and tells its user.
pub(crate) fn stop_serving() {
    let mut state = state();
    state.stopped = state.session.take().map(|session| session.token);
    state.resumable = None;
}

/// Answers the request `serial`: `busy` (the recordings being worked on
/// here, which are left out) accepts it, none declines.
pub(crate) fn answer(serial: u64, busy: Option<HashSet<String>>) {
    if let Some(request) = state().request.as_mut().filter(|request| request.serial == serial) {
        request.answer = Some(busy);
    }
}

fn end_session(state: &mut State, complete: bool, lost: bool) {
    if let Some(session) = state.session.take() {
        // Lost, the device may come back for the rest.
        state.resumable = lost.then(|| Resumable { device: session.device, busy: session.busy, at: Instant::now() });
        state.events.push(Event::Served {
            name: session.name,
            received: session.received,
            sent: session.sent,
            complete,
            lost,
        });
    }
}

fn remember(device: Device, address: SocketAddr) {
    let mut state = state();
    if !device.is_compatible() || device.id == state.me.id {
        return;
    }
    state.peers.insert(device.id.clone(), (Peer { device, address }, Instant::now()));
}

// --- Finding devices ---------------------------------------------------------

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Announcement {
    device: Device,
    /// Asks those who hear it to say who they are.
    asking: bool,
}

/// Hears other devices announce themselves, and answers those that ask.
fn listen(turn: u64) {
    let Ok(socket) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, PORT)) else {
        return;
    };
    // Where the system lets no multicast through, the socket still hears
    // what is sent straight to it.
    let _ = socket.join_multicast_v4(&GROUP, &Ipv4Addr::UNSPECIFIED);
    let _ = socket.set_read_timeout(Some(Duration::from_millis(500)));
    // A send waits while the network's queue is full, which a sync's
    // media keeps it: it gives up instead (the clone shares the limit).
    let _ = socket.set_write_timeout(Some(ANNOUNCE_WITHIN));
    if let Ok(announcer) = socket.try_clone() {
        state().announcer = Some(announcer);
    }
    announce(true);
    let mut buffer = [0_u8; 2048];
    loop {
        let me = {
            let state = state();
            if state.turn != turn {
                return;
            }
            state.me.clone()
        };
        let Ok((length, from)) = socket.recv_from(&mut buffer) else {
            continue;
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

/// Tells the network this device is here; `asking`, also asks who else is.
/// The send may wait on the network: never called on the engine thread,
/// and the state is let go before it (every sync thread needs it).
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

/// This device's address on the local network, if it is on one.
fn local_address() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    // Nothing is sent: connecting only picks the route.
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

/// Asks the device at `address` who it is.
fn ask(address: SocketAddr) -> Option<Device> {
    let response = agent(Duration::from_secs(3)).get(&format!("http://{address}/listenook/info")).call().ok()?;
    let device: Device = serde_json::from_reader(response.into_reader().take(64 * 1024)).ok()?;
    device.is_compatible().then_some(device)
}

/// Looks for devices: asks by multicast, and asks every address of the
/// local /24, which finds those a multicast does not reach (a phone, a
/// network that drops it). What answers shows in [`peers`].
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
                        .spawn(move || {
                            match TcpStream::connect_timeout(&address, Duration::from_millis(700)) {
                                Ok(_) => match ask(address) {
                                    Some(device) => {
                                        log::debug!("sync: found {} at {address}", device.name);
                                        remember(device, address);
                                    }
                                    None => log::debug!("sync: {address} is open but is not Listenook"),
                                },
                                // Nothing listens there (refused, or no such host).
                                Err(error) if address.ip() == IpAddr::V4(mine) => {
                                    log::debug!("sync: {address}: {error}")
                                }
                                Err(_) => {}
                            }
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

/// Finds the device at an address the user typed (`192.168.1.20`, or with
/// a port). Blocks; returns it when it answered.
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

// --- Answering another device ------------------------------------------------

/// Whether an address is on a local network (or this machine).
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

/// Answers other devices while this one is visible.
fn serve(turn: u64) {
    let listener = match TcpListener::bind((Ipv4Addr::UNSPECIFIED, port())) {
        Ok(listener) => listener,
        Err(error) => {
            log::warn!("sync: port {} is not free: {error}", port());
            return;
        }
    };
    let _ = listener.set_nonblocking(true);
    loop {
        if state().turn != turn {
            return;
        }
        match listener.accept() {
            Ok((stream, from)) => {
                if is_local(from.ip()) {
                    thread::spawn(move || {
                        let _ = stream.set_nonblocking(false);
                        if let Err(error) = handle(stream) {
                            log::debug!("sync: {error}");
                        }
                    });
                }
            }
            Err(_) => thread::sleep(Duration::from_millis(80)),
        }
    }
}

struct Call {
    method: String,
    path: String,
    length: u64,
    token: String,
    /// How far the device that drives the sync says it is.
    progress: Option<(u64, u64, u64)>,
    /// Where in the media file the call takes up.
    offset: u64,
    body: BufReader<TcpStream>,
}

fn read_call(stream: TcpStream) -> io::Result<Call> {
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
    Ok(Call { method, path, length, token, progress, offset, body })
}

fn reply(stream: &mut TcpStream, status: u16, body: &[u8]) -> io::Result<()> {
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        410 => "Gone",
        426 => "Upgrade Required",
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

/// The session `token` opens, kept alive; `count` notes what it carried.
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
    /// Takes up the sync this device lost, which was accepted already.
    resume: bool,
}

/// How much of a media file that was being sent is here.
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
}

/// How a sync ended, as the device that drove it tells the other.
#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Done {
    complete: bool,
}

fn read_body(call: &mut Call, limit: u64) -> io::Result<Vec<u8>> {
    if call.length > limit {
        return Err(io::Error::other("the body is too large"));
    }
    let mut bytes = vec![0_u8; call.length as usize];
    call.body.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn handle(stream: TcpStream) -> io::Result<()> {
    let mut out = stream.try_clone()?;
    let mut call = read_call(stream)?;
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
        ("GET", ["info"]) => reply_json(out, &me),
        ("POST", ["sync"]) => {
            let hello: Hello = serde_json::from_slice(&read_body(call, 4 * 1024 * 1024)?)?;
            welcome(out, &root, me, hello)
        }
        ("POST", ["cancel", id]) => {
            let mut state = state();
            if let Some(request) = state.request.take_if(|request| request.device.id == *id) {
                state.events.push(Event::Withdrawn { serial: request.serial });
            }
            drop(state);
            reply(out, 200, b"{}")
        }
        // Ended by this device's user, or no longer known (lost, and over).
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
            state.incoming.push(Incoming::Job(Box::new(job)));
            if let Some(session) = &mut state.session {
                session.received += 1;
            }
            drop(state);
            reply(out, 200, b"{}")
        }
        ("GET", ["media", id]) => {
            let source = persist::load_job(&root, id).map(|job| media_of(&root, &job));
            let Some(mut file) = source.and_then(|path| fs::File::open(path).ok()) else {
                return reply(out, 404, b"{}");
            };
            let length = file.metadata()?.len();
            // The rest of a file the other device has the start of.
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
            state().incoming.push(Incoming::Media { id: (*id).to_owned(), path });
            reply(out, 200, b"{}")
        }
        _ => reply(out, 404, b"{}"),
    }
}

/// Puts a request to sync before this device's user, and waits for the answer.
fn welcome(out: &mut TcpStream, root: &Path, me: Device, hello: Hello) -> io::Result<()> {
    if hello.device.app != "listenook" || hello.device.id.is_empty() {
        return reply(out, 400, b"{}");
    }
    if hello.device.protocol != PROTOCOL {
        return reply(out, 426, b"{}");
    }
    let token = uuid::Uuid::new_v4().to_string();
    let resumed = {
        let mut state = state();
        if state.session.as_ref().is_some_and(Session::is_over) {
            end_session(&mut state, false, true);
        }
        let id = &hello.device.id;
        let free = hello.resume && !state.starting && state.request.is_none();
        if free && state.session.as_ref().is_some_and(|session| session.device == *id) {
            // The connection was lost before this device noticed: the
            // same sync goes on.
            let old = state.session.take().expect("checked above");
            open_session(&mut state, &hello, &token, old.busy.clone(), (old.received, old.sent));
            Some(old.busy)
        } else if free
            && state.session.is_none()
            && state.resumable.as_ref().is_some_and(|lost| lost.device == *id && lost.at.elapsed() < RESUME_WITHIN)
        {
            let lost = state.resumable.take().expect("checked above");
            open_session(&mut state, &hello, &token, lost.busy.clone(), (0, 0));
            Some(lost.busy)
        } else {
            None
        }
    };
    let busy = match resumed {
        Some(busy) => busy,
        None => match ask_user(&hello, &token) {
            Ok(busy) => busy,
            Err(status) => return reply(out, status, b"{}"),
        },
    };
    let index = index_of(root, &busy);
    in_session(&token, |_| {});
    let sent = reply_json(out, &Welcome { token: token.clone(), device: me, index });
    if sent.is_err() {
        // The device that asked is gone already.
        in_session(&token, |session| session.broken = Some(Instant::now()));
    }
    sent
}

fn open_session(state: &mut State, hello: &Hello, token: &str, busy: HashSet<String>, (received, sent): (u32, u32)) {
    state.incoming.push(Incoming::Catalog(hello.catalog.clone()));
    state.resumable = None;
    state.session = Some(Session {
        token: token.to_owned(),
        device: hello.device.id.clone(),
        busy,
        name: hello.device.name.clone(),
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

/// Asks this device's user: the recordings to leave out once accepted,
/// else the status to answer with.
fn ask_user(hello: &Hello, token: &str) -> Result<HashSet<String>, u16> {
    let serial = {
        let mut state = state();
        if state.starting || state.session.is_some() || state.request.is_some() {
            return Err(409);
        }
        state.serial += 1;
        let serial = state.serial;
        state.request = Some(Request { serial, device: hello.device.clone(), answer: None });
        state.events.push(Event::Asked { serial, device: hello.device.clone() });
        serial
    };
    let asked = Instant::now();
    loop {
        thread::sleep(Duration::from_millis(100));
        let mut state = state();
        let Some(request) = state.request.as_mut().filter(|request| request.serial == serial) else {
            // Withdrawn by the device that asked.
            return Err(403);
        };
        if let Some(answer) = request.answer.take() {
            state.request = None;
            let busy = answer.ok_or(403_u16)?;
            // The sync is on from the answer, with no moment in between.
            open_session(&mut state, hello, token, busy.clone(), (0, 0));
            return Ok(busy);
        }
        if asked.elapsed() > ANSWER_WITHIN {
            state.request = None;
            state.events.push(Event::Withdrawn { serial });
            return Err(403);
        }
    }
}

fn manifest_path(root: &Path, id: &str) -> PathBuf {
    root.join("jobs").join(id).join("manifest.json")
}

/// The Library on disk, as the other device needs to know it. `busy`
/// names the recordings being worked on in this run.
/// Where a recording's media is: the path its manifest keeps, or where
/// that leads now that the app's folder has another name (an iPhone's or
/// iPad's after an update, see [`persist::rehomed`]).
fn media_of(root: &Path, job: &Job) -> PathBuf {
    PathBuf::from(persist::rehomed(&job.source_path, root, Path::is_file).unwrap_or_else(|| job.source_path.clone()))
}

fn index_of(root: &Path, busy: &HashSet<String>) -> Index {
    let entries = persist::load_jobs(root)
        .iter()
        .map(|job| {
            let size = fs::metadata(media_of(root, job)).ok().filter(fs::Metadata::is_file).map(|file| file.len());
            Entry { busy: busy.contains(&job.id), ..Entry::of(job, size) }
        })
        .collect();
    Index { entries, catalog: persist::load_library_catalog(root) }
}

/// Copies `length` bytes, telling `alive` how many went each time; it
/// answers whether to go on.
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

/// Writes `length` bytes to `path`, through a `.part` file beside it,
/// after the `offset` bytes that file has from the time before. What came
/// of a transfer that broke off stays in it, to be taken up again.
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

// --- Syncing with another device ---------------------------------------------

fn code_of(error: ureq::Error) -> &'static str {
    match error {
        ureq::Error::Status(403, _) => "sync_declined",
        ureq::Error::Status(409, _) => "sync_peer_busy",
        ureq::Error::Status(426, _) => "sync_incompatible",
        ureq::Error::Status(..) => "sync_failed",
        ureq::Error::Transport(_) => "sync_unreachable",
    }
}

/// Withdraws the request this device is waiting on at `address`.
pub(crate) fn withdraw(address: SocketAddr) {
    let id = state().me.id.clone();
    thread::spawn(move || {
        let _ = agent(Duration::from_secs(3)).post(&format!("http://{address}/listenook/cancel/{id}")).call();
    });
}

/// Syncs this Library with the one at `address`: asks, waits for its user
/// to accept, then copies what each side lacks. Blocks until it is done.
/// `busy` names the recordings being worked on here. What arrives waits
/// in [`take`].
pub(crate) fn sync_with(
    address: SocketAddr,
    busy: HashSet<String>,
    progress: &Progress,
) -> Result<Summary, &'static str> {
    let (root, me) = {
        let mut state = state();
        if state.session.is_some() || state.request.is_some() || state.starting {
            return Err("sync_peer_busy");
        }
        state.starting = true;
        (state.root.clone(), state.me.clone())
    };
    let result = match root {
        Some(root) => persist_with(address, &root, &me, &busy, progress),
        None => Err("sync_failed"),
    };
    progress.waiting.store(false, Ordering::Relaxed);
    state().starting = false;
    result
}

/// [`exchange`], taken up again when the connection is lost after the
/// other device accepted: it lets this one back in without asking, and
/// what was copied, whole or in part, is not copied again.
fn persist_with(
    address: SocketAddr,
    root: &Path,
    me: &Device,
    busy: &HashSet<String>,
    progress: &Progress,
) -> Result<Summary, &'static str> {
    let mut summary = Summary::default();
    let mut lost: Option<Instant> = None;
    loop {
        let again = lost.is_some();
        let code = match exchange(address, root, me.clone(), busy, progress, again, &mut summary) {
            Ok(()) => return Ok(summary),
            Err(code) => code,
        };
        let stopped = || progress.stop.load(Ordering::Relaxed);
        // The other device may not have noticed yet, and still be in the sync.
        let worth = recoverable(code) || (again && code == "sync_peer_busy");
        if stopped() || !worth || !progress.accepted.load(Ordering::Relaxed) {
            return Err(code);
        }
        // An attempt that got through has all the time again.
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

/// Whether a sync that ended so may go on once the network is back.
fn recoverable(code: &str) -> bool {
    matches!(code, "sync_interrupted" | "sync_unreachable")
}

/// One go at the sync: `resume` takes up one that was lost. What it
/// copies is added to `summary`.
fn exchange(
    address: SocketAddr,
    root: &Path,
    me: Device,
    busy: &HashSet<String>,
    progress: &Progress,
    resume: bool,
    summary: &mut Summary,
) -> Result<(), &'static str> {
    let base = format!("http://{address}/listenook");
    let hello = Hello { device: me, catalog: persist::load_library_catalog(root), resume };
    let welcome: Welcome = agent(ANSWER_WITHIN + Duration::from_secs(10))
        .post(&format!("{base}/sync"))
        .send_bytes(&serde_json::to_vec(&hello).map_err(|_| "sync_failed")?)
        .map_err(code_of)
        .and_then(|response| serde_json::from_reader(response.into_reader()).map_err(|_| "sync_failed"))?;
    if progress.stop.load(Ordering::Relaxed) {
        return Err("sync_cancelled");
    }
    progress.accepted.store(true, Ordering::Relaxed);
    progress.waiting.store(false, Ordering::Relaxed);
    // What is left to copy, when taken up again.
    progress.items.store(0, Ordering::Relaxed);
    progress.bytes.store(0, Ordering::Relaxed);
    let http = agent(Duration::from_secs(30));
    let token = welcome.token.as_str();
    let local = index_of(root, busy);
    let plan = plan(&local.entries, &welcome.index.entries);
    progress.items_total.store((plan.pull.len() + plan.push.len()) as u64, Ordering::Relaxed);
    progress.bytes_total.store(plan.media_bytes(), Ordering::Relaxed);
    state().incoming.push(Incoming::Catalog(welcome.index.catalog.clone()));

    // Each call says whose sync it is and how far, for the other device
    // to show.
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
        // The other device ended the sync.
        ureq::Error::Status(403, _) => "sync_cancelled_there",
        // It gave the sync up for lost.
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
            // What came of it the time before is not asked for again.
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
            // An older Listenook sends the whole file, and does not say from where.
            let from: u64 = response.header("X-Listenook-Offset").and_then(|from| from.parse().ok()).unwrap_or(0);
            if from > 0 && (from != have || from + length != transfer.media_size) {
                // Not the rest of the file this is the start of: from the top, next time.
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
            state().incoming.push(Incoming::Job(Box::new(job)));
        } else if transfer.media {
            state().incoming.push(Incoming::Media { id: id.clone(), path });
        }
        Ok(())
    };
    let push = |transfer: &Transfer| -> Result<(), &'static str> {
        let id = &transfer.id;
        if transfer.media {
            let source = persist::load_job(root, id).map(|job| media_of(root, &job)).ok_or("sync_failed")?;
            let mut file = fs::File::open(&source).map_err(|_| "sync_failed")?;
            let length = file.metadata().map_err(|_| "sync_failed")?.len();
            let extension = media_extension(&transfer.media_name);
            // What the other device has of it from the time before (an
            // older Listenook keeps nothing, and knows no such question).
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
    // Lost, it is taken up again: the other device keeps it open.
    if matches!(outcome, Err(code) if recoverable(code)) && !progress.stop.load(Ordering::Relaxed) {
        return outcome;
    }
    // Else, whatever happened, the other device is told the sync is over.
    let told = call(agent(Duration::from_secs(5)).post(&format!("{base}/done")))
        .send_bytes(&serde_json::to_vec(&Done { complete: outcome.is_ok() }).unwrap_or_default());
    // It no longer knows this sync: it was ended there, which is why a
    // transfer broke off.
    if matches!(told, Err(ureq::Error::Status(403, _))) && matches!(outcome, Err(code) if code != "sync_cancelled") {
        outcome = Err("sync_cancelled_there");
    }
    outcome
}

/// A reader that says how much was read of it, and ends when told to stop.
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

    /// One process is one device: these tests share its state.
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

    /// An iPhone's or iPad's manifests keep paths into a container that
    /// has another name by now (or the `@container` the app once wrote).
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
        let index = index_of(&root, &HashSet::new());
        assert_eq!(index.entries[0].media_size, 5);
        assert_eq!(index.entries[0].media_name.as_deref(), Some("Talk.m4a"));
        assert_eq!(media_of(&root, &job), root.join("media/one/Talk.m4a"));
        let _ = fs::remove_dir_all(root.parent().unwrap().parent().unwrap());
    }

    /// A device's side of a sync, played by this process: the server is
    /// "there", and what the client pulls is checked as it arrives.
    #[test]
    fn two_libraries_end_as_their_union() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the tests that read it run one at a time.
        unsafe { std::env::set_var("LISTENOOK_SYNC_PORT", "47931") };
        let (there, here) = (library("there"), library("here"));
        recording(&there, "only-there", "2026-01-01T00:00:00.000Z", Some(b"remote media"));
        recording(&there, "both", "2026-03-01T00:00:00.000Z", None);
        recording(&here, "both", "2026-02-01T00:00:00.000Z", Some(b"local media"));
        recording(&here, "only-here", "2026-01-01T00:00:00.000Z", Some(b"pushed media"));
        let catalog =
            LibraryCatalog { tags: vec![Named { id: "t1".into(), name: "todo".into() }], ..Default::default() };
        persist::save_library_catalog(&there, &catalog).unwrap();

        configure(Some(there.clone()), "device-there".into(), "There".into(), true);
        let address = SocketAddr::from((Ipv4Addr::LOCALHOST, 47931));
        let found = (0..50).find_map(|_| {
            thread::sleep(Duration::from_millis(50));
            ask(address)
        });
        assert_eq!(found.expect("the device answers").name, "There");

        // The user there accepts as soon as asked.
        let accepting = thread::spawn(|| {
            for _ in 0..100 {
                thread::sleep(Duration::from_millis(50));
                let asked = state().events.iter().find_map(|event| match event {
                    Event::Asked { serial, .. } => Some(*serial),
                    _ => None,
                });
                if let Some(serial) = asked {
                    answer(serial, Some(HashSet::new()));
                    return;
                }
            }
        });
        // The client reads its own Library from another folder: as the
        // state is one per process, it is driven here without `sync_with`.
        let me = Device { app: "listenook".into(), protocol: PROTOCOL, id: "device-here".into(), ..Device::default() };
        let progress = Progress::default();
        let mut summary = Summary::default();
        exchange(address, &here, me, &HashSet::new(), &progress, false, &mut summary).unwrap();
        accepting.join().unwrap();
        assert_eq!(summary, Summary { received: 2, sent: 2 });
        assert_eq!(progress.items.load(Ordering::Relaxed), 4);

        let (incoming, events) = take();
        assert!(events.contains(&Event::Served {
            name: String::new(),
            received: 1,
            sent: 2,
            complete: true,
            lost: false
        }));
        let jobs: Vec<&Job> = incoming
            .iter()
            .filter_map(|incoming| match incoming {
                Incoming::Job(job) => Some(&**job),
                _ => None,
            })
            .collect();
        // Pulled here: the recording only there, and the newer manifest of
        // the one both have. Pushed there: the recording only here.
        let titles: Vec<String> = jobs.iter().map(|job| job.title()).collect();
        assert!(titles.contains(&"Title of only-there at 2026-01-01T00:00:00.000Z".to_owned()));
        assert!(titles.contains(&"Title of both at 2026-03-01T00:00:00.000Z".to_owned()));
        assert!(titles.contains(&"Title of only-here at 2026-01-01T00:00:00.000Z".to_owned()));
        assert_eq!(fs::read(here.join("media/sync-only-there.mp3")).unwrap(), b"remote media");
        assert_eq!(fs::read(there.join("media/sync-only-here.mp3")).unwrap(), b"pushed media");
        // The media of the one both have went where it was missing.
        assert_eq!(fs::read(there.join("media/sync-both.mp3")).unwrap(), b"local media");
        assert!(incoming.iter().any(|incoming| matches!(incoming, Incoming::Media { id, .. } if id == "both")));
        assert!(incoming.iter().any(|incoming| matches!(incoming, Incoming::Catalog(c) if c.tags.len() == 1)));

        // Without a session nothing is given out.
        let refused = agent(Duration::from_secs(2)).get(&format!("http://{address}/listenook/manifest/both")).call();
        assert!(matches!(refused, Err(ureq::Error::Status(410, _))));
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here));
    }

    #[test]
    fn a_declined_sync_copies_nothing() {
        let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        // SAFETY: the tests that read it run one at a time.
        unsafe { std::env::set_var("LISTENOOK_SYNC_PORT", "47932") };
        let (there, here) = (library("declining"), library("declined"));
        recording(&there, "kept", "2026-01-01T00:00:00.000Z", None);
        configure(Some(there.clone()), "device-there".into(), "There".into(), true);
        let address = SocketAddr::from((Ipv4Addr::LOCALHOST, 47932));
        assert!((0..50).any(|_| {
            thread::sleep(Duration::from_millis(50));
            ask(address).is_some()
        }));
        let declining = thread::spawn(|| {
            for _ in 0..100 {
                thread::sleep(Duration::from_millis(50));
                let asked = state().events.iter().find_map(|event| match event {
                    Event::Asked { serial, .. } => Some(*serial),
                    _ => None,
                });
                if let Some(serial) = asked {
                    answer(serial, None);
                    return;
                }
            }
        });
        let me = Device { app: "listenook".into(), protocol: PROTOCOL, id: "device-here".into(), ..Device::default() };
        let outcome =
            exchange(address, &here, me, &HashSet::new(), &Progress::default(), false, &mut Summary::default());
        declining.join().unwrap();
        assert_eq!(outcome, Err("sync_declined"));
        assert!(take().0.is_empty());
        configure(None, String::new(), String::new(), false);
        let _ = (fs::remove_dir_all(there), fs::remove_dir_all(here));
    }

    #[test]
    fn only_local_addresses_are_answered() {
        assert!(is_local("192.168.1.4".parse().unwrap()));
        assert!(is_local("127.0.0.1".parse().unwrap()));
        assert!(is_local("fe80::1".parse().unwrap()));
        assert!(!is_local("8.8.8.8".parse().unwrap()));
        assert!(!is_local("2001:4860:4860::8888".parse().unwrap()));
    }
}
