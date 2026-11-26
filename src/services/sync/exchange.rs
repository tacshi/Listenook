//! A round of sync with another device: what each side has, and the recordings, settings and
//! progress that go each way.

use super::*;

pub(super) fn welcome(
    out: &mut Wire,
    root: &Path,
    me: Device,
    hello: Hello,
    from: IpAddr,
    peer: &str,
) -> io::Result<()> {
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

pub(super) fn open_session(
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

pub(super) fn manifest_path(root: &Path, id: &str) -> PathBuf {
    root.join("jobs").join(id).join("manifest.json")
}

pub(super) fn media_of(root: &Path, job: &Job) -> Option<PathBuf> {
    let path = PathBuf::from(
        persist::rehomed(&job.source_path, root, Path::is_file).unwrap_or_else(|| job.source_path.clone()),
    );
    (!persist::climbs(&path)).then_some(path)
}

pub(super) fn names(entries: &[Entry]) -> impl Iterator<Item = (String, String)> + '_ {
    entries.iter().filter_map(|entry| {
        let name = entry.media_name.as_ref().filter(|name| !is_sync_name(&entry.id, name))?;
        Some((entry.id.clone(), name.clone()))
    })
}

pub(super) fn library(root: &Path) -> (Index, String) {
    let (mut index, revision) = recordings(root);
    index.shelves = Shelves::of_settings(&persist::load_settings(root));
    let shelves = serde_json::to_string(&index.shelves).unwrap_or_default();
    let revision = digest(&[&revision, &shelves]);
    (index, revision)
}

pub(super) fn recordings(root: &Path) -> (Index, String) {
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

pub(super) fn index_of(root: &Path, busy: &HashSet<String>) -> (Index, String) {
    let (mut index, revision) = library(root);
    for entry in &mut index.entries {
        entry.busy |= busy.contains(&entry.id);
    }
    (index, revision)
}

pub(super) fn copy(
    from: &mut impl Read,
    to: &mut impl Write,
    length: u64,
    mut alive: impl FnMut(u64) -> bool,
) -> io::Result<()> {
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

pub(super) fn receive(
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

pub(super) fn code_of(error: ureq::Error) -> &'static str {
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

pub(super) fn reach(id: &str, looked: &mut bool, turn: u64) -> Option<(SocketAddr, Device)> {
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

pub(super) fn persist_with(
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
pub(super) fn leave_large_media(plan: &mut listenook_core::sync::Plan) -> u32 {
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

pub(super) fn recoverable(code: &str) -> bool {
    matches!(code, "sync_interrupted" | "sync_unreachable")
}

/// Syncs with the device at `address` whose certificate has the fingerprint `key`, as the
/// device `identity` is.
pub(super) fn exchange(
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

pub(super) struct Counted<'a, R, F: Fn(u64) -> bool> {
    inner: R,
    moved: &'a F,
}

impl<R: Read, F: Fn(u64) -> bool> Read for Counted<'_, R, F> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.inner.read(buffer)?;
        if (self.moved)(read as u64) { Ok(read) } else { Err(io::Error::other("stopped")) }
    }
}
