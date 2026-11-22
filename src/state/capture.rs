//! The one recording of what the computer plays: started from the Library,
//! the menus or the tray, going on wherever the app goes meanwhile, then
//! trimmed and kept in the Library, or thrown away. A recording not yet
//! saved survives the app quitting: it is offered again at the next start.

use std::{path::PathBuf, rc::Rc};

use listenook_core::capture::{self, Span, Trim};
use nsh_core::prelude::*;

use crate::services::capture::{self as service, Access, Recorder, Take};

/// Where the recording is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum Phase {
    /// Nothing recorded.
    #[default]
    Idle,
    /// Waiting for the system to set recording up, or for the person to
    /// allow it.
    Starting,
    /// The system does not let Listenook hear other apps.
    Denied,
    Recording,
    /// Finishing the file.
    Stopping,
    /// Stopped, and being trimmed.
    Trimming,
    /// Writing the file to keep.
    Saving,
}

/// How many 10 ms levels the live meter shows: the last 12 seconds.
pub(crate) const RECENT_LEVELS: usize = 1_200;

#[derive(Clone, Copy)]
pub(crate) struct CaptureState {
    /// Whether the recording's dialog is shown: it can be put away while the
    /// recording goes on.
    pub(crate) open: Signal<bool>,
    phase: Signal<Phase>,
    paused: Signal<bool>,
    elapsed_ms: Signal<u64>,
    recent: Signal<Vec<f32>>,
    heard: Signal<bool>,
    recorder: Stored<Option<Recorder>>,
    /// When the recording started, which names it.
    started: Stored<String>,
    take: Signal<Option<Rc<Take>>>,
    gaps: Memo<Vec<Span>>,
    pub(crate) trim: Signal<Trim>,
    pub(crate) title: Signal<String>,
    /// An error code while the last try failed.
    error: Signal<Option<&'static str>>,
}

impl CaptureState {
    pub(super) fn new() -> Self {
        let take = signal(None::<Rc<Take>>);
        Self {
            open: signal(false),
            phase: signal(Phase::Idle),
            paused: signal(false),
            elapsed_ms: signal(0),
            recent: signal(Vec::new()),
            heard: signal(false),
            recorder: stored(None),
            started: stored(String::new()),
            take,
            gaps: computed(move || take.with(|take| take.as_ref().map(|take| take.gaps()).unwrap_or_default())),
            trim: signal(Trim { start_ms: 0, end_ms: 0, cut_gaps: true }),
            title: signal(String::new()),
            error: signal(None),
        }
    }

    pub(crate) fn phase(&self) -> Phase {
        self.phase.get()
    }

    pub(crate) fn paused(&self) -> bool {
        self.paused.get()
    }

    pub(crate) fn elapsed_ms(&self) -> u64 {
        self.elapsed_ms.get()
    }

    pub(crate) fn recent(&self) -> Signal<Vec<f32>> {
        self.recent
    }

    /// Whether anything was heard since recording started.
    pub(crate) fn heard(&self) -> bool {
        self.heard.get()
    }

