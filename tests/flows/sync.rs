//! Sync with another device: pairing, rounds, and what goes each way.

use super::*;

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
    it.app.type_text("text:192.168.1.20 or a Tailscale name", &format!("127.0.0.1:{port}")).unwrap();
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
    it.app.type_text("text:192.168.1.20 or a Tailscale name", &format!("127.0.0.1:{port}")).unwrap();
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
