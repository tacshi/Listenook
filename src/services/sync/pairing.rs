//! Pairing two devices: checking the code one shows and the other types, with SPAKE2, and
//! keeping each other's certificate.

use super::*;

pub(super) fn answer_pairing(out: &mut Wire, me: Device, asked: PairAsk, asker: String) -> io::Result<()> {
    if asked.device.app != "listenook" || asked.device.id.is_empty() || asked.device.id == me.id {
        return reply(out, 400, b"{}");
    }
    if asked.device.protocol != PROTOCOL {
        return reply(out, 426, b"{}");
    }
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
    let code = new_code();
    let circle = state.ledger.circle.as_ref().map(Circle::offer);
    state.pairing = Some(Pairing {
        serial,
        device: asked.device.clone(),
        code: code.clone(),
        asker,
        offer: asked.circle,
        key: None,
        attempts: 0,
        at: Instant::now(),
    });
    state.tell(Event::Pairing { serial, device: asked.device, code });
    drop(state);
    reply_json(out, &PairAnswer { device: told(me), circle })
}

/// The pairing the device holding `asker` started, while it may still finish.
pub(super) fn pairing_of<'a>(state: &'a mut State, id: &str, asker: &str) -> Option<&'a mut Pairing> {
    state
        .pairing
        .as_mut()
        .filter(|pairing| pairing.device.id == id && pairing.asker == asker && pairing.at.elapsed() < PAIR_WITHIN)
}

/// The asker's side of the code's key exchange: answers with this side. Whether the code was
/// right shows only at `finish_pairing`, where the try is counted.
pub(super) fn confirm_pairing(out: &mut Wire, me: &Device, theirs: PairKey, asker: &str) -> io::Result<()> {
    let mine = state().identity.as_ref().map(|identity| identity.fingerprint.clone()).unwrap_or_default();
    let mut state = state();
    let Some(pairing) = pairing_of(&mut state, &theirs.id, asker) else {
        drop(state);
        return refuse(out, "expired");
    };
    let (pake, message) = Pake::start(&pairing.code, (&pairing.device.id, asker), (&me.id, &mine), false);
    let Some(key) = pake.finish(&theirs.message) else {
        drop(state);
        return reply(out, 400, b"{}");
    };
    pairing.key = Some(key);
    drop(state);
    reply_json(out, &PairKey { id: me.id.clone(), message })
}

pub(super) fn finish_pairing(out: &mut Wire, me: &Device, finish: PairFinish, asker: &str) -> io::Result<()> {
    let mine = state().identity.as_ref().map(|identity| identity.fingerprint.clone()).unwrap_or_default();
    let mut state = state();
    let Some(pairing) = pairing_of(&mut state, &finish.id, asker) else {
        drop(state);
        return refuse(out, "expired");
    };
    let Some(key) = pairing.key.take() else {
        drop(state);
        return refuse(out, "expired");
    };
    if !same(&finish.proof, &pake_proof(&key, "asker")) {
        pairing.attempts += 1;
        let attempts = pairing.attempts;
        state.misses.miss();
        let waiting = state.misses.waiting();
        let spent = attempts >= PAIR_ATTEMPTS || waiting;
        if spent && let Some(pairing) = state.pairing.take() {
            state.tell(Event::Paired { serial: pairing.serial, name: None });
        }
        drop(state);
        let reason = if waiting {
            "wait"
        } else if spent {
            "expired"
        } else {
            "wrong"
        };
        return refuse(out, reason);
    }
    let Some(pairing) = state.pairing.take() else {
        return refuse(out, "expired");
    };
    state.misses = Misses::default();
    // Both circles end as one, with the devices of both; it keeps the name of the larger one.
    let mine_offer = state.ledger.circle.as_ref().map(Circle::offer);
    let joins = joins_answerer(pairing.offer.as_ref(), mine_offer.as_ref());
    let circle = state.ledger.circle.get_or_insert_with(new_circle);
    if let Some(theirs) = &finish.circle {
        if !joins && !theirs.id.is_empty() {
            circle.id = theirs.id.clone();
        }
        merge_members(&mut circle.members, &theirs.members);
    }
    join(circle, [(me, &mine), (&pairing.device, asker)]);
    let shared = Shared { id: circle.id.clone(), members: circle.members.clone() };
    let circle = circle.clone();
    state.adopt(circle);
    state.save();
    state.tell(Event::Paired { serial: pairing.serial, name: Some(pairing.device.name.clone()) });
    drop(state);
    reply_json(out, &PairDone { proof: pake_proof(&key, "answerer"), circle: shared })
}

