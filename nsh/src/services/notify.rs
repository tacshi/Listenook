//! System notifications for work that finished while the user was
//! elsewhere: a transcription, a download.

use listenook_core::{Job, JobStatus};
use nsh_core::{notifications::Notification, prelude::*};

use crate::state::{error_text, store, tr};

thread_local! {
    static ASKED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The title (untranslated) for a job going from `was` to the state it is
/// in, if that is worth a notification: work ended, well or badly.
fn title(job: &Job, was: JobStatus) -> Option<&'static str> {
    // Word timing follows a transcript that was announced already.
    if !was.is_active() || was == JobStatus::Aligning {
        return None;
    }
    Some(match (was, job.status) {
        (JobStatus::Downloading, JobStatus::Ready | JobStatus::Completed) => "Download finished",
        (_, JobStatus::Completed) => "Transcription finished",
        (_, JobStatus::Empty) => "No speech found",
        (JobStatus::Downloading, JobStatus::Failed) => "Download failed",
        (_, JobStatus::Failed | JobStatus::MissingSource) => "Transcription failed",
        _ => return None,
    })
}

/// Tells the user a job's work ended, when they asked to be told and the
/// app is not in front of them.
pub(crate) fn job_changed(job: &Job, was: JobStatus) {
    let store = store();
    let wanted = store.setting(|s| s.extra.get("notify_when_done").and_then(|v| v.as_bool()).unwrap_or(true));
    if !wanted || store.focused() {
        return;
    }
    let Some(title) = title(job, was).map(tr) else {
        return;
    };
    let body = match (job.status, job.error_code.as_deref()) {
        (JobStatus::Failed | JobStatus::MissingSource, Some(code)) => format!("{} — {}", job.title(), error_text(code)),
        _ => job.title(),
    };
    let id = job.id.clone();
    store.run(async move {
        // The system asks the user once; after that it remembers.
        if !ASKED.replace(true) {
            let _ = request_notification_permission().await;
        }
        let _ = show_notification(Notification::new(id, title.to_string(), body)).await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_work_that_ended_is_announced() {
        let job = |status| Job { status, source_path: "/x/Talk.mp3".into(), ..Job::default() };
        assert!(title(&job(JobStatus::Completed), JobStatus::Processing).is_some());
        assert!(title(&job(JobStatus::Ready), JobStatus::Downloading).is_some());
        assert!(title(&job(JobStatus::Failed), JobStatus::Uploading).is_some());
        assert!(title(&job(JobStatus::Completed), JobStatus::Aligning).is_none(), "announced when transcribed");
        assert!(title(&job(JobStatus::Processing), JobStatus::Uploading).is_none(), "still working");
        assert!(title(&job(JobStatus::Cancelled), JobStatus::Processing).is_none(), "the user stopped it");
        assert!(title(&job(JobStatus::Completed), JobStatus::Ready).is_none(), "nothing was running");
    }
}
