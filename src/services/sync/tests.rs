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
            let member =
                Member { name: (*id).into(), joined_at: now_iso(), key: fingerprint_of(library), ..Member::default() };
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
    let theirs = match post(&agent, &format!("{base}/pair/confirm"), &PairKey { id: "device-here".into(), message }) {
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
    let catalog = LibraryCatalog { tags: vec![Named { id: "t1".into(), name: "todo".into() }], ..Default::default() };
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
    let places_go = incoming.iter().any(
        |incoming| matches!(incoming, Incoming::Podcasts(p) if p.listened.iter().any(|e| e.episode_id == "heard-here")),
    );
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
    assert!(matches!(elsewhere, Err(ureq::Error::Transport(_))), "a device with another certificate is not trusted");
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
    let seen = Peer { device: Device { id: "other".into(), ..Device::default() }, address: ([127, 0, 0, 1], 9).into() };
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
