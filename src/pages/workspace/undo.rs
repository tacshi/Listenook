//! The last change made to a transcript in the reader, kept so it can be undone: one at a
//! time, as the toast that offers it shows one. Undoing puts back the sentences that change
//! touched and leaves the others as they are now, with what was made of them since (a
//! translation, a highlight, a mark to review).

use std::collections::HashMap;
use std::sync::Arc;

use listenook_core::{Document, Segment};

use crate::state::store;

struct Undoable {
    generation: u64,
    job_id: String,
    before: Arc<Document>,
    after: Arc<Document>,
}

thread_local! {
    static LAST_CHANGE: std::cell::RefCell<(u64, Option<Undoable>)> = const { std::cell::RefCell::new((0, None)) };
}

/// Keeps the change that took `job_id`'s transcript from `before` to `after`. The number that
/// names it.
pub(super) fn keep(job_id: String, before: Arc<Document>, after: Arc<Document>) -> u64 {
    LAST_CHANGE.with_borrow_mut(|(count, last)| {
        *count += 1;
        *last = Some(Undoable { generation: *count, job_id, before, after });
        *count
    })
}

/// Undoes the change kept last: the one named `generation` when given, else the one made to
/// `job_id`'s transcript. False when there is none to undo.
pub(super) fn undo(generation: Option<u64>, job_id: &str) -> bool {
    let taken = LAST_CHANGE.with_borrow_mut(|(_, last)| {
        let matches = last.as_ref().is_some_and(|last| match generation {
            Some(wanted) => wanted == last.generation,
            None => last.job_id == job_id,
        });
        if matches { last.take() } else { None }
    });
    let Some(Undoable { job_id, before, after, .. }) = taken else {
        return false;
    };
    let store = store();
    // A transcript that is no longer the one the change left (transcribed again, or replaced
    // by another device's) has nothing of it to put back.
    let same = |now: &Document| {
        now.segments.len() == after.segments.len()
            && now.segments.iter().zip(&after.segments).all(|(now, after)| now.id == after.id && now.text == after.text)
    };
    if !store.job_now(&job_id).and_then(|job| job.document()).is_some_and(|now| same(&now)) {
        return false;
    }
    store.update_document(&job_id, |document| {
        let by_id = |segments: &[Segment]| -> HashMap<String, Segment> {
            segments.iter().map(|segment| (segment.id.clone(), segment.clone())).collect()
        };
        let (left, now) = (by_id(&after.segments), by_id(&document.segments));
        let put_back = |segment: &Segment| {
            let untouched = left.get(&segment.id) == Some(segment);
            untouched.then(|| now.get(&segment.id).cloned()).flatten().unwrap_or_else(|| segment.clone())
        };
        document.segments = before.segments.iter().map(put_back).collect();
        document.tokens = before.tokens.clone();
        document.speakers = before.speakers.clone();
    });
    true
}
