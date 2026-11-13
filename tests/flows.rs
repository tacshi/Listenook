//! The app's flows, with the steps a user takes, on the real engine without
//! a window. Each test has its own data folder; the network is a stub.

use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use listenook_core::podcast;
use nsh_engine::{EngineConfig, Points, Root, Size};
use nsh_testing::{DialogAnswer, Headless, StubNetwork, StubResponse};
use serde_json::json;

/// The data folder comes from the environment, which tests share: one at a time.
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
    // SAFETY: tests that read these run one at a time, under `turn`.
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
    App { app, root, _turn: turn }
}

/// Seeds the transcript and names the port this device answers other
/// devices on (read when it becomes visible). Set here, once the test has
/// its turn: tests that start an app run one at a time.
fn on_port(port: u16) -> impl FnOnce(&Path) {
    move |root| {
        // SAFETY: under the turn `start` holds.
        unsafe { std::env::set_var("LISTENOOK_SYNC_PORT", port.to_string()) };
        seed_transcript(root);
    }
}

fn manifest(root: &Path, id: &str) -> PathBuf {
    root.join("jobs").join(id).join("manifest.json")
}

/// A finished job with a five-sentence bilingual transcript.
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
    assert!(it.app.shows("So, what should a beginner do first?"));
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
fn dictation_checks_the_answer_without_showing_the_sentence() {
    let mut it = open_sample("dictation");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:Type what you hear").unwrap();
    // Typing from hearing is blind listening: the transcript is out of sight.
    it.app.wait_for("label:Hidden sentence").unwrap();
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Listen again and retry.").unwrap();
    it.app.clear("text:welcome to the show").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Matches transcript").unwrap();
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
            // SAFETY: under the turn `start` holds.
            unsafe { std::env::set_var("LISTENOOK_TABLET_MENUS", "1") };
            seed_transcript(root);
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    // The first menus go with the page they were made in.
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

/// A local AI endpoint (no key needed) answering every chat completion with `content`.
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
    // An evidence chip takes the user back to the transcript at that moment.
    it.app.press("label:Play from 00:03").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
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
    it.app.press("role:button[In progress 1]").unwrap();
    it.app.wait_for("Budget review").unwrap();
    let saved = std::fs::read_to_string(it.root.join("library_catalog.json")).unwrap();
    assert!(saved.contains("shadowing"));
}

#[test]
fn two_sentences_are_merged_from_the_editor() {
    let mut it = open_sample("merge");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.press("role:button[Merge with next]").unwrap();
    it.app.wait_for("Welcome back to the show. Today we are talking about how people learn languages.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("\"segment-2\""), "the second sentence is gone from the manifest");
}

