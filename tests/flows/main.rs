use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use listenook_core::{
    podcast,
    sync::{PROTOCOL, Pake, pake_proof},
};
use nsh_app_listenook::testing::{answer, client, device_key};
use nsh_core::platform::NetworkKind;
use nsh_engine::{
    EngineConfig, Points, Root, Size,
    geometry::{point, px},
};
use nsh_testing::{DialogAnswer, DragOptions, Headless, StubNetwork, StubResponse};
use serde_json::json;

mod ai;
mod home;
mod library;
mod podcasts;
mod reader;
mod sync;

static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

const GONE: Duration = Duration::from_secs(5);

struct App {
    app: Headless,
    root: PathBuf,
    _turn: MutexGuard<'static, ()>,
}

fn response(body: impl Into<Vec<u8>>) -> StubResponse {
    let mut response = StubResponse::default();
    response.status = 200;
    response.body = body.into();
    response
}

fn start(name: &str, seed: impl FnOnce(&Path), routes: Vec<(String, StubResponse)>) -> App {
    let turn = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let root = std::env::temp_dir().join(format!("listenook-flow-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    unsafe {
        std::env::set_var("LISTENOOK_DATA_DIR", &root);
        std::env::set_var("LISTENOOK_MEMORY_SECRETS", "1");
        std::env::set_var("SONIOX_API_KEY", "test-key");
        std::env::remove_var("LISTENOOK_START");
        std::env::remove_var("LISTENOOK_TABLET_MENUS");
        std::env::remove_var("LISTENOOK_SYNC_PORT");
        std::env::remove_var("LISTENOOK_CAPTURE");
        std::env::remove_var("LISTENOOK_UPLOAD_URL");
    }
    // Uploads leave over their own connection, which the stubbed network never sees: a local
    // server gives them the response the test routed for them.
    if let Some((_, uploaded)) =
        routes.iter().find(|(route, _)| route.starts_with("POST ") && route.ends_with("/v1/files"))
    {
        unsafe { std::env::set_var("LISTENOOK_UPLOAD_URL", upload_server(uploaded.clone())) };
    }
    seed(&root);
    let app = Headless::start(EngineConfig {
        viewport: Size::new(Points(1200.0), Points(800.0)),
        network: Some(Arc::new(StubNetwork::new(routes))),
        ..EngineConfig::new(Root::of::<nsh_app_listenook::App>())
    })
    .unwrap();
    let mut app = app;
    app.wait_for("Library").unwrap();
    app.press("Library").unwrap();
    App { app, root, _turn: turn }
}

/// A server on this machine that reads each upload whole and answers it with `reply`: its URL.
fn upload_server(reply: StubResponse) -> String {
    use std::io::{BufRead, BufReader, Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/v1/files", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(&stream);
            let mut length = 0;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line.trim().is_empty() {
                    break;
                }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or(0);
                }
            }
            let _ = std::io::copy(&mut reader.take(length), &mut std::io::sink());
            let head = format!("HTTP/1.1 {} Stub\r\nContent-Length: {}\r\n\r\n", reply.status, reply.body.len());
            let _ = (&stream).write_all(&[head.as_bytes(), &reply.body].concat());
        }
    });
    url
}

fn on_port(port: u16) -> impl FnOnce(&Path) {
    move |root| {
        unsafe { std::env::set_var("LISTENOOK_SYNC_PORT", port.to_string()) };
        seed_transcript(root);
    }
}

/// Where the other device in a sync keeps its key, beside this device's library.
fn other_library(root: &Path) -> PathBuf {
    PathBuf::from(format!("{}-other", root.display()))
}

fn paired_on_port(port: u16) -> impl FnOnce(&Path) {
    move |root| {
        on_port(port)(root);
        std::fs::write(root.join("settings.json"), json!({"sync_device_id": "this-device"}).to_string()).unwrap();
        let ledger = json!({"circle": {"id": "circle", "members": {
            "this-device": {"name": "This", "platform": "macos", "joined_at": "2026-11-01T00:00:00.000Z", "key": device_key(root)},
            "other": {"name": "Studio Mac", "platform": "macos", "joined_at": "2026-11-01T00:00:00.000Z", "key": device_key(&other_library(root))},
        }}});
        std::fs::write(root.join("sync.json"), ledger.to_string()).unwrap();
    }
}

