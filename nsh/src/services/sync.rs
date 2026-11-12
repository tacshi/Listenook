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
    io::{self, BufRead, BufReader, Read, Write},
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
    /// The sync this device accepted ended.
    Served { name: String, received: u32, sent: u32, complete: bool },
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
}

struct Request {
    serial: u64,
    device: Device,
    /// The ids of the recordings being worked on here, once accepted;
    /// `Some(None)` once declined.
    answer: Option<Option<HashSet<String>>>,
}

struct Session {
    token: String,
    name: String,
    last: Instant,
    received: u32,
    sent: u32,
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
    if state.session.as_ref().is_some_and(|session| session.last.elapsed() > QUIET) {
        end_session(&mut state, false);
    }
    (std::mem::take(&mut state.incoming), std::mem::take(&mut state.events))
}

/// Answers the request `serial`: `busy` (the recordings being worked on
/// here, which are left out) accepts it, none declines.
pub(crate) fn answer(serial: u64, busy: Option<HashSet<String>>) {
    if let Some(request) = state().request.as_mut().filter(|request| request.serial == serial) {
        request.answer = Some(busy);
    }
}

fn end_session(state: &mut State, complete: bool) {
    if let Some(session) = state.session.take() {
        state.events.push(Event::Served {
            name: session.name,
            received: session.received,
            sent: session.sent,
            complete,
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
fn announce(asking: bool) {
    let state = state();
    if let Some(socket) = &state.announcer
        && let Ok(message) = serde_json::to_vec(&Announcement { device: state.me.clone(), asking })
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
    announce(true);
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
    body: BufReader<TcpStream>,
}

fn read_call(stream: TcpStream) -> io::Result<Call> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    let mut body = BufReader::new(stream);
    let (mut method, mut path, mut length, mut token) = (String::new(), String::new(), 0, String::new());
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
                _ => {}
            }
        }
    }
    Ok(Call { method, path, length, token, body })
}

