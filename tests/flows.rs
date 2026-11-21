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
use nsh_engine::{
    EngineConfig, Points, Root, Size,
    geometry::{point, px},
};
use nsh_testing::{DialogAnswer, Headless, StubNetwork, StubResponse};
use serde_json::json;

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

#[test]
fn the_sleep_timer_shows_what_is_left_until_it_is_turned_off() {
    let mut it = open_sample("sleep");
    it.app.press("label:Sleep timer").unwrap();
    it.app.press("15 minutes").unwrap();
    it.app.wait_for("15:00").unwrap();
    it.app.press("label:Sleep timer").unwrap();
    it.app.press("When this recording ends").unwrap();
    it.app.wait_for_gone("15:00", GONE).unwrap();
    it.app.press("label:Sleep timer").unwrap();
    it.app.press("Off").unwrap();
    assert!(!it.app.shows("15:00"));
}

#[test]
fn home_resumes_what_was_played_last_and_lists_what_was_added() {
    let mut it = start(
        "home",
        |root| {
            seed_transcript(root);
            let settings = json!({
                "playback_positions_ms": {"sample": 6000},
                "playback_played_at": {"sample": "2026-11-15T10:00:00.000Z"},
            });
            std::fs::write(root.join("settings.json"), settings.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Continue").unwrap();
    assert!(it.app.shows("Recently added"));
    it.app.press("label:Search").unwrap();
    it.app.type_text("text:Search your library", "nothing like this").unwrap();
    it.app.wait_for("No recordings match your search.").unwrap();
    it.app.press_key("escape").unwrap();
    it.app.wait_for("Recently added").unwrap();
    it.app.press("label:Resume Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
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

#[test]
fn home_shows_today_against_the_goal_and_the_days_before() {
    let mut it = start(
        "home-activity",
        |root| {
            seed_transcript(root);
            seed_activity(root);
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Today").unwrap();
    assert!(it.app.shows("of 20 min"));
    assert!(it.app.shows("12 min"));
    assert!(it.app.shows("6 min"));
    assert!(it.app.shows("4-day streak"));
    assert!(it.app.shows("2 min to go"));
    assert!(it.app.shows("Activity"));
    it.app.wait_for("label:Learning time, last 7 days").unwrap();
    it.app.press("Month").unwrap();
    it.app.wait_for("label:Learning time, last 30 days").unwrap();
    it.app.press("label:Daily goal").unwrap();
    it.app.press("10 min a day").unwrap();
    it.app.wait_for("Goal met").unwrap();
    it.app.wait_for("5-day streak").unwrap();
    let settings = std::fs::read_to_string(it.root.join("settings.json")).unwrap();
    assert!(settings.contains("\"daily_goal_minutes\": 10"), "{settings}");
}

#[test]
fn home_starts_today_at_nothing_without_history() {
    let mut it = start("home-no-activity", seed_transcript, Vec::new());
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Play something to start today's minutes.").unwrap();
    assert!(it.app.shows("of 20 min"));
    assert!(!it.app.shows("Activity"));
}

#[test]
fn a_card_comes_off_continue_and_recently_added_until_it_is_opened_again() {
    let mut it = start(
        "home-remove",
        |root| {
            seed_transcript(root);
            let settings = json!({
                "playback_positions_ms": {"sample": 6000},
                "playback_played_at": {"sample": "2026-11-15T10:00:00.000Z"},
            });
            std::fs::write(root.join("settings.json"), settings.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("label:Resume Learning languages").unwrap();

    it.app.long_press("label:Resume Learning languages").unwrap();
    it.app.press("Remove from Continue").unwrap();
    it.app.wait_for_gone("label:Resume Learning languages", GONE).unwrap();
    it.app.press("role:button[Undo]").unwrap();
    it.app.wait_for("label:Resume Learning languages").unwrap();

    it.app.long_press("label:Resume Learning languages").unwrap();
    it.app.press("Remove from Continue").unwrap();
    it.app.wait_for_gone("label:Resume Learning languages", GONE).unwrap();
    assert!(it.app.shows("Recently added"), "the recording itself stays");
    let settings = std::fs::read_to_string(it.root.join("settings.json")).unwrap();
    assert!(settings.contains("continue_hidden"), "the removal is kept");

    it.app.long_press("Learning languages").unwrap();
    it.app.press("Remove from Recently added").unwrap();
    it.app.wait_for_gone("Recently added", GONE).unwrap();
    assert!(manifest(&it.root, "sample").exists(), "nothing is deleted");

    it.app.press("Library").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:Back").unwrap();
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("label:Resume Learning languages").unwrap();
    assert!(!it.app.shows("Recently added"), "only Continue comes back");
}

#[test]
fn an_empty_library_invites_media_and_the_language_changes_at_once() {
    let mut it = start("empty", |_| {}, Vec::new());
    it.app.wait_for("Drop audio or video here").unwrap();
    it.app.press("role:button[Settings]").unwrap();
    it.app.wait_for("Appearance").unwrap();
    it.app.press("简体中文").unwrap();
    it.app.wait_for("资料库").unwrap();
    let settings = std::fs::read_to_string(it.root.join("settings.json")).unwrap();
    assert!(settings.contains("simplifiedChinese"), "the choice is saved");
}

#[test]
fn a_transcript_opens_from_the_library_and_search_filters_it() {
    let mut it = open_sample("search");
    assert!(it.app.shows("欢迎回到节目。"), "a translated transcript opens bilingual");
    it.app.press("label:Search transcript").unwrap();
    it.app.type_text("text:Search transcript", "beginner").unwrap();
    it.app.wait_for_gone("Welcome back to the show.", GONE).unwrap();
    it.app.press("label:Clear search").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.wait_for_gone("label:Clear search", GONE).unwrap();
}

#[test]
fn scrolling_away_from_the_sentence_playing_offers_a_way_back_to_it() {
    let mut it = start("follow", seed_long_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Sentence 1 says something about learning.").unwrap();
    it.app.press("Sentence 2 says something about learning.").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
    assert!(!it.app.shows("Jump to playing"), "nothing to jump to while the list follows");
    it.app.scroll("Sentence 3 says something about learning.", px(1500.0)).unwrap();
    it.app.wait_for("Jump to playing").unwrap();
    it.app.press("Jump to playing").unwrap();
    it.app.wait_for("Sentence 2 says something about learning.").unwrap();
    it.app.wait_for_gone("Jump to playing", GONE).unwrap();
}

#[test]
fn command_b_in_the_reader_hides_the_sidebar_unless_words_are_selected() {
    let mut it = open_sample("command-b");
    assert!(it.app.shows("Podcasts"), "the sidebar shows beside the reader");
    it.app.press_key("mod+b").unwrap();
    it.app.wait_for_gone("Podcasts", GONE).unwrap();
    it.app.press_key("mod+b").unwrap();
    it.app.wait_for("Podcasts").unwrap();
}

#[test]
fn view_modes_show_the_original_the_translation_or_both() {
    let mut it = open_sample("modes");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Translated").unwrap();
    it.app.wait_for_gone("Welcome back to the show.", GONE).unwrap();
    assert!(it.app.shows("欢迎回到节目。"));
    it.app.press("role:button[Translated]").unwrap();
    it.app.press("Original").unwrap();
    it.app.wait_for_gone("欢迎回到节目。", GONE).unwrap();
    assert!(it.app.shows("Welcome back to the show."));
}

#[test]
fn an_edited_sentence_is_saved_to_the_manifest() {
    let mut it = open_sample("edit");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("Welcome to the programme.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("Welcome to the programme."));
}

#[test]
fn one_edit_changes_the_sentence_and_its_translation() {
    let mut it = open_sample("edit-both");
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.clear("id:translation-editor").unwrap();
    it.app.type_text("id:translation-editor", "欢迎收听节目。").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("欢迎收听节目。").unwrap();
    assert!(it.app.shows("Welcome to the programme."));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("Welcome to the programme."));
    assert!(saved.contains("欢迎收听节目。"));
}

#[test]
fn a_tap_on_the_repeat_button_loops_the_sentence_and_a_tap_on_any_looping_one_ends_it() {
    let mut it = open_sample("repeat-tap");
    let rails = |it: &App| it.app.screen().count("id:repeat-rail").unwrap();
    it.app.press("label:Repeat sentence >> nth=1").unwrap();
    it.app.wait_for("id:repeat-rail").unwrap();
    assert_eq!(rails(&it), 1);
    it.app.press("Today we are talking about how people learn languages.").unwrap();
    assert_eq!(rails(&it), 1, "a tap on the sentence itself plays it and keeps the repeat");
    it.app.press("label:Repeat sentence >> nth=1").unwrap();
    it.app.wait_for_gone("id:repeat-rail", GONE).unwrap();
}

#[test]
fn dragging_the_repeat_button_loops_every_sentence_the_finger_passes() {
    let mut it = open_sample("repeat-drag");
    let rails = |it: &App| it.app.screen().count("id:repeat-rail").unwrap();
    it.app.drag_and_hold("label:Repeat sentence >> nth=0", point(px(0.0), px(160.0))).unwrap();
    let held = rails(&it);
    assert!(held > 1, "the repeat grows while the finger is still down: {held}");
    it.app.drop_held().unwrap();
    assert_eq!(rails(&it), held, "lifting the finger keeps the repeat");
    it.app.drag("label:Repeat sentence >> nth=3", point(px(0.0), px(-1000.0))).unwrap();
    assert_eq!(rails(&it), 4, "dragged up, the repeat runs from the top sentence to the one the drag started on");
    it.app.press("label:Repeat sentence >> nth=1").unwrap();
    it.app.wait_for_gone("id:repeat-rail", GONE).unwrap();
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

#[test]
fn a_short_repeat_drag_after_scrolling_takes_in_a_sentence_or_two() {
    let mut it = start("repeat-scrolled", seed_long_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Sentence 1 says something about learning.").unwrap();
    it.app.drag("Sentence 3 says something about learning.", point(px(0.0), px(-700.0))).unwrap();
    it.app.drag("Sentence 12 says something about learning.", point(px(0.0), px(300.0))).unwrap();
    it.app.drag("label:Repeat sentence >> nth=8", point(px(0.0), px(90.0))).unwrap();
    let rails = it.app.screen().count("id:repeat-rail").unwrap();
    assert!((2..=3).contains(&rails), "a short drag takes in a sentence or two: {rails}");
}

#[test]
fn holding_a_repeat_drag_near_the_bottom_edge_scrolls_and_keeps_stretching_the_repeat() {
    let mut it = start("repeat-autoscroll", seed_long_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Sentence 1 says something about learning.").unwrap();
    it.app.drag_and_hold("label:Repeat sentence >> nth=0", point(px(0.0), px(680.0))).unwrap();
    it.app.wait(Duration::from_millis(1500)).unwrap();
    it.app.drop_held().unwrap();
    assert!(!it.app.shows("Sentence 1 says something about learning."), "the list scrolled");
    let rails = it.app.screen().count("id:repeat-rail").unwrap();
    assert!(rails > 5, "the repeat reached sentences that were below the fold: {rails}");
}

#[test]
fn saving_an_emptied_sentence_deletes_it() {
    let mut it = open_sample("delete");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for_gone("role:button[Save]", GONE).unwrap();
    assert!(!it.app.shows("Welcome back to the show."));
    assert!(it.app.shows("Today we are talking about how people learn languages."));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("segment-1\""));
    assert!(saved.contains("segment-2"));

    it.app.press("role:button[Undo]").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("segment-1\""), "Undo puts the sentence back");
}

#[test]
fn deleting_a_sentence_from_the_editor_can_be_undone() {
    let mut it = open_sample("delete-button");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=1").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.press("label:More sentence actions").unwrap();
    it.app.press("Delete sentence").unwrap();
    it.app.wait_for_gone("Today we are talking about how people learn languages.", GONE).unwrap();
    it.app.wait_for("Sentence deleted").unwrap();
    it.app.press_key("mod+z").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
    it.app.press_key("mod+z").unwrap();
    assert!(it.app.shows("Today we are talking about how people learn languages."), "one step back only");
}

#[test]
fn a_skipped_sentence_folds_away_and_comes_back() {
    let mut it = open_sample("skip");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=1").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.press("label:More sentence actions").unwrap();
    it.app.press("Skip this sentence").unwrap();
    it.app.wait_for_gone("Today we are talking about how people learn languages.", GONE).unwrap();
    it.app.wait_for("Skipped · 00:02").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""skipped": true"#), "the skip is saved");
    it.app.press("role:button[Bring back]").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
    assert!(!it.app.shows("Skipped · 00:02"));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains(r#""skipped""#), "bringing it back leaves no trace");
}

fn seed_with_skipped(root: &Path) {
    seed_transcript(root);
    let path = manifest(root, "sample");
    let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    job["document"]["segments"][1]["skipped"] = json!(true);
    std::fs::write(path, job.to_string()).unwrap();
}

#[test]
fn the_arrow_keys_step_over_a_skipped_sentence() {
    let mut it = start("arrows-skip", seed_with_skipped, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press_key("right").unwrap();
    it.app.wait_for("00:05").unwrap();
    assert!(!it.app.shows("00:02"), "the skipped sentence is not a stop");
    it.app.press_key("left").unwrap();
    it.app.wait_for_gone("00:05", GONE).unwrap();
    assert!(!it.app.shows("00:02"));
}

#[test]
fn a_stretch_of_sentences_is_skipped_by_picking_its_first_and_last() {
    let mut it = open_sample("skip-range");
    it.app.long_press("Welcome back to the show.").unwrap();
    it.app.press("Skip from here…").unwrap();
    it.app.wait_for("Now tap the last sentence to skip.").unwrap();
    // The menu takes Escape until it has faded out; the key is for the reader once it is gone.
    it.app.wait_for_gone("role:menu", GONE).unwrap();
    it.app.press_key("escape").unwrap();
    it.app.wait_for_gone("Now tap the last sentence to skip.", GONE).unwrap();
    it.app.press("Start with short episodes, and repeat each sentence out loud.").unwrap();
    assert!(it.app.shows("Welcome back to the show."), "Escape leaves nothing half picked");

    it.app.long_press("So, what should a beginner do first?").unwrap();
    it.app.press("Skip from here…").unwrap();
    it.app.wait_for("Now tap the last sentence to skip.").unwrap();
    it.app.press("Today we are talking about how people learn languages.").unwrap();
    it.app.wait_for("Skipped · 00:08").unwrap();
    assert!(!it.app.shows("Now tap the last sentence to skip."));
    assert!(!it.app.shows("Listening every day matters more than studying hard once a week."));
    assert!(!it.app.shows("So, what should a beginner do first?"));
    assert!(it.app.shows("Welcome back to the show."));
    assert!(it.app.shows("Start with short episodes, and repeat each sentence out loud."));
}

#[test]
fn the_ai_finds_ads_and_they_are_skipped_on_one_tap() {
    let reply = json!({"ads": [{"first": "segment-2", "last": "segment-3", "reason": "sponsor read"}]});
    let routes = llm_routes(&reply.to_string());
    let mut it = start(
        "find-ads",
        |root| {
            seed_transcript(root);
            let _ = llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:More actions").unwrap();
    it.app.press("Find ads").unwrap();
    it.app.wait_for("Ads found: 1 · 00:05").unwrap();
    assert!(it.app.shows("Today we are talking about how people learn languages."), "nothing is skipped yet");
    it.app.press("role:button[Skip them]").unwrap();
    it.app.wait_for_gone("Today we are talking about how people learn languages.", GONE).unwrap();
    assert!(!it.app.shows("Listening every day matters more than studying hard once a week."));
    it.app.wait_for("Skipped · 00:05").unwrap();
    assert!(!it.app.shows("Ads found: 1 · 00:05"), "the findings are done with");
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert_eq!(saved.matches(r#""skipped": true"#).count(), 2);
    assert!(!saved.contains("ad_scan"), "nothing is left waiting");
}

#[test]
fn the_arrow_keys_move_between_sentences() {
    let mut it = open_sample("arrows");
    it.app.press_key("right").unwrap();
    it.app.wait_for("00:02").unwrap();
    it.app.press_key("right").unwrap();
    it.app.wait_for("00:05").unwrap();
    it.app.press_key("left").unwrap();
    it.app.wait_for("00:02").unwrap();
    assert!(!it.app.shows("00:05"));
}

#[test]
fn tapping_a_sentence_plays_from_there() {
    let mut it = open_sample("tap-plays");
    it.app.press("Listening every day matters more than studying hard once a week.").unwrap();
    it.app.wait_for("00:05").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
    it.app.press("So, what should a beginner do first?").unwrap();
    it.app.wait_for("00:08").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
}

#[test]
fn dictation_checks_the_answer_without_showing_the_sentence() {
    let mut it = open_sample("dictation");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:Type what you hear").unwrap();
    it.app.wait_for("label:Hidden sentence").unwrap();
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Listen again and retry.").unwrap();
    it.app.wait_for("label:Checked answer").unwrap();
    assert!(it.app.shows("…"), "the missing word is marked without showing it");
    it.app.wait_for("Type the missing word where the caret is.").unwrap();
    // The missing word gets a space of its own to be typed into.
    it.app.clear("text:welcome  to the show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    // A word typed wrong comes selected, to type over.
    it.app.type_text("text:Type what you hear", "welcome back to a show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Type to replace the first mistake.").unwrap();
    // Missed twice: a hint, first letters then the word, and slower.
    it.app.wait_for("Playing slower: 0.75×").unwrap();
    it.app.press("role:button[Hint]").unwrap();
    it.app.wait_for("Hint: t••").unwrap();
    it.app.press("role:button[Show word]").unwrap();
    it.app.wait_for("Hint: the").unwrap();
    it.app.clear("text:welcome back to a show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    // A letter off is close, not wrong.
    it.app.type_text("text:Type what you hear", "welcome bak to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Close: check the spelling, and type to replace it.").unwrap();
    it.app.clear("text:welcome bak to the show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Matches transcript").unwrap();
    // Mimic shares the card, and Practice opens in the mode used last.
    it.app.press("Mimic").unwrap();
    it.app.wait_for("Reps").unwrap();
    // The card steps between sentences itself, without the transport.
    it.app.press("label:Next sentence >> nth=0").unwrap();
    it.app.wait_for("text:/^Sentence 2 ·/").unwrap();
    it.app.wait_for_gone("text:Type what you hear", GONE).unwrap();
    it.app.press("label:Practice").unwrap();
    it.app.wait_for_gone("Reps", GONE).unwrap();
    it.app.press("label:Practice").unwrap();
    it.app.wait_for("Reps").unwrap();
}

#[test]
fn type_answer_remembers_the_sentences_missed_and_goes_back_over_them() {
    let mut it = open_sample("dictation-review");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:/^Sentence 1 ·/").unwrap();
    let saved = || std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    // Wrong at the first check: to review, kept with the recording.
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.submit("text:welcome to the show").unwrap();
    it.app.wait_for("Missed 1").unwrap();
    it.app.wait_for("Sentence 1 · 0/1 first try").unwrap();
    assert!(saved().contains("\"to_review\": true"), "the miss is saved");
    // Right after a miss, it stays to review; the next one comes.
    it.app.clear("text:welcome  to the show").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    it.app.wait_for("text:/^Sentence 2 ·/").unwrap();
    assert!(it.app.shows("Missed 1"));
    // Missed only: back to it; right at the first try now, it is done with.
    it.app.press("Missed 1").unwrap();
    it.app.wait_for("text:/^Sentence 1 ·/").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    it.app.wait_for("That's all to review.").unwrap();
    it.app.wait_for("Right at the first try: 1/2").unwrap();
    it.app.wait_for_gone("Missed 1", GONE).unwrap();
    // The sentence's own controls leave with it: the summary has its own.
    it.app.wait_for_gone("role:button[Check]", GONE).unwrap();
    assert!(!it.app.shows("label:Replay"));
    assert!(!it.app.shows("text:/^Sentence 1 ·/"));
    assert!(!saved().contains("to_review"), "done with, it is no longer saved as missed");
}

#[test]
fn dictation_checks_on_return_and_moves_on_by_itself() {
    let mut it = open_sample("dictation-return");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:/^Sentence 1 ·/").unwrap();
    it.app.wait_for("label:Hidden sentence >> nth=4").unwrap();
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.submit("text:welcome to the show").unwrap();
    it.app.wait_for("Listen again and retry.").unwrap();
    it.app.wait_for("label:Checked answer").unwrap();
    it.app.submit("text:welcome  to the show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    it.app.clear("text:welcome  to the show").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    it.app.wait_for("Matches transcript").unwrap();
    // The return repeated a moment later (iPadOS does, 0.6 s on) leaves the
    // marks up: the next sentence comes by itself.
    it.app.wait(Duration::from_millis(700)).unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    assert!(it.app.shows("Matches transcript"), "a repeated return does not skip the marks");
    it.app.wait_for("text:/^Sentence 2 ·/").unwrap();
    it.app.wait_for("text:Type what you hear").unwrap();
    // The sentence typed right stays shown: four of the five are hidden.
    it.app.wait_for_gone("label:Hidden sentence >> nth=4", GONE).unwrap();
    it.app.wait_for("label:Hidden sentence >> nth=3").unwrap();
}

#[test]
fn removing_a_recording_asks_first_and_deletes_it() {
    let mut it = start("remove", seed_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();

    it.app.on_dialog(|_| DialogAnswer::Press("Cancel".to_owned()));
    it.app.press("label:More actions").unwrap();
    it.app.press("Remove…").unwrap();
    it.app.wait_for("Learning languages").unwrap();
    assert!(manifest(&it.root, "sample").exists(), "Cancel removes nothing");

    it.app.on_dialog(|dialog| {
        assert_eq!(dialog.title.as_deref(), Some("Remove “Learning languages”?"));
        DialogAnswer::Press("Remove".to_owned())
    });
    it.app.press("label:More actions").unwrap();
    it.app.press("Remove…").unwrap();
    it.app.wait_for("Drop audio or video here").unwrap();
    assert!(!manifest(&it.root, "sample").exists());
    let removed = std::fs::read_to_string(it.root.join("removed.json")).unwrap();
    assert!(removed.contains("sample"), "a sync is told of the removal");
}

#[test]
fn a_tablet_menu_still_closes_on_a_choice_after_its_page_was_left() {
    let mut it = start(
        "tablet-menu",
        |root| {
            unsafe { std::env::set_var("LISTENOOK_TABLET_MENUS", "1") };
            seed_transcript(root);
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("role:button[Podcasts]").unwrap();
    it.app.wait_for_gone("Learning languages", GONE).unwrap();
    it.app.press("Library").unwrap();
    it.app.wait_for("Learning languages").unwrap();

    it.app.on_dialog(|_| DialogAnswer::Press("Cancel".to_owned()));
    it.app.press("label:More actions").unwrap();
    it.app.wait_for("Rename…").unwrap();
    it.app.press("Remove…").unwrap();
    it.app.wait_for_gone("Rename…", GONE).unwrap();
}

#[test]
fn a_ready_job_is_transcribed_by_soniox_and_cleaned_up() {
    let routes = vec![
        ("POST https://api.soniox.com/v1/files".to_owned(), response(r#"{"id":"file-1"}"#)),
        ("POST https://api.soniox.com/v1/transcriptions".to_owned(), response(r#"{"id":"tr-1"}"#)),
        ("GET https://api.soniox.com/v1/transcriptions/tr-1".to_owned(), response(r#"{"status":"completed"}"#)),
        (
            "GET https://api.soniox.com/v1/transcriptions/tr-1/transcript".to_owned(),
            response(
                r#"{"tokens":[{"text":"Hello","start_ms":0,"end_ms":400,"speaker":"1"},{"text":" world.","start_ms":400,"end_ms":900,"speaker":"1"}]}"#,
            ),
        ),
        ("DELETE https://api.soniox.com/v1/transcriptions/tr-1".to_owned(), response("")),
        ("DELETE https://api.soniox.com/v1/files/file-1".to_owned(), response("")),
    ];
    let mut it = start(
        "transcribe",
        |root| {
            let media = root.join("Standup.mp3");
            std::fs::write(&media, b"not really audio").unwrap();
            let job =
                json!({"id": "queued", "source_path": media, "status": "ready", "transcription_provider": "soniox"});
            std::fs::create_dir_all(root.join("jobs/queued")).unwrap();
            std::fs::write(manifest(root, "queued"), job.to_string()).unwrap();
        },
        routes,
    );
    it.app.wait_for("Standup").unwrap();
    it.app.press("role:button[Transcribe]").unwrap();
    it.app.wait_for_gone("role:button[Transcribe]", GONE).unwrap();
    it.app.press("Standup").unwrap();
    it.app.wait_for("Hello world.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "queued")).unwrap();
    assert!(saved.contains(r#""status": "completed""#));
    assert!(saved.contains(r#""cleanup_state": "complete""#), "the upload was deleted from the provider");
}

#[test]
fn a_failed_transcription_says_why_and_can_be_retried() {
    let mut denied = response(r#"{"error_type":"unauthorized","error_message":"bad key"}"#);
    denied.status = 401;
    let mut it = start(
        "failure",
        |root| {
            let media = root.join("Standup.mp3");
            std::fs::write(&media, b"not really audio").unwrap();
            let job = json!({"id": "queued", "source_path": media, "status": "ready"});
            std::fs::create_dir_all(root.join("jobs/queued")).unwrap();
            std::fs::write(manifest(root, "queued"), job.to_string()).unwrap();
        },
        vec![("POST https://api.soniox.com/v1/files".to_owned(), denied)],
    );
    it.app.wait_for("Standup").unwrap();
    it.app.press("role:button[Transcribe]").unwrap();
    it.app.wait_for("The API key was rejected. Check it in Settings.").unwrap();
    it.app.press("role:button[Retry]").unwrap();
    it.app.wait_for_gone("The API key was rejected. Check it in Settings.", GONE).unwrap();
}

#[test]
fn a_show_opens_from_discover_and_lists_its_episodes() {
    const FEED: &str = r#"<rss><channel><title>Daily English</title><author>BBC</author>
<item><title>Episode two</title><guid>g2</guid><pubDate>Tue, 04 Mar 2025 10:00:00 GMT</pubDate><enclosure url="https://cdn.example/b.mp3" type="audio/mpeg"/></item>
<item><title>Episode one</title><guid>g1</guid><pubDate>Mon, 03 Mar 2025 10:00:00 GMT</pubDate><enclosure url="https://cdn.example/a.mp3" type="audio/mpeg"/></item>
</channel></rss>"#;
    let lookup = r#"{"results":[{"kind":"podcast","collectionId":7,"collectionName":"Daily English","feedUrl":"https://feeds.example/daily","artistName":"BBC","artworkUrl100":""}]}"#;
    let mut it = start(
        "podcast",
        |_| {},
        vec![
            (format!("GET {}", podcast::lookup_url(podcast::FEATURED_IDS)), response(lookup)),
            ("GET https://feeds.example/daily".to_owned(), response(FEED)),
        ],
    );
    it.app.wait_for("Drop audio or video here").unwrap();
    it.app.press("role:button[Podcasts]").unwrap();
    it.app.wait_for("Daily English").unwrap();
    it.app.press("Daily English").unwrap();
    it.app.wait_for("Episode two").unwrap();
    assert!(it.app.shows("Episode one"));
    it.app.press("role:button[Follow]").unwrap();
    it.app.wait_for("role:button[Unfollow]").unwrap();
    let catalog = std::fs::read_to_string(it.root.join("podcast_catalog.json")).unwrap();
    assert!(catalog.contains("https://feeds.example/daily"), "the followed show is saved");
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

#[test]
fn translating_with_the_llm_fills_in_each_sentence() {
    let routes = llm_routes("1. 第一句\n2. 第二句\n3. 第三句\n4. 第四句\n5. 第五句");
    let mut it = start(
        "translate",
        |root| {
            seed_transcript(root);
            let _ = llm(root, "");
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            for segment in job["document"]["segments"].as_array_mut().unwrap() {
                segment.as_object_mut().unwrap().remove("translated_text");
            }
            std::fs::write(path, job.to_string()).unwrap();
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:More actions").unwrap();
    it.app.press("Translate…").unwrap();
    it.app.press("role:button[Translate]").unwrap();
    it.app.wait_for("第一句").unwrap();
    it.app.wait_for("第五句").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""status": "completed""#) && saved.contains("第三句"));
}

#[test]
fn an_ai_brief_is_generated_with_evidence_and_unsupported_items_dropped() {
    let brief = json!({
        "overview": "A talk about daily listening.", "overview_evidence": ["segment-2"],
        "chapters": [{"title": "Invented chapter", "summary": "No evidence.", "evidence": ["segment-99"]}],
        "insights": [{"type": "keyIdea", "text": "Consistency beats intensity.", "evidence": ["segment-3"]}],
        "language_notes": [],
    });
    let routes = llm_routes(&brief.to_string());
    let mut it = start(
        "brief",
        |root| {
            seed_transcript(root);
            let _ = llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:AI Brief").unwrap();
    it.app.wait_for("No AI Brief yet").unwrap();
    it.app.press("role:button[Create AI Brief]").unwrap();
    it.app.press("role:button[Generate]").unwrap();
    it.app.wait_for("A talk about daily listening.").unwrap();
    assert!(it.app.shows("Consistency beats intensity."));
    assert!(!it.app.shows("Invented chapter"), "a chapter citing no real sentence is dropped");
    it.app.press("label:Play from 00:03").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
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

#[test]
fn a_bolded_word_is_explained_as_the_expression_it_belongs_to() {
    let reply = json!({
        "learner_profile": "Around A2: you mark everyday phrases.",
        "highlights": [{
            "segment_id": "segment-5", "highlighted": "loud", "intent": "language", "kind": "expression",
            "term": "out loud", "explanation": "so that others can hear", "usage": "after verbs like read or say",
            "examples": ["Read it out loud."], "related": ["aloud"], "pitfalls": "", "source_excerpt": "out loud",
        }],
        "overview": "Daily listening helps.", "overview_evidence": ["segment-3"], "insights": [],
        "language_notes": [{"kind": "vocabulary", "term": "episodes", "explanation": "parts of a show",
            "source_excerpt": "episodes", "evidence": ["segment-5"]}],
    });
    let routes = llm_routes(&reply.to_string());
    let mut it = start(
        "highlight-learning",
        |root| {
            seed_transcript(root);
            seed_highlight(root, 4, "loud");
            let _ = llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    assert!(
        it.app.screen().in_selectable_view("Start with short episodes, and repeat each sentence out loud.").unwrap(),
        "a sentence can be selected"
    );
    assert!(it.app.screen().span_style("text:loud").unwrap().font_weight >= 600, "the highlight is bold");
    assert!(it.app.screen().span_style("text:Start").unwrap().font_weight < 600);
    it.app.press("label:AI Brief").unwrap();
    it.app.press("role:button[Create AI Brief]").unwrap();
    it.app.wait_for("1 highlights · the AI decides whether each is a word to learn or a key point.").unwrap();
    it.app.press("Language notes").unwrap();
    it.app.press("role:button[Generate]").unwrap();
    it.app.wait_for("From your highlights").unwrap();
    assert!(it.app.shows("out loud"));
    assert!(it.app.shows("You marked “loud”"));
    assert!(it.app.shows("Read it out loud."));
    assert!(it.app.shows("Around A2: you mark everyday phrases."));
    assert!(it.app.shows("Also worth learning") && it.app.shows("parts of a show"));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""learning_level": "auto""#), "the level follows the highlights");
}

#[test]
fn a_bolded_point_in_a_meeting_becomes_a_marked_key_idea() {
    let reply = json!({
        "learner_profile": "",
        "highlights": [{"segment_id": "segment-3", "highlighted": "Listening every day matters more than studying hard once a week.",
            "intent": "content", "point": "Daily practice beats weekly cramming."}],
        "overview": "A talk about habits.", "overview_evidence": ["segment-2"], "insights": [], "language_notes": [],
    });
    let routes = llm_routes(&reply.to_string());
    let mut it = start(
        "highlight-meeting",
        |root| {
            seed_transcript(root);
            seed_highlight(root, 2, "Listening every day matters more than studying hard once a week.");
            let _ = llm(root, "");
        },
        routes,
    );
    open_brief(&mut it);
    it.app.press("role:button[Generate]").unwrap();
    it.app.wait_for("Daily practice beats weekly cramming.").unwrap();
    assert!(it.app.screen().matches("label:You marked this").unwrap());
    assert!(!it.app.shows("From your highlights"), "a point is not a language note");
    assert!(!it.app.shows("new highlights since this brief"));
}

#[test]
fn a_highlight_follows_its_words_when_sentences_merge() {
    let mut it = start(
        "highlight-merge",
        |root| {
            seed_transcript(root);
            seed_highlight(root, 1, "learn languages");
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.press("role:button[Merge with next]").unwrap();
    it.app.wait_for("Welcome back to the show. Today we are talking about how people learn languages.").unwrap();
    assert!(it.app.screen().span_style("text:learn languages").unwrap().font_weight >= 600);
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    let merged = &saved["document"]["segments"][0];
    let text = merged["text"].as_str().unwrap();
    let (start, end) =
        (merged["highlights"][0]["start"].as_u64().unwrap(), merged["highlights"][0]["end"].as_u64().unwrap());
    assert_eq!(&text[start as usize..end as usize], "learn languages");
}

#[test]
fn a_recording_is_filed_under_a_tag_and_found_from_the_sidebar() {
    let mut it = start(
        "tags",
        |root| {
            seed_transcript(root);
            let other = json!({"id": "other", "source_path": "/nowhere/Budget review.mp3", "status": "ready"});
            std::fs::create_dir_all(root.join("jobs/other")).unwrap();
            std::fs::write(manifest(root, "other"), other.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    assert!(it.app.shows("Budget review"), "one list holds what is transcribed and what is not");
    it.app.press("label:More actions >> nth=1").unwrap();
    it.app.press("Tags…").unwrap();
    it.app.type_text("text:New tag", "shadowing").unwrap();
    it.app.press("role:button[Add]").unwrap();
    it.app.press("role:button[Done]").unwrap();
    it.app.press("role:button[shadowing 1]").unwrap();
    it.app.wait_for_gone("Budget review", GONE).unwrap();
    assert!(it.app.shows("Learning languages"));
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("1 waiting to be transcribed").unwrap();
    let saved = std::fs::read_to_string(it.root.join("library_catalog.json")).unwrap();
    assert!(saved.contains("shadowing"));
}

#[test]
fn two_sentences_are_merged_from_the_editor() {
    let mut it = open_sample("merge");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the show.").unwrap();
    it.app.press("role:button[Merge with next]").unwrap();
    it.app.wait_for("Welcome to the show. Today we are talking about how people learn languages.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("\"segment-2\""), "the second sentence is gone from the manifest");
}

#[test]
fn a_paired_devices_sync_needs_no_answer_and_its_recording_arrives() {
    let mut it = start("sync", paired_on_port(47941), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();
    assert!(it.app.shows("Studio Mac"), "the paired device is listed");

    let root = it.root.clone();
    let other = std::thread::spawn(move || -> Result<serde_json::Value, String> {
        let base = "https://127.0.0.1:47941/listenook";
        let hello = json!({
            "device": other_device(47941),
            "shelves": {
                "positions": {"sample": {"position_ms": 9000, "at": "2026-11-15T10:00:00.000Z"}},
                "marks": {"recent:sample": {"hidden": true, "at": "2026-11-15T10:00:00.000Z"}},
            },
            "catalog": {"version": 1, "groups": [], "tags": [{"id": "t9", "name": "shared"}]},
            "podcasts": {
                "followed": [{"feed_url": "https://example.com/studio.xml", "title": "Studio Show", "followed_at": "2026-11-12T08:00:00.000Z"}],
                "listened": [{"episode_id": "studio-1", "position_ms": 42000, "duration_ms": 600000, "updated_at": "2026-11-12T08:30:00.000Z"}],
                "played": [{"feed_url": "https://example.com/other.xml", "title": "Other Show", "episodes": [
                    {"id": "studio-1", "feed_url": "https://example.com/other.xml", "title": "Left halfway", "enclosure_url": "https://example.com/a.mp3", "media_extension": "mp3"},
                ]}],
            },
        });
        let welcome = hello_to(&root, base, hello)?;
        let token = welcome["token"].as_str().ok_or("no token")?.to_owned();
        let job = json!({
            "manifest_version": 15, "id": "from-other", "source_path": "/elsewhere/talk.m4a",
            "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
            "status": "completed", "display_title": "Sent from the studio", "tag_ids": ["t9"],
            "document": {"segments": [{"id": "segment-1", "start_ms": 0, "end_ms": 900, "text": "Hello."}]},
        });
        other(&root)
            .put(&format!("{base}/manifest/from-other"))
            .set("X-Listenook-Token", &token)
            .send_string(&job.to_string())
            .map_err(|error| error.to_string())?;
        other(&root)
            .post(&format!("{base}/done"))
            .set("X-Listenook-Token", &token)
            .send_string(r#"{"complete":true}"#)
            .map_err(|error| error.to_string())?;
        Ok(welcome)
    });

    let welcome = other.join().unwrap().unwrap();
    assert_eq!(welcome["index"]["entries"][0]["id"], "sample", "the other device is told what is here");
    assert!(!it.app.shows("Pair a device"), "a paired device is not asked about");

    it.app.wait_for("Sent from the studio").unwrap();
    let arrived = std::fs::read_to_string(manifest(&it.root, "from-other")).unwrap();
    assert!(arrived.contains("2026-11-12T09:00:00.000Z"), "its time of change stays the other device's");
    let catalog = std::fs::read_to_string(it.root.join("library_catalog.json")).unwrap();
    assert!(catalog.contains("shared"), "its tag came with it");
    let played = std::fs::read_to_string(it.root.join("podcast_playback.json")).unwrap();
    assert!(played.contains("studio-1"), "where it left an episode came with it");
    let settings: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(it.root.join("settings.json")).unwrap()).unwrap();
    assert_eq!(settings["playback_positions_ms"]["sample"], 9000, "where it left a recording came with it");
    assert_eq!(settings["recent_hidden"], json!(["sample"]), "what it took off Recently added comes off here");
    it.app.wait_for("Synced with Studio Mac: 1 received, 0 sent").unwrap();
    it.app.press("Close").unwrap();
    it.app.press("role:button[Podcasts]").unwrap();
    it.app.wait_for("Studio Show").unwrap();
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Left halfway").unwrap();
    let shows = std::fs::read_to_string(it.root.join("podcast_catalog.json")).unwrap();
    assert!(shows.contains("Left halfway"), "the episode it left is saved with its details");
}

#[test]
fn a_device_pairs_with_the_code_shown_here_and_a_wrong_code_does_not() {
    let mut it = start("sync-pair", on_port(47944), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("Nearby devices").unwrap();
    assert!(!it.app.shows("My devices"), "nothing is paired yet");

    let base = "https://127.0.0.1:47944/listenook";
    let library = other_library(&it.root);
    let seen = Arc::new(Mutex::new(String::new()));
    let asking = client(&library, None, Some(seen.clone()));
    let asked = json!({"device": other_device(47944)});
    let answer: serde_json::Value = (0..50)
        .find_map(|_| match asking.post(&format!("{base}/pair")).send_string(&asked.to_string()) {
            Ok(response) => Some(response.into_string().unwrap()),
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100));
                None
            }
        })
        .expect("the device answers")
        .parse()
        .unwrap();
    let here = answer["device"]["id"].as_str().unwrap().to_owned();
    let here_key = seen.lock().unwrap().clone();
    assert_eq!(here_key, device_key(&it.root), "the device shows its own certificate");

    it.app.wait_for("Pair a device").unwrap();
    it.app.wait_for("“Studio Mac”").ok();
    let shown = it
        .app
        .screen()
        .texts()
        .into_iter()
        .find(|text| text.len() == 7 && text.chars().filter(char::is_ascii_digit).count() == 6)
        .map(|text| text.replace(' ', ""))
        .expect("a six-digit code is shown");
    let try_code = |code: &str| -> Result<serde_json::Value, u16> {
        let agent = client(&library, Some(&here_key), None);
        let (pake, message) = Pake::start(code, ("other", &device_key(&library)), (&here, &here_key), true);
        let sent = json!({"id": "other", "message": message});
        let theirs: serde_json::Value = agent
            .post(&format!("{base}/pair/confirm"))
            .send_string(&sent.to_string())
            .unwrap()
            .into_string()
            .unwrap()
            .parse()
            .unwrap();
        let key = pake.finish(theirs["message"].as_str().unwrap()).unwrap();
        let finish = json!({"id": "other", "proof": pake_proof(&key, "asker")});
        match agent.post(&format!("{base}/pair/finish")).send_string(&finish.to_string()) {
            Ok(response) => {
                let done: serde_json::Value = response.into_string().unwrap().parse().unwrap();
                assert_eq!(done["proof"], pake_proof(&key, "answerer"), "the device proves it knew the code");
                Ok(done)
            }
            Err(ureq::Error::Status(status, _)) => Err(status),
            Err(error) => panic!("{error}"),
        }
    };
    let wrong = if shown == "000000" { "111111" } else { "000000" };
    assert_eq!(try_code(wrong).err(), Some(403), "a wrong code is refused");
    assert!(it.app.shows("Pair a device"), "the code stays up after one wrong try");

    let done = try_code(&shown).unwrap();
    assert_eq!(done["circle"]["members"]["other"]["key"], device_key(&library));
    it.app.wait_for_gone("Pair a device", GONE).unwrap();
    it.app.wait_for("My devices").unwrap();
    it.app.wait_for("Studio Mac").unwrap();
    let saved = std::fs::read_to_string(it.root.join("sync.json")).unwrap();
    assert!(saved.contains(&device_key(&library)) && saved.contains("Studio Mac"), "the pairing is remembered");

    let welcome = hello_to(&it.root, base, json!({"device": other_device(47944), "auto": true})).unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();
    other(&it.root)
        .post(&format!("{base}/done"))
        .set("X-Listenook-Token", &token)
        .send_string(r#"{"complete":true}"#)
        .unwrap();
    std::thread::sleep(Duration::from_millis(500));
    assert!(!it.app.shows("Synced with Studio Mac"), "a sync on its own says nothing");
    let stranger = PathBuf::from(format!("{}-stranger", it.root.display()));
    let refused = client(&stranger, Some(&here_key), None)
        .post(&format!("{base}/sync"))
        .send_string(&json!({"device": other_device(47944)}).to_string());
    assert!(matches!(refused, Err(ureq::Error::Status(403, _))), "another device's key is refused");
}

#[test]
fn home_continues_an_episode_of_a_show_not_followed() {
    let mut it = start(
        "home-episode",
        |root| {
            let catalog = json!({"version": 1, "feeds": [{"feed_url": "https://example.com/other.xml", "title": "Other Show", "episodes": [
                {"id": "left-1", "feed_url": "https://example.com/other.xml", "title": "Left halfway", "enclosure_url": "https://example.com/a.mp3", "media_extension": "mp3"},
            ]}]});
            std::fs::write(root.join("podcast_catalog.json"), catalog.to_string()).unwrap();
            let playback = json!({"version": 1, "entries": [
                {"episode_id": "left-1", "position_ms": 42000, "duration_ms": 600000, "updated_at": "2026-11-12T08:30:00.000Z"},
            ]});
            std::fs::write(root.join("podcast_playback.json"), playback.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Continue").unwrap();
    assert!(it.app.shows("Left halfway"));
    assert!(!it.app.shows("Start your library"));
}

#[test]
fn this_device_pairs_by_entering_the_code_shown_on_the_other_one() {
    let mut it = start("sync-asker", on_port(47945), Vec::new());
    it.app.wait_for("Learning languages").unwrap();

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let library = other_library(&it.root);
    let theirs_key = device_key(&library);
    let there = library.clone();
    let other = std::thread::spawn(move || {
        let device = other_device(port);
        let mine = device_key(&there);
        let (mut asker, mut asker_key, mut key) = (String::new(), String::new(), Vec::new());
        let mut asked_paths = Vec::new();
        for stream in listener.incoming() {
            let Ok(connected) = answer(&there, stream.unwrap()) else {
                continue;
            };
            let call = asked(connected);
            let (path, body, peer) = (call.path.clone(), call.json(), call.peer.clone());
            match path.as_str() {
                "/listenook/info" => call.answer(200, device.clone()),
                "/listenook/pair" => {
                    asker = body["device"]["id"].as_str().unwrap().to_owned();
                    asker_key = peer;
                    call.answer(200, json!({"device": device}))
                }
                "/listenook/pair/confirm" => {
                    let (pake, message) = Pake::start("246810", (&asker, &asker_key), ("other", &mine), false);
                    key = pake.finish(body["message"].as_str().unwrap()).unwrap();
                    call.answer(200, json!({"id": "other", "message": message}))
                }
                "/listenook/pair/finish" if body["proof"] != pake_proof(&key, "asker") => {
                    call.answer(403, json!({"reason": "wrong"}))
                }
                "/listenook/pair/finish" => call.answer(
                    200,
                    json!({
                        "proof": pake_proof(&key, "answerer"),
                        "circle": {"id": "theirs", "members": {
                            "other": {"name": "Studio Mac", "platform": "macos", "joined_at": "2026-11-01T00:00:00.000Z", "key": mine},
                        }},
                    }),
                ),
                "/listenook/sync" if peer == asker_key => call.answer(
                    200,
                    json!({
                        "token": "token", "device": device,
                        "index": {"entries": [], "catalog": {"version": 1, "groups": [], "tags": []}},
                    }),
                ),
                "/listenook/sync" => call.answer(403, json!({"reason": "unpaired"})),
                _ => call.answer(200, json!({})),
            }
            asked_paths.push(path.clone());
            if path == "/listenook/done" {
                break;
            }
        }
        asked_paths
    });

    it.app.press("Sync").unwrap();
    it.app.wait_for("Nearby devices").unwrap();
    it.app.type_text("text:IP address, such as 192.168.1.20", &format!("127.0.0.1:{port}")).unwrap();
    it.app.press("role:button[Connect]").unwrap();
    it.app.wait_for("Enter the code shown on “Studio Mac”.").unwrap();
    it.app.type_text("text:6-digit code", "111111").unwrap();
    it.app.press("role:button[Pair]").unwrap();
    it.app.wait_for("That code is not right. Check it on the other device and try again.").unwrap();
    it.app.type_text("text:6-digit code", "246 810\n").unwrap();
    it.app.wait_for_within("Synced with Studio Mac", Duration::from_secs(10)).unwrap();
    let asked = other.join().unwrap();
    assert_eq!(asked.iter().filter(|path| *path == "/listenook/pair/finish").count(), 2);
    assert!(asked.contains(&"/listenook/sync".to_owned()), "the first sync follows the pairing");
    let saved = std::fs::read_to_string(it.root.join("sync.json")).unwrap();
    assert!(saved.contains("\"theirs\"") && saved.contains(&theirs_key), "this device joined the other one's circle");
    it.app.press("role:button[Done]").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();
    assert!(it.app.shows("Studio Mac"));
}

#[test]
fn a_recording_removed_on_the_other_device_is_removed_here() {
    let mut it = start("sync-removed", paired_on_port(47943), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();
    let old = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();

    let root = it.root.clone();
    let other = std::thread::spawn(move || -> Result<(), String> {
        let base = "https://127.0.0.1:47943/listenook";
        let hello = json!({"device": other_device(47943), "removed": {"sample": "2099-01-01T00:00:00.000Z"}});
        let welcome = hello_to(&root, base, hello)?;
        let token = welcome["token"].as_str().ok_or("no token")?.to_owned();
        other(&root)
            .put(&format!("{base}/manifest/sample"))
            .set("X-Listenook-Token", &token)
            .send_string(&old)
            .map_err(|error| error.to_string())?;
        other(&root)
            .post(&format!("{base}/done"))
            .set("X-Listenook-Token", &token)
            .send_string(r#"{"complete":true}"#)
            .map_err(|error| error.to_string())?;
        Ok(())
    });

    other.join().unwrap().unwrap();
    it.app.wait_for_gone("Learning languages", GONE).unwrap();
    assert!(!manifest(&it.root, "sample").exists());
    let removed = std::fs::read_to_string(it.root.join("removed.json")).unwrap();
    assert!(removed.contains("sample"), "the removal is remembered for the next device");
}

#[test]
fn a_sync_being_answered_shows_and_ends_when_the_other_device_is_lost() {
    let mut it = start("sync-served", paired_on_port(47942), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();

    let base = "https://127.0.0.1:47942/listenook";
    let hello = json!({"device": other_device(47942), "catalog": {"version": 1, "groups": [], "tags": []}});
    let welcome = hello_to(&it.root, base, hello).unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();

    it.app.wait_for("Syncing with Studio Mac…").unwrap();
    assert!(!it.app.shows("My devices"), "no device is chosen while one syncs");
    let job = json!({
        "manifest_version": 15, "id": "from-other", "source_path": "/elsewhere/talk.m4a",
        "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
        "status": "completed", "display_title": "Sent from the studio",
    });
    other(&it.root)
        .put(&format!("{base}/manifest/from-other"))
        .set("X-Listenook-Token", &token)
        .set("X-Listenook-Progress", "1 3 0")
        .send_string(&job.to_string())
        .unwrap();
    it.app.wait_for("1 / 3 recordings").unwrap();
    let stranger = PathBuf::from(format!("{}-stranger", it.root.display()));
    let taken = client(&stranger, Some(&device_key(&it.root)), None)
        .get(&format!("{base}/manifest/sample"))
        .set("X-Listenook-Token", &token)
        .call();
    assert!(matches!(taken, Err(ureq::Error::Status(410, _))), "a token is no good on another device's connection");

    it.app.press("role:button[Close]").unwrap();
    it.app.wait_for_gone("Syncing with Studio Mac…", GONE).unwrap();
    it.app.wait_for("Sent from the studio").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("Syncing with Studio Mac…").unwrap();

    let broken = other(&it.root)
        .put(&format!("{base}/media/from-other/m4a"))
        .set("X-Listenook-Token", &token)
        .set("Content-Length", "1000")
        .send(Breaks::after(b"half", Duration::from_millis(500)));
    assert!(broken.is_err());
    it.app.wait_for_within("The sync did not finish", Duration::from_secs(20)).unwrap();
    assert!(it.app.shows("The connection was lost. What was copied is kept; sync again to finish."));
    let late = other(&it.root).get(&format!("{base}/manifest/sample")).set("X-Listenook-Token", &token).call();
    assert!(matches!(late, Err(ureq::Error::Status(410, _))), "the sync is over for the other device too");

    let hello =
        json!({"device": other_device(47942), "catalog": {"version": 1, "groups": [], "tags": []}, "resume": true});
    let welcome = hello_to(&it.root, base, hello).unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();
    it.app.wait_for("Syncing with Studio Mac…").unwrap();
    let part: serde_json::Value = other(&it.root)
        .get(&format!("{base}/part/from-other/m4a"))
        .set("X-Listenook-Token", &token)
        .call()
        .unwrap()
        .into_string()
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(part["size"], 4, "what arrived before the loss was kept");
    other(&it.root)
        .put(&format!("{base}/media/from-other/m4a"))
        .set("X-Listenook-Token", &token)
        .set("X-Listenook-Offset", "4")
        .send_string(&"z".repeat(996))
        .unwrap();
    let media = std::fs::read_to_string(it.root.join("media/sync-from-other.m4a")).unwrap();
    assert_eq!(media, format!("half{}", "z".repeat(996)));
    other(&it.root)
        .post(&format!("{base}/done"))
        .set("X-Listenook-Token", &token)
        .send_string(r#"{"complete":true}"#)
        .unwrap();
    it.app.wait_for("Synced with Studio Mac").unwrap();
    it.app.press("role:button[Done]").unwrap();
    it.app.wait_for_gone("Synced with Studio Mac", GONE).unwrap();
}

#[test]
fn a_sync_ends_when_a_call_is_lost_before_it_is_read() {
    let mut it = start("sync-lost-early", paired_on_port(47949), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();

    let base = "https://127.0.0.1:47949/listenook";
    let hello = json!({"device": other_device(47949), "catalog": {"version": 1, "groups": [], "tags": []}});
    let welcome = hello_to(&it.root, base, hello).unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();
    it.app.wait_for("Syncing with Studio Mac…").unwrap();

    // Given up on at once: on Windows the reset can take the request with it, unread.
    let broken = other(&it.root)
        .put(&format!("{base}/media/sample/m4a"))
        .set("X-Listenook-Token", &token)
        .set("Content-Length", "1000")
        .send(Breaks::after(b"", Duration::ZERO));
    assert!(broken.is_err());
    it.app.wait_for_within("The sync did not finish", Duration::from_secs(20)).unwrap();
}

#[test]
fn a_path_sent_by_the_other_device_never_names_a_file_here() {
    let mut it = start("sync-path", paired_on_port(47948), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    let private = std::env::temp_dir().join(format!("listenook-flow-private-{}.m4a", std::process::id()));
    std::fs::write(&private, "not for the other device").unwrap();
    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();

    let base = "https://127.0.0.1:47948/listenook";
    let hello = json!({"device": other_device(47948), "catalog": {"version": 1, "groups": [], "tags": []}});
    let welcome = hello_to(&it.root, base, hello).unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();
    it.app.wait_for("Syncing with Studio Mac…").unwrap();
    let job = json!({
        "manifest_version": 15, "id": "probe", "source_path": private.to_str().unwrap(),
        "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
        "status": "completed", "display_title": "Probe from the studio",
    });
    other(&it.root)
        .put(&format!("{base}/manifest/probe"))
        .set("X-Listenook-Token", &token)
        .send_string(&job.to_string())
        .unwrap();
    it.app.press("role:button[Close]").unwrap();
    it.app.wait_for("Probe from the studio").unwrap();

    let saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(manifest(&it.root, "probe")).unwrap()).unwrap();
    let kept = it.root.join("media").join("sync-probe.m4a");
    assert_eq!(saved["source_path"].as_str(), kept.to_str(), "the recording waits for its media in the app's folder");
    let served = other(&it.root).get(&format!("{base}/media/probe")).set("X-Listenook-Token", &token).call();
    assert!(matches!(served, Err(ureq::Error::Status(404, _))), "the file the path named is not sent");
    let _ = std::fs::remove_file(private);

    let put = |id: &str, updated_at: &str, title: &str| {
        let job = json!({
            "manifest_version": 15, "id": id, "source_path": "/elsewhere/talk.m4a",
            "created_at": "2026-11-12T08:00:00.000Z", "updated_at": updated_at,
            "status": "completed", "display_title": title,
        });
        other(&it.root)
            .put(&format!("{base}/manifest/{id}"))
            .set("X-Listenook-Token", &token)
            .send_string(&job.to_string())
            .unwrap();
    };
    put("probe", "2026-11-12T08:30:00.000Z", "An older probe");
    put("after", "2026-11-12T09:00:00.000Z", "Sent after the older probe");
    it.app.wait_for("Sent after the older probe").unwrap();
    assert!(it.app.shows("Probe from the studio") && !it.app.shows("An older probe"), "the newer recording here stays");
    let saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(manifest(&it.root, "probe")).unwrap()).unwrap();
    assert_eq!(saved["display_title"], "Probe from the studio");
}

#[test]
fn a_lost_connection_is_taken_up_again_where_it_broke_off() {
    let mut it = start("sync-lost", paired_on_port(47943), Vec::new());
    it.app.wait_for("Learning languages").unwrap();

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let there = other_library(&it.root);
    let here_key = device_key(&it.root);
    let other = std::thread::spawn(move || {
        let device = other_device(port);
        let mut asked_for: Vec<(String, Option<String>, String)> = Vec::new();
        for stream in listener.incoming() {
            let Ok(connected) = answer(&there, stream.unwrap()) else {
                continue;
            };
            let call = asked(connected);
            assert_eq!(call.peer, here_key, "only this device asks");
            let (path, offset) = (call.path.clone(), call.header("x-listenook-offset"));
            let body = String::from_utf8_lossy(&call.body).into_owned();
            match (path.as_str(), offset.as_deref()) {
                ("/listenook/info", _) => call.answer(200, device.clone()),
                ("/listenook/sync", _) => call.answer(
                    200,
                    json!({
                        "token": "token", "device": device,
                        "index": {
                            "entries": [{"id": "lost", "updated_at": "2026-11-12T09:00:00.000Z", "media_name": "talk.m4a", "media_size": 1000}],
                            "catalog": {"version": 1, "groups": [], "tags": []},
                        },
                    }),
                ),
                ("/listenook/media/lost", None) => {
                    call.reply(&format!("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n{}", "x".repeat(100)))
                }
                ("/listenook/media/lost", Some("100")) => call.reply(&format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: 900\r\nX-Listenook-Offset: 100\r\nConnection: close\r\n\r\n{}",
                    "y".repeat(900)
                )),
                ("/listenook/manifest/lost", _) => call.answer(
                    200,
                    json!({
                        "manifest_version": 15, "id": "lost", "source_path": "/elsewhere/talk.m4a",
                        "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
                        "status": "completed", "display_title": "Came through",
                    }),
                ),
                _ => call.answer(200, json!({})),
            }
            asked_for.push((path.clone(), offset, body));
            if path == "/listenook/done" {
                break;
            }
        }
        asked_for
    });

    it.app.press("Sync").unwrap();
    it.app.wait_for("My devices").unwrap();
    it.app.type_text("text:IP address, such as 192.168.1.20", &format!("127.0.0.1:{port}")).unwrap();
    it.app.press("role:button[Connect]").unwrap();
    it.app.wait_for_within("Connection lost. Reconnecting…", Duration::from_secs(10)).unwrap();
    it.app.wait_for_within("Synced with Studio Mac", Duration::from_secs(20)).unwrap();
    let asked = other.join().unwrap();
    let syncs: Vec<&String> =
        asked.iter().filter(|(path, ..)| path == "/listenook/sync").map(|(.., body)| body).collect();
    assert_eq!(syncs.len(), 2, "asked again after the loss");
    assert!(!syncs[0].contains(r#""resume":true"#) && syncs[1].contains(r#""resume":true"#));
    let media: Vec<Option<&str>> = asked
        .iter()
        .filter(|(path, ..)| path == "/listenook/media/lost")
        .map(|(_, offset, _)| offset.as_deref())
        .collect();
    assert_eq!(media, [None, Some("100")], "the file is asked for from where it broke off");
    assert_eq!(
        asked.last().map(|(path, _, body)| (path.as_str(), body.as_str())),
        Some(("/listenook/done", r#"{"complete":true}"#))
    );
    let file = std::fs::read_to_string(it.root.join("media/sync-lost.m4a")).unwrap();
    assert_eq!(file, format!("{}{}", "x".repeat(100), "y".repeat(900)), "the two parts make the file");
    it.app.press("role:button[Done]").unwrap();
    it.app.wait_for("Came through").unwrap();
}

#[test]
fn settings_list_the_paired_devices_and_unpair_this_one() {
    let mut it = start("sync-unpair", paired_on_port(47946), Vec::new());
    it.app.press("Settings").unwrap();
    it.app.wait_for("Paired devices").unwrap();
    assert!(it.app.shows("Studio Mac"));
    it.app.on_dialog(|_| DialogAnswer::Press("Unpair".to_owned()));
    it.app.press("role:button[Unpair this device]").unwrap();
    it.app.wait_for("This device is not paired with any other. Open Sync to pair one with a code.").unwrap();
    assert!(!it.app.shows("Studio Mac"));
    let saved = std::fs::read_to_string(it.root.join("sync.json")).unwrap();
    assert!(!saved.contains(&device_key(&other_library(&it.root))), "the other device is forgotten here");
}

#[test]
fn a_change_here_reaches_a_paired_device_within_seconds() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut it = start(
        "sync-change",
        move |root: &Path| {
            paired_on_port(47947)(root);
            std::fs::write(
                root.join("settings.json"),
                json!({"sync_device_id": "this-device", "sync_visible": true}).to_string(),
            )
            .unwrap();
            let mut ledger: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(root.join("sync.json")).unwrap()).unwrap();
            ledger["seen"] = json!({"other": {"address": format!("127.0.0.1:{port}")}});
            std::fs::write(root.join("sync.json"), ledger.to_string()).unwrap();
        },
        Vec::new(),
    );
    let (tell, heard) = std::sync::mpsc::channel::<String>();
    let there = other_library(&it.root);
    std::thread::spawn(move || {
        let device = json!({"app": "listenook", "protocol": PROTOCOL, "id": "other", "name": "Studio Mac", "platform": "macos", "port": port, "revision": "theirs"});
        for stream in listener.incoming() {
            let Ok(stream) = stream else { break };
            let Ok(connected) = answer(&there, stream) else {
                continue;
            };
            let call = asked(connected);
            let (path, body) = (call.path.clone(), String::from_utf8_lossy(&call.body).into_owned());
            let reply = match path.as_str() {
                "/listenook/info" => device.clone(),
                "/listenook/sync" => json!({
                    "token": "token", "device": device, "revision": "theirs",
                    "index": {"entries": [], "catalog": {"version": 1, "groups": [], "tags": []}},
                }),
                _ => json!({}),
            };
            call.answer(200, reply);
            if path == "/listenook/sync" && tell.send(body).is_err() {
                break;
            }
        }
    });

    let first = heard.recv_timeout(Duration::from_secs(20)).expect("a sync when the app starts");
    assert!(!first.contains("\"removed\""), "nothing is removed yet");
    assert!(heard.recv_timeout(Duration::from_secs(3)).is_err(), "nothing more while nothing changes");

    it.app.wait_for("Learning languages").unwrap();
    it.app.on_dialog(|_| DialogAnswer::Press("Remove".to_owned()));
    it.app.press("label:More actions").unwrap();
    it.app.press("Remove…").unwrap();
    it.app.wait_for("Drop audio or video here").unwrap();
    let changed = Instant::now();
    let second = heard.recv_timeout(Duration::from_secs(40)).expect("a sync soon after the change");
    assert!(changed.elapsed() < Duration::from_secs(30), "synced after {:?}", changed.elapsed());
    assert!(second.contains("\"removed\"") && second.contains("\"sample\""), "the removal goes with it");
}

#[test]
fn a_downloaded_episode_keeps_its_show_on_home() {
    let mut it = start(
        "home-downloaded",
        |root| {
            seed_transcript(root);
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            job["source_origin"] = json!("podcast");
            job["podcast_provenance"] = json!({
                "feed_url": "https://example.com/aee.xml", "episode_id": "aee-2722",
                "enclosure_url": "https://example.com/aee-2722.mp3", "show_title": "All Ears English Podcast",
                "episode_title": "We Wager You'll Love This Episode",
            });
            std::fs::write(&path, job.to_string()).unwrap();
            let settings = json!({
                "playback_positions_ms": {"sample": 6000},
                "playback_played_at": {"sample": "2026-11-15T10:00:00.000Z"},
            });
            std::fs::write(root.join("settings.json"), settings.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Continue").unwrap();
    assert!(it.app.shows("00:06 · All Ears English Podcast"));
    assert!(it.app.shows("2026-11-10 · All Ears English Podcast"));
}

#[test]
fn the_editor_actions_sit_on_one_row_with_the_rest_in_a_menu() {
    let mut it = start(
        "editor-actions",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    let screen = it.app.screen();
    let nodes = screen.layout_nodes();
    let bounds = |selector: &str| {
        let id = screen.press_target(selector).unwrap().unwrap();
        nodes.iter().find(|node| node.id == id).unwrap().bounds
    };
    let split = bounds("role:button[Split at cursor]");
    let more = bounds("label:More sentence actions");
    let save = bounds("role:button[Save]");
    let middle = |b: &nsh_core::Bounds<nsh_core::Points>| b.origin.y + b.size.height * 0.5;
    assert_eq!(middle(&split), middle(&save), "Split {split:?} and Save {save:?} share a row");
    assert!(split.origin.x < more.origin.x && more.origin.x < save.origin.x, "Split, More, then Save");
    let again = bounds("label:Translate again");
    let box_ = nodes.iter().find(|node| node.id == screen.id("id:translation-editor").unwrap()).unwrap().bounds;
    assert!(
        again.origin.x > box_.origin.x + box_.size.width * 0.5 && again.origin.y < box_.origin.y + box_.size.height,
        "Translate again {again:?} sits in the translation box {box_:?}"
    );
    it.app.press("label:More sentence actions").unwrap();
    it.app.wait_for("Skip from here…").unwrap();
    assert!(it.app.shows("Delete sentence"));
}

fn translation_box(it: &mut App, wanted: &str) {
    let wanted = wanted.to_owned();
    it.app
        .wait_until("the translation box to fill", Duration::from_secs(5), move |screen| {
            screen.input_text("id:translation-editor").ok().flatten() == Some(wanted.as_str())
        })
        .unwrap();
}

#[test]
fn translate_again_fills_the_box_from_the_edited_sentence_and_waits_for_save() {
    let routes = llm_routes("1. 欢迎收听节目。");
    let mut it = start(
        "translate-draft",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("label:Translate again").unwrap();
    translation_box(&mut it, "欢迎收听节目。");
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("欢迎收听节目。"), "nothing is saved before Save");
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("欢迎收听节目。").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("Welcome to the programme.") && saved.contains("欢迎收听节目。"));
}

#[test]
fn a_sentence_waits_in_place_for_its_translation_and_an_undo_drops_a_late_one() {
    let mut routes = llm_routes("1. 欢迎收听节目。");
    routes[0].1.delay = Duration::from_millis(1000);
    let mut it = start(
        "translate-late",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("欢迎回到节目。").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("label:Translating").unwrap();
    assert!(it.app.shows("欢迎回到节目。"), "the old translation stays while it waits");
    it.app.press("role:button[Undo]").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.wait_for_gone("label:Translating", GONE).unwrap();
    it.app.wait(Duration::from_millis(300)).unwrap();
    assert!(!it.app.shows("欢迎收听节目。"), "the reply was for the undone text");
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    assert_eq!(saved["document"]["segments"][0]["translated_text"], "欢迎回到节目。");
}

#[test]
fn a_corrected_sentence_with_its_translation_untouched_is_translated_again_on_save() {
    let routes = llm_routes("1. 欢迎收听节目。");
    let mut it = start(
        "translate-on-save",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("欢迎回到节目。").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("欢迎收听节目。").unwrap();
    assert!(!it.app.shows("欢迎回到节目。"), "the old translation is replaced");
    assert!(!it.app.shows("label:Translating"), "the sentence is done waiting");
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    assert_eq!(saved["document"]["segments"][0]["text"], "Welcome to the programme.");
    assert_eq!(saved["document"]["segments"][0]["translated_text"], "欢迎收听节目。");
    assert_ne!(
        saved["translation_state"]["status"], "translating",
        "one sentence leaves the recording's translation alone"
    );
    assert_ne!(saved["translation_state"]["total_segments"], 1);
}
