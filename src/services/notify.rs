use listenook_core::{Job, JobStatus};
use nsh_core::{notifications::Notification, prelude::*};

use crate::state::{error_text, store, tr};

thread_local! {
    static ASKED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn title(job: &Job, was: JobStatus) -> Option<&'static str> {
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