/// A body that gives what it holds, then fails as a connection that drops does, once `pause`
/// has let this device read what was sent.
struct Breaks {
    held: std::io::Cursor<&'static [u8]>,
    pause: Duration,
}

impl Breaks {
    fn after(held: &'static [u8], pause: Duration) -> Breaks {
        Breaks { held: std::io::Cursor::new(held), pause }
    }
}

impl std::io::Read for Breaks {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        match self.held.read(buffer)? {
            0 => {
                std::thread::sleep(self.pause);
                Err(std::io::Error::other("the connection dropped"))
            }
            read => Ok(read),
        }
    }
}

fn other_device(port: u16) -> serde_json::Value {
    json!({"app": "listenook", "protocol": PROTOCOL, "id": "other", "name": "Studio Mac", "platform": "macos", "port": port})
}

/// The other device, which goes on only with this one.
fn other(root: &Path) -> ureq::Agent {
    client(&other_library(root), Some(&device_key(root)), None)
}

/// The other device starts a sync with this one at `base`: what it was welcomed with.
fn hello_to(root: &Path, base: &str, hello: serde_json::Value) -> Result<serde_json::Value, String> {
    let agent = other(root);
    for _ in 0..50 {
        let welcome = match agent.post(&format!("{base}/sync")).send_string(&hello.to_string()) {
            Ok(response) => response.into_string().map_err(|error| error.to_string())?,
            Err(ureq::Error::Transport(_)) => {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
            Err(error) => return Err(error.to_string()),
        };
        return serde_json::from_str(&welcome).map_err(|error| error.to_string());
    }
    Err("the device never answered".into())
}

/// One request to a device played by a test, over TLS: its path, its headers in lower case,
/// its body, and where the answer goes.
struct Asked<S> {
    path: String,
    headers: Vec<String>,
    body: Vec<u8>,
    peer: String,
    stream: S,
}

fn asked<S: std::io::Read + std::io::Write>((stream, peer): (S, String)) -> Asked<S> {
    use std::io::{BufRead, BufReader, Read};
    let mut reader = BufReader::new(stream);
    let mut first = String::new();
    reader.read_line(&mut first).unwrap();
    let mut headers = Vec::new();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line.trim().is_empty() {
            break;
        }
        headers.push(line.trim().to_ascii_lowercase());
    }
    let length: usize =
        headers.iter().find_map(|header| header.strip_prefix("content-length:")?.trim().parse().ok()).unwrap_or(0);
    let mut body = vec![0_u8; length];
    reader.read_exact(&mut body).unwrap();
    let path = first.split(' ').nth(1).unwrap_or("").to_owned();
    // What the reader holds beyond the request is nothing: the client waits for the answer.
    Asked { path, headers, body, peer, stream: reader.into_inner() }
}

impl<S: std::io::Write> Asked<S> {
    fn header(&self, name: &str) -> Option<String> {
        self.headers.iter().find_map(|header| Some(header.strip_prefix(name)?.strip_prefix(':')?.trim().to_owned()))
    }

    fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or_default()
    }

    fn reply(mut self, text: &str) {
        let _ = self.stream.write_all(text.as_bytes());
        let _ = self.stream.flush();
    }

    fn answer(self, status: u16, body: serde_json::Value) {
        let body = body.to_string();
        self.reply(&format!(
            "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        ));
    }
}

fn manifest(root: &Path, id: &str) -> PathBuf {
    root.join("jobs").join(id).join("manifest.json")
}

fn seed_transcript(root: &Path) {
    let sentences = [
        ("Welcome back to the show.", "欢迎回到节目。"),
        ("Today we are talking about how people learn languages.", "今天我们来聊聊人们如何学习语言。"),
        ("Listening every day matters more than studying hard once a week.", "每天听一点更重要。"),
        ("So, what should a beginner do first?", "那么，初学者应该先做什么？"),
        ("Start with short episodes, and repeat each sentence out loud.", "从短的节目开始。"),
    ];
    let segments: Vec<_> = sentences
        .iter()
        .enumerate()
        .map(|(index, (text, translated))| {
            json!({
                "id": format!("segment-{}", index + 1), "start_ms": index * 3000, "end_ms": index * 3000 + 2800,
                "text": text, "translated_text": translated, "speaker": "1", "language": "en",
            })
        })
        .collect();
    let job = json!({
        "manifest_version": 15, "id": "sample", "source_path": "/nowhere/Learning languages.m4a",
        "created_at": "2026-11-10T08:00:00.000Z", "status": "completed",
        "document": {"segments": segments, "speakers": [{"id": "1", "name": "Host"}], "updated_at": "2026-11-10T08:00:00.000Z"},
    });
    std::fs::create_dir_all(root.join("jobs/sample")).unwrap();
    std::fs::write(manifest(root, "sample"), job.to_string()).unwrap();
}

fn open_sample(name: &str) -> App {
    let mut it = start(name, seed_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it
}

fn seed_activity(root: &Path) {
    use listenook_core::activity::{Days, day_key, today};
    let today = today();
    let mut days = serde_json::Map::new();
    days.insert(day_key(today), json!({"listen_s": 720, "practice_s": 360}));
    for back in 1..=4 {
        days.insert(day_key(today - Days::new(back)), json!({"listen_s": 900, "practice_s": 400}));
    }
    let log = json!({"version": 1, "devices": {"another-device": days}});
    std::fs::write(root.join("activity.json"), log.to_string()).unwrap();
}

fn seed_long_transcript(root: &Path) {
    let segments: Vec<_> = (0..60)
        .map(|index| {
            json!({
                "id": format!("segment-{}", index + 1), "start_ms": index * 3000, "end_ms": index * 3000 + 2800,
                "text": format!("Sentence {} says something about learning.", index + 1),
                "translated_text": format!("第{}句。", index + 1), "speaker": "1", "language": "en",
            })
        })
        .collect();
    let job = json!({
        "manifest_version": 15, "id": "sample", "source_path": "/nowhere/Learning languages.m4a",
        "created_at": "2026-11-10T08:00:00.000Z", "status": "completed",
        "document": {"segments": segments, "speakers": [{"id": "1", "name": "Host"}], "updated_at": "2026-11-10T08:00:00.000Z"},
    });
    std::fs::create_dir_all(root.join("jobs/sample")).unwrap();
    std::fs::write(manifest(root, "sample"), job.to_string()).unwrap();
}

fn seed_with_skipped(root: &Path) {
    seed_transcript(root);
    let path = manifest(root, "sample");
    let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    job["document"]["segments"][1]["skipped"] = json!(true);
    std::fs::write(path, job.to_string()).unwrap();
}

fn llm(root: &Path, content: &str) -> Vec<(String, StubResponse)> {
    let settings = json!({"llm_provider_settings": {"provider": "lmStudio", "base_url": "http://localhost:1234/v1", "model": "local-model"}});
    std::fs::write(root.join("settings.json"), settings.to_string()).unwrap();
    let reply = json!({"choices": [{"message": {"content": content}}]});
    vec![("POST http://localhost:1234/v1/chat/completions".to_owned(), response(reply.to_string()))]
}

fn llm_routes(content: &str) -> Vec<(String, StubResponse)> {
    llm(&std::env::temp_dir(), content)
}

fn seed_highlight(root: &Path, segment: usize, words: &str) {
    let path = manifest(root, "sample");
    let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let entry = &mut job["document"]["segments"][segment];
    let text = entry["text"].as_str().unwrap().to_owned();
    let start = text.find(words).unwrap();
    entry["highlights"] = json!([{"start": start, "end": start + words.len()}]);
    std::fs::write(path, job.to_string()).unwrap();
}

fn open_brief(it: &mut App) {
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:AI Brief").unwrap();
    it.app.press("role:button[Create AI Brief]").unwrap();
}

fn translation_box(it: &mut App, wanted: &str) {
    let wanted = wanted.to_owned();
    it.app
        .wait_until("the translation box to fill", Duration::from_secs(5), move |screen| {
            screen.input_text("id:translation-editor").ok().flatten() == Some(wanted.as_str())
        })
        .unwrap();
}

fn fake_capture(_: &Path) {
    unsafe { std::env::set_var("LISTENOOK_CAPTURE", "fake") };
}

fn left_files(folder: &Path, start: &str) -> Vec<String> {
    std::fs::read_dir(folder)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with(start))
        .collect()
}
