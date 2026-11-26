//! The last change made to a transcript in the reader, kept so it can be undone: one at a
//! time, as the toast that offers it shows one.

use listenook_core::Document;

use crate::state::store;

struct Undoable {
    generation: u64,
    job_id: String,
    before: std::sync::Arc<Document>,
}

thread_local! {
    static LAST_CHANGE: std::cell::RefCell<(u64, Option<Undoable>)> = const { std::cell::RefCell::new((0, None)) };
}

pub(super) fn keep(job_id: String, before: std::sync::Arc<Document>) -> u64 {
    LAST_CHANGE.with_borrow_mut(|(count, last)| {
        *count += 1;
        *last = Some(Undoable { generation: *count, job_id, before });
        *count
    })
}

pub(super) fn undo(generation: Option<u64>) -> bool {
    let taken = LAST_CHANGE.with_borrow_mut(|(_, last)| {
        let matches = last.as_ref().is_some_and(|last| generation.is_none_or(|wanted| wanted == last.generation));
        if matches { last.take() } else { None }
    });
    let Some(Undoable { job_id, before, .. }) = taken else {
        return false;
    };
    store().update_document(&job_id, |document| {
        document.segments = before.segments.clone();
        document.tokens = before.tokens.clone();
        document.speakers = before.speakers.clone();
    });
    true
}