pub(crate) fn pair(address: SocketAddr) -> Result<Device, &'static str> {
    let (me, offer) = {
        let state = state();
        (state.me.clone(), state.ledger.circle.as_ref().map(Circle::offer))
    };
    if me.id.is_empty() {
        return Err("sync_failed");
    }
    let seen = Arc::new(Mutex::new(String::new()));
    let asked = PairAsk { device: me, circle: offer };
    let answer: PairAnswer = identity()?
        .agent(None, Some(seen.clone()), Duration::from_secs(10))
        .post(&format!("https://{address}/listenook/pair"))
        .send_bytes(&serde_json::to_vec(&asked).map_err(|_| "sync_failed")?)
        .map_err(code_of)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(256 * 1024)).map_err(|_| "sync_failed")
        })?;
    if !answer.device.is_compatible() {
        return Err("sync_incompatible");
    }
    let answerer = seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
    if answerer.is_empty() {
        return Err("sync_failed");
    }
    remember(answer.device.clone(), address);
    state().asking = Some(Asking { address, device: answer.device.clone(), answerer });
    Ok(answer.device)
}

pub(crate) fn confirm(code: &str) -> Result<(), &'static str> {
    let code: String = code.chars().filter(char::is_ascii_digit).collect();
    if !is_code(&code) {
        return Err("sync_wrong_code");
    }
    let identity = identity()?;
    let (asking, me, circle) = {
        let state = state();
        (state.asking.clone().ok_or("sync_code_expired")?, state.me.clone(), state.ledger.circle.clone())
    };
    // Only the device seen when asking: a certificate that changed is someone else.
    let agent = identity.agent(Some(&asking.answerer), None, Duration::from_secs(10));
    let base = format!("https://{}/listenook", asking.address);
    let refused = |error: ureq::Error| -> &'static str {
        match error {
            ureq::Error::Status(403, response) => {
                let reason = reason(response);
                if reason == "wrong" {
                    return "sync_wrong_code";
                }
                state().asking = None;
                if reason == "wait" { "sync_pair_wait" } else { "sync_code_expired" }
            }
            ureq::Error::Status(404 | 410, _) => {
                state().asking = None;
                "sync_code_expired"
            }
            error => code_of(error),
        }
    };
    let (pake, message) =
        Pake::start(&code, (&me.id, &identity.fingerprint), (&asking.device.id, &asking.answerer), true);
    let sent = PairKey { id: me.id.clone(), message };
    let theirs: PairKey = agent
        .post(&format!("{base}/pair/confirm"))
        .send_bytes(&serde_json::to_vec(&sent).map_err(|_| "sync_failed")?)
        .map_err(refused)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(64 * 1024)).map_err(|_| "sync_failed")
        })?;
    let key = pake.finish(&theirs.message).ok_or("sync_failed")?;
    let finish = PairFinish {
        id: me.id.clone(),
        proof: pake_proof(&key, "asker"),
        circle: circle.as_ref().map(|circle| Shared { id: circle.id.clone(), members: circle.members.clone() }),
    };
    let done: PairDone = agent
        .post(&format!("{base}/pair/finish"))
        .send_bytes(&serde_json::to_vec(&finish).map_err(|_| "sync_failed")?)
        .map_err(refused)
        .and_then(|response| {
            serde_json::from_reader(response.into_reader().take(4 * 1024 * 1024)).map_err(|_| "sync_failed")
        })?;
    let mut state = state();
    state.asking = None;
    if !same(&done.proof, &pake_proof(&key, "answerer")) {
        return Err("sync_failed");
    }
    let mut circle = circle.unwrap_or_else(new_circle);
    if !done.circle.id.is_empty() {
        circle.id = done.circle.id;
    }
    merge_members(&mut circle.members, &done.circle.members);
    join(&mut circle, [(&me, &identity.fingerprint), (&asking.device, &asking.answerer)]);
    state.adopt(circle);
    state.ledger.seen.entry(asking.device.id.clone()).or_default().learn(&asking.device);
    state.saw(&asking.device.id, asking.address, None);
    Ok(())
}

pub(crate) fn abandon() {
    let (asking, id, identity) = {
        let mut state = state();
        (state.asking.take(), state.me.id.clone(), state.identity.clone())
    };
    if let (Some(asking), Some(identity)) = (asking, identity) {
        thread::spawn(move || {
            let _ = identity
                .agent(Some(&asking.answerer), None, Duration::from_secs(3))
                .post(&format!("https://{}/listenook/pair/cancel/{id}", asking.address))
                .call();
        });
    }
}
