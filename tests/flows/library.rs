//! The library: transcribing, retranslating, filing, removing and recording.

use super::*;

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
fn a_job_that_failed_offline_is_transcribed_once_the_network_is_back() {
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
        "back-online",
        |root| {
            let media = root.join("Standup.mp3");
            std::fs::write(&media, b"not really audio").unwrap();
            let job = json!({"id": "dropped", "source_path": media, "status": "failed",
                             "error_code": "network_error", "transcription_provider": "soniox"});
            std::fs::create_dir_all(root.join("jobs/dropped")).unwrap();
            std::fs::write(manifest(root, "dropped"), job.to_string()).unwrap();
        },
        routes,
    );
    it.app.wait_for("Standup").unwrap();
    it.app.set_environment("offline", |env| env.network.kind = NetworkKind::None).unwrap();
    it.app.press("Standup").unwrap();
    assert!(!it.app.screen().matches("Hello world.").unwrap(), "nothing is sent while offline");
    it.app.set_environment("online", |env| env.network.kind = NetworkKind::Wifi).unwrap();
    it.app.wait_for("Hello world.").unwrap();
}

#[test]
fn an_untranscribed_recording_plays_in_the_reader_until_its_transcript_takes_its_place() {
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
        "untranscribed",
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
    it.app.press("Standup").unwrap();
    it.app.wait_for("No transcript yet").unwrap();
    it.app.press("role:button[Play]").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
    it.app.wait_for("role:button[Back 15 seconds]").unwrap();
    // With no sentences, the steps jump by time, and what needs the words waits for them.
    for needs_words in ["role:button[Search transcript]", "role:button[Practice]", "role:button[AI Brief]"] {
        assert!(!it.app.screen().matches(needs_words).unwrap(), "{needs_words} waits for the transcript");
    }
    it.app.press("role:button[Transcribe]").unwrap();
    it.app.wait_for("Hello world.").unwrap();
    it.app.wait_for("role:button[Previous sentence]").unwrap();
    it.app.wait_for("role:button[Search transcript]").unwrap();
    it.app.wait_for("role:button[Practice]").unwrap();
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
    // Beside the field, at its top: on macOS the field is an AppKit view that takes the clicks of
    // anything drawn over it.
    assert!(
        again.origin.x >= box_.origin.x + box_.size.width && again.origin.y < box_.origin.y + box_.size.height * 0.5,
        "Translate again {again:?} sits beside the translation field {box_:?}, not over it"
    );
    it.app.press("label:More sentence actions").unwrap();
    it.app.wait_for("Skip from here…").unwrap();
    assert!(it.app.shows("Delete sentence"));
}