fn reply(stream: &mut TcpStream, status: u16, body: &[u8]) -> io::Result<()> {
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
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
    let (root, me) = {
        let state = state();
        (state.root.clone(), state.me.clone())
    };
    let Some(root) = root else {
        return reply(&mut out, 404, b"{}");
    };
    let path = call.path.clone();
    let parts: Vec<&str> = path.trim_start_matches("/listenook/").split('/').collect();
    if !path.starts_with("/listenook/") {
        return reply(&mut out, 404, b"{}");
    }
    let method = call.method.clone();
    match (method.as_str(), parts.as_slice()) {
        ("GET", ["info"]) => reply_json(&mut out, &me),
        ("POST", ["sync"]) => {
            let hello: Hello = serde_json::from_slice(&read_body(&mut call, 4 * 1024 * 1024)?)?;
            welcome(&mut out, &root, me, hello)
        }
        ("POST", ["cancel", id]) => {
            let mut state = state();
            if let Some(request) = state.request.take_if(|request| request.device.id == *id) {
                state.events.push(Event::Withdrawn { serial: request.serial });
            }
            drop(state);
            reply(&mut out, 200, b"{}")
        }
        _ if !in_session(&call.token, |_| {}) => reply(&mut out, 403, b"{}"),
        ("POST", ["done"]) => {
            let done: Done = serde_json::from_slice(&read_body(&mut call, 64 * 1024)?).unwrap_or_default();
            end_session(&mut state(), done.complete);
            reply(&mut out, 200, b"{}")
        }
        (_, [_, id, ..]) if !Job::is_valid_id(id) => reply(&mut out, 400, b"{}"),
        ("GET", ["manifest", id]) => match fs::read(manifest_path(&root, id)) {
            Ok(bytes) => {
                in_session(&call.token, |session| session.sent += 1);
                reply(&mut out, 200, &bytes)
            }
            Err(_) => reply(&mut out, 404, b"{}"),
        },
        ("PUT", ["manifest", id]) => {
            let job: Job = serde_json::from_slice(&read_body(&mut call, MANIFEST_LIMIT)?)?;
            if job.id != *id {
                return reply(&mut out, 400, b"{}");
            }
            let mut state = state();
            state.incoming.push(Incoming::Job(Box::new(job)));
            if let Some(session) = &mut state.session {
                session.received += 1;
            }
            drop(state);
            reply(&mut out, 200, b"{}")
        }
        ("GET", ["media", id]) => {
            let source = persist::load_job(&root, id).map(|job| media_of(&root, &job));
            let Some(mut file) = source.and_then(|path| fs::File::open(path).ok()) else {
                return reply(&mut out, 404, b"{}");
            };
            let length = file.metadata()?.len();
            write!(
                out,
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
            )?;
            let token = call.token.clone();
            copy(&mut file, &mut out, length, |_| in_session(&token, |_| {}))?;
            out.flush()
        }
        ("PUT", ["media", id, extension]) => {
            let path = root.join("media").join(media_file_name(id, &format!("x.{extension}")));
            let token = call.token.clone();
            let length = call.length;
            receive(&mut call.body, &path, length, |_| in_session(&token, |_| {}))?;
            state().incoming.push(Incoming::Media { id: (*id).to_owned(), path });
            reply(&mut out, 200, b"{}")
        }
        _ => reply(&mut out, 404, b"{}"),
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
    let serial = {
        let mut state = state();
        let quiet = state.session.as_ref().is_some_and(|session| session.last.elapsed() > QUIET);
        if quiet {
            end_session(&mut state, false);
        }
        if state.starting || state.session.is_some() || state.request.is_some() {
            drop(state);
            return reply(out, 409, b"{}");
        }
        state.serial += 1;
        let serial = state.serial;
        state.request = Some(Request { serial, device: hello.device.clone(), answer: None });
        state.events.push(Event::Asked { serial, device: hello.device.clone() });
        serial
    };
    let asked = Instant::now();
    let busy = loop {
        thread::sleep(Duration::from_millis(100));
        let mut state = state();
        let Some(request) = state.request.as_mut().filter(|request| request.serial == serial) else {
            // Withdrawn by the device that asked.
            drop(state);
            return reply(out, 403, b"{}");
        };
        if let Some(answer) = request.answer.take() {
            state.request = None;
            break answer;
        }
        if asked.elapsed() > ANSWER_WITHIN {
            state.request = None;
            state.events.push(Event::Withdrawn { serial });
            break None;
        }
    };
    let Some(busy) = busy else {
        return reply(out, 403, b"{}");
    };
    let index = index_of(root, &busy);
    let token = uuid::Uuid::new_v4().to_string();
    {
        let mut state = state();
        state.incoming.push(Incoming::Catalog(hello.catalog));
        state.session = Some(Session {
            token: token.clone(),
            name: hello.device.name.clone(),
            last: Instant::now(),
            received: 0,
            sent: 0,
        });
    }
    reply_json(out, &Welcome { token, device: me, index })
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

/// Writes `length` bytes to `path`, through a `.part` file beside it.
fn receive(from: &mut impl Read, path: &Path, length: u64, alive: impl FnMut(u64) -> bool) -> io::Result<()> {
    if let Some(folder) = path.parent() {
        fs::create_dir_all(folder)?;
    }
    let part = path.with_extension("part");
    let written = fs::File::create(&part).and_then(|mut file| {
        copy(from, &mut file, length, alive)?;
        file.flush()
    });
    match written {
        Ok(()) => fs::rename(&part, path),
        Err(error) => {
            let _ = fs::remove_file(&part);
            Err(error)
        }
    }
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
        Some(root) => exchange(address, &root, me, &busy, progress),
        None => Err("sync_failed"),
    };
    state().starting = false;
    result
}

fn exchange(
    address: SocketAddr,
    root: &Path,
    me: Device,
    busy: &HashSet<String>,
    progress: &Progress,
) -> Result<Summary, &'static str> {
    let base = format!("http://{address}/listenook");
    let hello = Hello { device: me, catalog: persist::load_library_catalog(root) };
    let welcome: Welcome = agent(ANSWER_WITHIN + Duration::from_secs(10))
        .post(&format!("{base}/sync"))
        .send_bytes(&serde_json::to_vec(&hello).map_err(|_| "sync_failed")?)
        .map_err(code_of)
        .and_then(|response| serde_json::from_reader(response.into_reader()).map_err(|_| "sync_failed"))?;
    if progress.stop.load(Ordering::Relaxed) {
        return Err("sync_cancelled");
    }
    progress.accepted.store(true, Ordering::Relaxed);
    let http = agent(Duration::from_secs(60));
    let token = welcome.token.as_str();
    let local = index_of(root, busy);
    let plan = plan(&local.entries, &welcome.index.entries);
    progress.items_total.store((plan.pull.len() + plan.push.len()) as u64, Ordering::Relaxed);
    progress.bytes_total.store(plan.media_bytes(), Ordering::Relaxed);
    state().incoming.push(Incoming::Catalog(welcome.index.catalog.clone()));

    let moved = |count: u64| {
        progress.bytes.fetch_add(count, Ordering::Relaxed);
        !progress.stop.load(Ordering::Relaxed)
    };
    let failed = |error: ureq::Error| match error {
        // The other device ended the sync.
        ureq::Error::Status(403, _) => "sync_cancelled_there",
        other => code_of(other),
    };
    let stopped = |_: io::Error| {
        if progress.stop.load(Ordering::Relaxed) { "sync_cancelled" } else { "sync_interrupted" }
    };
    let pull = |transfer: &Transfer| -> Result<(), &'static str> {
        let id = &transfer.id;
        let path = root.join("media").join(media_file_name(id, &transfer.media_name));
        if transfer.media {
            let response =
                http.get(&format!("{base}/media/{id}")).set("X-Listenook-Token", token).call().map_err(failed)?;
            let length: u64 =
                response.header("Content-Length").and_then(|length| length.parse().ok()).ok_or("sync_failed")?;
            receive(&mut response.into_reader(), &path, length, moved).map_err(stopped)?;
        }
        if transfer.manifest {
            let response =
                http.get(&format!("{base}/manifest/{id}")).set("X-Listenook-Token", token).call().map_err(failed)?;
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
            let file = fs::File::open(&source).map_err(|_| "sync_failed")?;
            let length = file.metadata().map_err(|_| "sync_failed")?.len();
            let mut counted = Counted { inner: file, moved: &moved };
            http.put(&format!("{base}/media/{id}/{}", media_extension(&transfer.media_name)))
                .set("X-Listenook-Token", token)
                .set("Content-Length", &length.to_string())
                .send(&mut counted)
                .map_err(
                    |error| if progress.stop.load(Ordering::Relaxed) { "sync_cancelled" } else { failed(error) },
                )?;
        }
        if transfer.manifest {
            let manifest = fs::read(manifest_path(root, id)).map_err(|_| "sync_failed")?;
            http.put(&format!("{base}/manifest/{id}"))
                .set("X-Listenook-Token", token)
                .send_bytes(&manifest)
                .map_err(failed)?;
        }
        Ok(())
    };

    let mut summary = Summary::default();
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
    // Whatever happened, the other device is told the sync is over.
    let _ = agent(Duration::from_secs(5))
        .post(&format!("{base}/done"))
        .set("X-Listenook-Token", token)
        .send_bytes(&serde_json::to_vec(&Done { complete: outcome.is_ok() }).unwrap_or_default());
    outcome.map(|()| summary)
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
        let summary = exchange(address, &here, me, &HashSet::new(), &progress).unwrap();
        accepting.join().unwrap();
        assert_eq!(summary, Summary { received: 2, sent: 2 });
        assert_eq!(progress.items.load(Ordering::Relaxed), 4);

        let (incoming, events) = take();
        assert!(events.contains(&Event::Served { name: String::new(), received: 1, sent: 2, complete: true }));
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
        assert!(matches!(refused, Err(ureq::Error::Status(403, _))));
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
        let outcome = exchange(address, &here, me, &HashSet::new(), &Progress::default());
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
