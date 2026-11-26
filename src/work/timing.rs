//! Timing each word of a transcript that times only its sentences (a local transcription,
//! subtitles), with the aligner on this device.

use listenook_core::Job;

use crate::{
    services::local,
    state::{Store, store},
};

/// Times the words of `id`'s new transcript when that is set to happen on its own and can here,
/// from `samples` of its audio or, without them, its file.
pub(crate) async fn add_word_timing(store: Store, id: &str, samples: Option<std::sync::Arc<Vec<i16>>>) {
    let Some(job) = store.job_now(id) else {
        return;
    };
    if !store.setting(|s| s.auto_align_transcripts) || !local::can_align(&job) {
        return;
    }
    time_words(store, id, &job, samples).await;
}

async fn time_words(store: Store, id: &str, job: &Job, samples: Option<std::sync::Arc<Vec<i16>>>) {
    store.update_job(id, |job| job.apply(listenook_core::Change::BeginAlignment));
    let samples = match samples {
        Some(samples) => Some(samples),
        None => local::prepare_audio(job).await.ok(),
    };
    let record = match samples {
        Some(samples) => {
            let job_id = id.to_owned();
            let progress =
                move |fraction| store.act(crate::state::Action::SetProgress(&job_id, "aligning", Some(fraction)));
            let (record, tokens) = local::align(job, samples, progress).await;
            if !tokens.is_empty() {
                store.update_document(id, |document| listenook_core::transcript::local::take_aligned(document, tokens));
            }
            record
        }
        None => serde_json::json!({"status": "failed", "warning_code": "alignment_source_missing"}),
    };
    store.update_job(id, |job| job.apply(listenook_core::Change::EndAlignment(record)));
}

/// Times the words of `id`'s transcript now, as asked from the Library.
pub(crate) fn align(id: &str) {
    let store = store();
    let id = id.to_owned();
    store.run_for(&id.clone(), async move {
        if let Some(job) = store.job_now(&id).filter(|job| local::can_align(job)) {
            time_words(store, &id, &job, None).await;
        }
    });
}