/// The made-up recording: a second of silence, two of sound, four of
/// silence, two of sound, then silence for as long as it runs.
#[test]
fn a_recording_of_what_plays_is_cut_of_its_silence_and_kept_in_the_library() {
    let mut it = start(
        "capture",
        |root| {
            fake_capture(root);
            seed_transcript(root);
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("label:Add to Library").unwrap();
    it.app.wait_for("Audio or video on this computer").unwrap();
    it.app.press("Record what’s playing").unwrap();
    it.app.wait_for("Recording goes on if you close this window.").unwrap();
    it.app.wait_for(r"text:/^00:(09|1\d)$/ >> nth=0").unwrap();
    it.app.press_key("escape").unwrap();
    it.app.wait_for_gone("Recording goes on if you close this window.", GONE).unwrap();
    it.app.press("label:Show the recording >> nth=0").unwrap();
    it.app.wait_for("Pause").unwrap();
    it.app.press("Pause").unwrap();
    it.app.wait_for("Resume").unwrap();
    it.app.press("Stop").unwrap();
    it.app.wait_for("Trim recording").unwrap();
    it.app.wait_for(r"text:/^Cuts 00:\d\d of silence in 3 places\.$/").unwrap();
    it.app.wait_for(r"text:/^Keeps 00:04 of 00:(09|1\d)$/").unwrap();
    it.app.press("Cut out silent gaps").unwrap();
    it.app.wait_for(r"text:/of silence in 3 places stays in\.$/").unwrap();
    it.app.press("Cut out silent gaps").unwrap();
    it.app.wait_for(r"text:/^Keeps 00:04 /").unwrap();
    it.app.clear("id:recording-name").unwrap();
    it.app.type_text("id:recording-name", "Evening news").unwrap();
    it.app.press("Save to Library").unwrap();
    it.app.wait_for("Saved to your Library.").unwrap();
    it.app.wait_for("Evening news").unwrap();
    assert!(!it.app.shows("Trim recording"));

    assert!(it.app.shows("Learning languages"), "what was in the Library stays");
    let kept = left_files(&it.root.join("media"), "");
    assert_eq!(kept.len(), 1, "{kept:?}");
    let file = it.root.join("media").join(&kept[0]);
    if cfg!(any(target_os = "macos", target_os = "windows")) {
        assert!(kept[0].ends_with(".m4a"), "kept as AAC: {kept:?}");
    }
    assert!(std::fs::metadata(&file).unwrap().len() > 1000);
    assert!(left_files(&it.root.join("temporary"), "capture-").is_empty(), "nothing is left behind");
    let settings: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(it.root.join("settings.json")).unwrap()).unwrap();
    assert_eq!(settings["capture_transcribe"], json!(false), "the choice to transcribe is kept");
}

#[test]
fn a_recording_left_unsaved_is_offered_again_at_the_next_start() {
    let mut it = start(
        "capture-left",
        |root| {
            fake_capture(root);
            let folder = root.join("temporary");
            std::fs::create_dir_all(&folder).unwrap();
            let mut wav =
                listenook_core::media::capture::WavWriter::create(&folder.join("capture-left.wav"), 8_000, 2).unwrap();
            let sound: Vec<i16> = (0..8_000 * 3).flat_map(|at| [((at % 40) * 400) as i16; 2]).collect();
            wav.write(&sound).unwrap();
            wav.sync().unwrap();
            std::fs::write(folder.join("capture-left.kept.wav"), b"half made").unwrap();
        },
        Vec::new(),
    );
    it.app.wait_for("A recording wasn’t saved.").unwrap();
    assert!(it.app.shows("Not saved"), "the sidebar keeps it");
    assert_eq!(left_files(&it.root.join("temporary"), "capture-"), vec!["capture-left.wav".to_owned()]);
    it.app.press("Open").unwrap();
    it.app.wait_for("Trim recording").unwrap();
    assert!(it.app.shows("Keeps 00:03 of 00:03"));
    it.app.on_dialog(|dialog| {
        assert_eq!(dialog.title.as_deref(), Some("Discard this recording?"));
        DialogAnswer::Press("Discard".to_owned())
    });
    it.app.press("Discard…").unwrap();
    it.app.wait_for_gone("Trim recording", GONE).unwrap();
    it.app.wait_for_gone("Not saved", GONE).unwrap();
    let deadline = Instant::now() + GONE;
    while !left_files(&it.root.join("temporary"), "capture-").is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(left_files(&it.root.join("temporary"), "capture-").is_empty());
}

#[test]
fn transcribing_again_replaces_the_transcript_and_what_was_made_from_it() {
    let routes = vec![
        ("POST https://api.soniox.com/v1/files".to_owned(), response(r#"{"id":"file-2"}"#)),
        ("POST https://api.soniox.com/v1/transcriptions".to_owned(), response(r#"{"id":"tr-2"}"#)),
        ("GET https://api.soniox.com/v1/transcriptions/tr-2".to_owned(), response(r#"{"status":"completed"}"#)),
        (
            "GET https://api.soniox.com/v1/transcriptions/tr-2/transcript".to_owned(),
            response(
                r#"{"tokens":[{"text":"Hello","start_ms":0,"end_ms":400,"speaker":"1"},{"text":" again.","start_ms":400,"end_ms":900,"speaker":"1"}]}"#,
            ),
        ),
        ("DELETE https://api.soniox.com/v1/transcriptions/tr-2".to_owned(), response("")),
        ("DELETE https://api.soniox.com/v1/files/file-2".to_owned(), response("")),
    ];
    let mut it = start(
        "again",
        |root| {
            seed_transcript(root);
            let media = root.join("Learning languages.m4a");
            std::fs::write(&media, b"not really audio").unwrap();
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            job["source_path"] = json!(media);
            job["remote_file_id"] = json!("file-1");
            job["remote_transcription_id"] = json!("tr-1");
            job["cleanup_state"] = json!("complete");
            std::fs::write(&path, job.to_string()).unwrap();
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.on_dialog(|dialog| {
        assert_eq!(dialog.title.as_deref(), Some("Transcribe again “Learning languages”?"));
        DialogAnswer::Press("Transcribe again".to_owned())
    });
    it.app.press("label:More actions").unwrap();
    it.app.press("Transcribe again…").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Hello again.").unwrap();
    assert!(!it.app.shows("Welcome back to the show."), "the new transcript takes the old one's place");
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""status": "completed""#));
    assert!(!saved.contains("欢迎回到节目"), "the old translation went with the old transcript");
}

#[test]
fn transcribing_again_shows_how_far_it_is_and_cancelling_keeps_the_transcript() {
    let routes = vec![
        ("POST https://api.soniox.com/v1/files".to_owned(), response(r#"{"id":"file-2"}"#)),
        ("POST https://api.soniox.com/v1/transcriptions".to_owned(), response(r#"{"id":"tr-2"}"#)),
        ("GET https://api.soniox.com/v1/transcriptions/tr-2".to_owned(), response(r#"{"status":"processing"}"#)),
        ("DELETE https://api.soniox.com/v1/transcriptions/tr-2".to_owned(), response("")),
        ("DELETE https://api.soniox.com/v1/files/file-2".to_owned(), response("")),
    ];
    let mut it = start(
        "again-cancel",
        |root| {
            seed_transcript(root);
            let media = root.join("Learning languages.m4a");
            std::fs::write(&media, b"not really audio").unwrap();
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            job["source_path"] = json!(media);
            std::fs::write(&path, job.to_string()).unwrap();
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.on_dialog(|_| DialogAnswer::Press("Transcribe again".to_owned()));
    it.app.press("label:More actions").unwrap();
    it.app.press("Transcribe again…").unwrap();
    it.app.wait_for("Transcribing").unwrap();
    assert!(it.app.shows("Welcome back to the show."), "the transcript stays readable meanwhile");
    it.app.press("role:button[Cancel]").unwrap();
    it.app.wait_for_gone("Transcribing", GONE).unwrap();
    assert!(it.app.shows("Welcome back to the show."));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""status": "completed""#), "cancelling leaves it transcribed");
}