    pub(crate) fn error(&self) -> Option<&'static str> {
        self.error.get()
    }

    /// Whether something is being recorded, paused or not.
    pub(crate) fn recording(&self) -> bool {
        matches!(self.phase.get(), Phase::Recording | Phase::Stopping)
    }

    /// Whether a recording waits: being made, or made and not yet saved.
    pub(crate) fn pending(&self) -> bool {
        !matches!(self.phase.get(), Phase::Idle | Phase::Denied | Phase::Starting)
    }

    pub(crate) fn take(&self) -> Option<Rc<Take>> {
        self.take.get()
    }

    pub(crate) fn gaps(&self) -> Memo<Vec<Span>> {
        self.gaps
    }

    /// The parts kept as the recording is trimmed now.
    pub(crate) fn kept(&self) -> Vec<Span> {
        self.gaps.with(|gaps| capture::kept(&self.trim.get(), gaps))
    }

    /// Opens the recording's dialog, starting to record when nothing is
    /// recorded yet.
    pub(crate) fn record(&self) {
        let store = super::store();
        self.open.set(true);
        if !matches!(self.phase.get_untracked(), Phase::Idle | Phase::Denied) {
            return;
        }
        let Some(root) = store.data_root() else {
            self.error.set(Some("capture_failed"));
            return;
        };
        if service::support() != service::Support::Yes {
            self.failed("capture_unsupported");
            return;
        }
        batch(|| {
            self.phase.set(Phase::Starting);
            self.error.set(None);
        });
        let state = *self;
        store.run(async move {
            let allowed = match service::access() {
                Access::Granted => true,
                Access::Denied => false,
                Access::Unknown => blocking(service::ask).await.unwrap_or(false),
            };
            if state.phase.get_untracked() != Phase::Starting {
                // Cancelled while the system asked.
                return;
            }
            if !allowed {
                state.phase.set(Phase::Denied);
                return;
            }
            let path = root.join("temporary").join(format!("capture-{}.wav", uuid::Uuid::new_v4().simple()));
            match blocking(move || Recorder::start(path)).await {
                Ok(Ok(recorder)) => state.began(recorder),
                Ok(Err(code)) => state.failed(code),
                Err(_) => state.failed("capture_failed"),
            }
        });
    }

    fn began(&self, recorder: Recorder) {
        if self.phase.get_untracked() != Phase::Starting {
            // Discarded while it was being set up.
            drop(recorder);
            return;
        }
        self.recorder.replace(Some(recorder));
        self.started.replace(capture::stamp());
        let store = super::store();
        batch(|| {
            self.phase.set(Phase::Recording);
            self.paused.set(false);
            self.elapsed_ms.set(0);
            self.recent.set(Vec::new());
            self.heard.set(false);
            // What Listenook plays itself stops, so it is not recorded over.
            store.sleep.pause_players();
        });
        let state = *self;
        store.run(async move {
            while state.phase.get_untracked() == Phase::Recording {
                timer(std::time::Duration::from_millis(100)).await;
                let Some((elapsed, recent, heard, full)) = state.recorder.with(|recorder| {
                    recorder.as_ref().map(|recorder| {
                        (
                            recorder.elapsed_ms(),
                            recorder.recent_levels(RECENT_LEVELS),
                            recorder.heard(),
                            recorder.full(),
                        )
                    })
                }) else {
                    return;
                };
                batch(|| {
                    state.elapsed_ms.set(elapsed);
                    state.recent.set(recent);
                    state.heard.set(heard);
                });
                if full {
                    state.stop();
                    crate::ui::toast(crate::ui::Tone::Info, super::tr("Recording stopped at 5 hours."));
                }
            }
        });
    }

    fn failed(&self, code: &'static str) {
        batch(|| {
            self.phase.set(Phase::Idle);
            self.error.set(Some(code));
        });
    }

    /// Records again after the system said no, once it is allowed.
    pub(crate) fn retry(&self) {
        if self.phase.get_untracked() == Phase::Denied && service::access() != Access::Denied {
            self.phase.set(Phase::Idle);
            self.record();
        }
    }

    pub(crate) fn set_paused(&self, paused: bool) {
        self.recorder.with(|recorder| {
            if let Some(recorder) = recorder {
                recorder.set_paused(paused);
            }
        });
        self.paused.set(paused);
    }

    /// Stops recording, and shows the recording to trim.
    pub(crate) fn stop(&self) {
        let Some(recorder) = self.recorder.replace(None) else {
            return;
        };
        self.phase.set(Phase::Stopping);
        let state = *self;
        super::store().run(async move {
            match blocking(move || recorder.stop()).await {
                Ok(Ok(take)) => state.trim_take(take, state.started.get(), true),
                Ok(Err(code)) => state.failed(code),
                Err(_) => state.failed("capture_write_failed"),
            }
        });
    }

    fn trim_take(&self, take: Take, started: String, open: bool) {
        let store = super::store();
        let cut_gaps =
            store.setting(|s| s.extra.get("capture_cut_gaps").and_then(|value| value.as_bool()).unwrap_or(true));
        let title = format!("{} {started}", super::tr("Recording"));
        batch(|| {
            self.trim.set(Trim { start_ms: 0, end_ms: take.duration_ms, cut_gaps });
            self.title.set(title);
            self.take.set(Some(Rc::new(take)));
            self.phase.set(Phase::Trimming);
            self.paused.set(false);
            if open {
                self.open.set(true);
            }
        });
    }

    pub(crate) fn set_cut_gaps(&self, cut_gaps: bool) {
        self.trim.update(|trim| trim.cut_gaps = cut_gaps);
        super::store().update_settings(|s| {
            s.extra.insert("capture_cut_gaps".into(), cut_gaps.into());
        });
    }

    /// Throws the recording away, stopping it first if it runs.
    pub(crate) fn discard(&self) {
        let recorder = self.recorder.replace(None);
        let made = self.take.get_untracked().map(|take| take.path.clone());
        batch(|| {
            self.phase.set(Phase::Idle);
            self.take.set(None);
            self.open.set(false);
            self.paused.set(false);
        });
        blocking(move || {
            let path = recorder.and_then(|recorder| recorder.stop().ok()).map(|take| take.path);
            for path in path.into_iter().chain(made) {
                let _ = std::fs::remove_file(path);
            }
        });
    }

    /// Keeps the trimmed recording in the Library, then transcribes it when
    /// `transcribe`.
    pub(crate) fn save(&self, transcribe: bool) {
        let Some(take) = self.take.get_untracked() else {
            return;
        };
        let spans = self.kept();
        if spans.is_empty() || self.phase.get_untracked() != Phase::Trimming {
            return;
        }
        let title = Some(self.title.get_untracked().trim().to_owned())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| super::tr("Recording").to_string());
        let store = super::store();
        store.update_settings(|s| {
            s.extra.insert("capture_transcribe".into(), transcribe.into());
        });
        self.phase.set(Phase::Saving);
        let state = *self;
        store.run(async move {
            let source = take.path.clone();
            let made = blocking(move || service::export(&source, &spans)).await;
            let kept = match made {
                Ok(Ok(kept)) => kept,
                Ok(Err(code)) => return state.save_failed(code),
                Err(_) => return state.save_failed("capture_write_failed"),
            };
            let Some(id) = crate::util::add_recording(&kept, &title) else {
                let _ = std::fs::remove_file(&kept);
                return state.save_failed("capture_write_failed");
            };
            let _ = std::fs::remove_file(&take.path);
            batch(|| {
                state.phase.set(Phase::Idle);
                state.take.set(None);
                state.open.set(false);
            });
            if transcribe {
                crate::services::transcribe::start(&id);
            }
            let store = super::store();
            crate::ui::toast_with_action(
                crate::ui::Tone::Success,
                super::tr(if transcribe {
                    "Saved to your Library. Transcribing now."
                } else {
                    "Saved to your Library."
                }),
                super::tr("Show"),
                move || store.show(super::Filter::All),
            );
        });
    }

    fn save_failed(&self, code: &'static str) {
        self.phase.set(Phase::Trimming);
        crate::ui::toast(crate::ui::Tone::Error, super::error_text(code));
    }

    /// Whether to transcribe what is saved, as chosen last.
    pub(crate) fn transcribes(&self) -> bool {
        super::store().setting(|s| s.extra.get("capture_transcribe").and_then(|value| value.as_bool()).unwrap_or(false))
    }

    /// Finishes the file of a recording that runs as the app quits, so it is
    /// offered again at the next start.
    pub(crate) fn finish_on_quit(&self) {
        if let Some(recorder) = self.recorder.replace(None) {
            let _ = recorder.stop();
        }
    }

    /// Offers a recording a run that ended before it was saved left behind.
    pub(crate) fn recover(&self, temporary: PathBuf) {
        let state = *self;
        super::store().run(async move {
            let found = blocking(move || {
                let mut left = Vec::new();
                for path in std::fs::read_dir(&temporary).into_iter().flatten().flatten().map(|entry| entry.path()) {
                    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
                    if !name.starts_with("capture-") {
                        continue;
                    }
                    if name.ends_with(".kept.wav") || name.ends_with(".m4a") {
                        // What saving had made when the app stopped.
                        let _ = std::fs::remove_file(&path);
                    } else if name.ends_with(".wav") {
                        left.push(path);
                    }
                }
                left.sort_by_key(|path| std::fs::metadata(path).and_then(|meta| meta.modified()).ok());
                let newest = left.pop();
                for older in left {
                    let _ = std::fs::remove_file(older);
                }
                let newest = newest?;
                let Some(take) = Take::left(&newest) else {
                    let _ = std::fs::remove_file(&newest);
                    return None;
                };
                // It started its length before it was last written.
                let written = std::fs::metadata(&newest).and_then(|meta| meta.modified());
                let started = written
                    .ok()
                    .and_then(|written| written.checked_sub(std::time::Duration::from_millis(take.duration_ms)))
                    .map_or_else(capture::stamp, capture::stamp_at);
                Some((take, started))
            })
            .await;
            let Ok(Some((take, started))) = found else {
                return;
            };
            if state.phase.get_untracked() != Phase::Idle {
                return;
            }
            state.trim_take(take, started, false);
            crate::ui::toast_with_action(
                crate::ui::Tone::Info,
                super::tr("A recording wasn’t saved."),
                super::tr("Open"),
                move || state.open.set(true),
            );
        });
    }
}