#[test]
fn another_devices_sync_is_accepted_and_its_recording_arrives() {
    let mut it = start("sync", on_port(47941), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    // Opening Sync makes the device visible and looks for others.
    it.app.press("label:Sync with another device…").unwrap();
    it.app.wait_for("Nearby devices").unwrap();

    // The other device: it asks, and once accepted sends a recording.
    let other = std::thread::spawn(|| -> Result<serde_json::Value, String> {
        let base = "http://127.0.0.1:47941/listenook";
        let hello = json!({
            "device": {"app": "listenook", "protocol": 1, "id": "other", "name": "Studio Mac", "platform": "macos", "port": 47941},
            "catalog": {"version": 1, "groups": [], "tags": [{"id": "t9", "name": "shared"}]},
        });
        let mut welcome = None;
        for _ in 0..50 {
            match ureq::post(&format!("{base}/sync")).timeout(Duration::from_secs(30)).send_string(&hello.to_string()) {
                Ok(response) => {
                    welcome = Some(response.into_string().map_err(|error| error.to_string())?);
                    break;
                }
                Err(ureq::Error::Transport(_)) => std::thread::sleep(Duration::from_millis(100)),
                Err(error) => return Err(error.to_string()),
            }
        }
        let welcome: serde_json::Value =
            serde_json::from_str(&welcome.ok_or("the device never answered")?).map_err(|error| error.to_string())?;
        let token = welcome["token"].as_str().ok_or("no token")?.to_owned();
        let job = json!({
            "manifest_version": 15, "id": "from-other", "source_path": "/elsewhere/talk.m4a",
            "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
            "status": "completed", "display_title": "Sent from the studio", "tag_ids": ["t9"],
            "document": {"segments": [{"id": "segment-1", "start_ms": 0, "end_ms": 900, "text": "Hello."}]},
        });
        ureq::put(&format!("{base}/manifest/from-other"))
            .set("X-Listenook-Token", &token)
            .send_string(&job.to_string())
            .map_err(|error| error.to_string())?;
        ureq::post(&format!("{base}/done"))
            .set("X-Listenook-Token", &token)
            .send_string(r#"{"complete":true}"#)
            .map_err(|error| error.to_string())?;
        Ok(welcome)
    });

    it.app.wait_for("Sync request").unwrap();
    it.app.wait_for("“Studio Mac” wants to sync its Library with this one.").unwrap();
    it.app.press("role:button[Accept]").unwrap();
    let welcome = other.join().unwrap().unwrap();
    assert_eq!(welcome["index"]["entries"][0]["id"], "sample", "the other device is told what is here");

    it.app.wait_for("Sent from the studio").unwrap();
    let arrived = std::fs::read_to_string(manifest(&it.root, "from-other")).unwrap();
    assert!(arrived.contains("2026-11-12T09:00:00.000Z"), "its time of change stays the other device's");
    let catalog = std::fs::read_to_string(it.root.join("library_catalog.json")).unwrap();
    assert!(catalog.contains("shared"), "its tag came with it");
}

/// What the other device removed goes here too, and stays gone when a
/// device sends it again unchanged.
#[test]
fn a_recording_removed_on_the_other_device_is_removed_here() {
    let mut it = start("sync-removed", on_port(47943), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("label:Sync with another device…").unwrap();
    it.app.wait_for("Nearby devices").unwrap();
    let old = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();

    let other = std::thread::spawn(move || -> Result<(), String> {
        let base = "http://127.0.0.1:47943/listenook";
        let hello = json!({
            "device": {"app": "listenook", "protocol": 1, "id": "other", "name": "Studio Mac", "platform": "macos", "port": 47943},
            "removed": {"sample": "2099-01-01T00:00:00.000Z"},
        });
        let mut welcome = None;
        for _ in 0..50 {
            match ureq::post(&format!("{base}/sync")).timeout(Duration::from_secs(30)).send_string(&hello.to_string()) {
                Ok(response) => {
                    welcome = Some(response.into_string().map_err(|error| error.to_string())?);
                    break;
                }
                Err(ureq::Error::Transport(_)) => std::thread::sleep(Duration::from_millis(100)),
                Err(error) => return Err(error.to_string()),
            }
        }
        let welcome: serde_json::Value =
            serde_json::from_str(&welcome.ok_or("the device never answered")?).map_err(|error| error.to_string())?;
        let token = welcome["token"].as_str().ok_or("no token")?.to_owned();
        // As a Listenook that knows nothing of removals would.
        ureq::put(&format!("{base}/manifest/sample"))
            .set("X-Listenook-Token", &token)
            .send_string(&old)
            .map_err(|error| error.to_string())?;
        ureq::post(&format!("{base}/done"))
            .set("X-Listenook-Token", &token)
            .send_string(r#"{"complete":true}"#)
            .map_err(|error| error.to_string())?;
        Ok(())
    });

    it.app.wait_for("Sync request").unwrap();
    it.app.press("role:button[Accept]").unwrap();
    other.join().unwrap().unwrap();
    it.app.wait_for_gone("Learning languages", GONE).unwrap();
    assert!(!manifest(&it.root, "sample").exists());
    let removed = std::fs::read_to_string(it.root.join("removed.json")).unwrap();
    assert!(removed.contains("sample"), "the removal is remembered for the next device");
}

/// The sync another device drives shows in the Sync dialog, which can be
/// put away meanwhile; a device that is no longer heard from ends it.
#[test]
fn a_sync_being_answered_shows_and_ends_when_the_other_device_is_lost() {
    use std::io::Write;
    let mut it = start("sync-served", on_port(47942), Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("label:Sync with another device…").unwrap();
    it.app.wait_for("Nearby devices").unwrap();

    let base = "http://127.0.0.1:47942/listenook";
    let other = std::thread::spawn(move || -> Result<String, String> {
        let hello = json!({
            "device": {"app": "listenook", "protocol": 1, "id": "other", "name": "Studio Mac", "platform": "macos", "port": 47942},
            "catalog": {"version": 1, "groups": [], "tags": []},
        });
        for _ in 0..50 {
            match ureq::post(&format!("{base}/sync")).timeout(Duration::from_secs(30)).send_string(&hello.to_string()) {
                Ok(response) => return response.into_string().map_err(|error| error.to_string()),
                Err(ureq::Error::Transport(_)) => std::thread::sleep(Duration::from_millis(100)),
                Err(error) => return Err(error.to_string()),
            }
        }
        Err("the device never answered".into())
    });
    it.app.wait_for("Sync request").unwrap();
    it.app.press("role:button[Accept]").unwrap();
    let welcome: serde_json::Value = serde_json::from_str(&other.join().unwrap().unwrap()).unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();

    // The dialog now tells whose sync runs, and how far the other device says it is.
    it.app.wait_for("Syncing with Studio Mac…").unwrap();
    assert!(!it.app.shows("Nearby devices"), "no device is chosen while one syncs");
    let job = json!({
        "manifest_version": 15, "id": "from-other", "source_path": "/elsewhere/talk.m4a",
        "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
        "status": "completed", "display_title": "Sent from the studio",
    });
    ureq::put(&format!("{base}/manifest/from-other"))
        .set("X-Listenook-Token", &token)
        .set("X-Listenook-Progress", "1 3 0")
        .send_string(&job.to_string())
        .unwrap();
    it.app.wait_for("1 / 3 recordings").unwrap();

    // Put away, the dialog goes and the sync goes on: it is there when opened again.
    it.app.press("role:button[Close]").unwrap();
    it.app.wait_for_gone("Syncing with Studio Mac…", GONE).unwrap();
    it.app.wait_for("Sent from the studio").unwrap();
    it.app.press("label:Sync with another device…").unwrap();
    it.app.wait_for("Syncing with Studio Mac…").unwrap();

    // The other device drops off in the middle of a file, and says nothing more.
    let mut broken = std::net::TcpStream::connect("127.0.0.1:47942").unwrap();
    write!(
        broken,
        "PUT /listenook/media/from-other/m4a HTTP/1.1\r\nX-Listenook-Token: {token}\r\nContent-Length: 1000\r\n\r\nhalf"
    )
    .unwrap();
    drop(broken);
    it.app.wait_for_within("The sync did not finish", Duration::from_secs(20)).unwrap();
    assert!(it.app.shows("The connection was lost. What was copied is kept; sync again to finish."));
    let late = ureq::get(&format!("{base}/manifest/sample")).set("X-Listenook-Token", &token).call();
    assert!(matches!(late, Err(ureq::Error::Status(410, _))), "the sync is over for the other device too");

    // It comes back for the rest: let in without asking again, and the
    // file goes on from what arrived of it.
    let hello = json!({
        "device": {"app": "listenook", "protocol": 1, "id": "other", "name": "Studio Mac", "platform": "macos", "port": 47942},
        "catalog": {"version": 1, "groups": [], "tags": []},
        "resume": true,
    });
    let welcome: serde_json::Value = ureq::post(&format!("{base}/sync"))
        .timeout(Duration::from_secs(5))
        .send_string(&hello.to_string())
        .unwrap()
        .into_string()
        .unwrap()
        .parse()
        .unwrap();
    let token = welcome["token"].as_str().unwrap().to_owned();
    it.app.wait_for("Syncing with Studio Mac…").unwrap();
    assert!(!it.app.shows("Sync request"), "accepted once is enough");
    let part: serde_json::Value = ureq::get(&format!("{base}/part/from-other/m4a"))
        .set("X-Listenook-Token", &token)
        .call()
        .unwrap()
        .into_string()
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(part["size"], 4, "what arrived before the loss was kept");
    ureq::put(&format!("{base}/media/from-other/m4a"))
        .set("X-Listenook-Token", &token)
        .set("X-Listenook-Offset", "4")
        .send_string(&"z".repeat(996))
        .unwrap();
    let media = std::fs::read_to_string(it.root.join("media/sync-from-other.m4a")).unwrap();
    assert_eq!(media, format!("half{}", "z".repeat(996)));
    ureq::post(&format!("{base}/done")).set("X-Listenook-Token", &token).send_string(r#"{"complete":true}"#).unwrap();
    it.app.wait_for("Synced with Studio Mac").unwrap();
    it.app.press("role:button[Done]").unwrap();
    it.app.wait_for_gone("Synced with Studio Mac", GONE).unwrap();
}

/// The device this one syncs with drops the connection in the middle of a
/// file: the sync is taken up again by itself, and the file from where it broke off.
#[test]
fn a_lost_connection_is_taken_up_again_where_it_broke_off() {
    use std::io::{BufRead, BufReader, Read, Write};
    let mut it = start("sync-lost", on_port(47943), Vec::new());
    it.app.wait_for("Learning languages").unwrap();

    // The other device: it accepts at once, goes away a tenth into the
    // file, and is back when asked again.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let other = std::thread::spawn(move || {
        let device = json!({"app": "listenook", "protocol": 1, "id": "other", "name": "Studio Mac", "platform": "macos", "port": port});
        // Each call: its path, the offset it names, its body.
        let mut asked: Vec<(String, Option<String>, String)> = Vec::new();
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let (mut first, mut length, mut offset) = (String::new(), 0_usize, None);
            reader.read_line(&mut first).unwrap();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.trim().is_empty() {
                    break;
                }
                let line = line.to_ascii_lowercase();
                if let Some(value) = line.strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                if let Some(value) = line.strip_prefix("x-listenook-offset:") {
                    offset = Some(value.trim().to_owned());
                }
            }
            let mut body = vec![0_u8; length];
            reader.read_exact(&mut body).unwrap();
            let path = first.split(' ').nth(1).unwrap_or("").to_owned();
            let json = |body: serde_json::Value| {
                let body = body.to_string();
                format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
            };
            let answer = match (path.as_str(), offset.as_deref()) {
                ("/listenook/info", _) => json(device.clone()),
                ("/listenook/sync", _) => json(json!({
                    "token": "token", "device": device,
                    "index": {
                        "entries": [{"id": "lost", "updated_at": "2026-11-12T09:00:00.000Z", "media_name": "talk.m4a", "media_size": 1000}],
                        "catalog": {"version": 1, "groups": [], "tags": []},
                    },
                })),
                // A tenth of the file, and the connection is gone.
                ("/listenook/media/lost", None) => {
                    format!("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n{}", "x".repeat(100))
                }
                ("/listenook/media/lost", Some("100")) => format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: 900\r\nX-Listenook-Offset: 100\r\nConnection: close\r\n\r\n{}",
                    "y".repeat(900)
                ),
                ("/listenook/manifest/lost", _) => json(json!({
                    "manifest_version": 15, "id": "lost", "source_path": "/elsewhere/talk.m4a",
                    "created_at": "2026-11-12T08:00:00.000Z", "updated_at": "2026-11-12T09:00:00.000Z",
                    "status": "completed", "display_title": "Came through",
                })),
                _ => json(json!({})),
            };
            stream.write_all(answer.as_bytes()).unwrap();
            asked.push((path.clone(), offset, String::from_utf8_lossy(&body).into_owned()));
            if path == "/listenook/done" {
                break;
            }
        }
        asked
    });

    it.app.press("label:Sync with another device…").unwrap();
    it.app.wait_for("Nearby devices").unwrap();
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
