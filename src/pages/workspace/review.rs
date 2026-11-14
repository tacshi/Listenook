use std::{rc::Rc, time::Duration};

use listenook_core::{ContentMode, Document, Job, Segment, dictation};
use nsh_core::prelude::*;

use crate::{
    state::{Store, store, tr},
    ui::{Tone, toast_with_action},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Side {
    None,
    Practice,
    Brief,
    Video,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Practice {
    None,
    Dictation,
    Mimic,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Editing {
    pub(super) segment_id: String,
    pub(super) translation: bool,
}

#[derive(Clone, Copy)]
pub(super) struct Review {
    pub(super) store: Store,
    id: Stored<String>,
    pub(super) job: Memo<Option<Rc<Job>>>,
    pub(super) player: ElementRef,
    pub(super) list: ElementRef,
    pub(super) position_ms: Signal<i64>,
    pub(super) duration_ms: Signal<i64>,
    pub(super) paused: Signal<bool>,
    pub(super) rate: Signal<f32>,
    pub(super) has_video: bool,
    pub(super) side: Signal<Side>,
    pub(super) video_wanted: Signal<bool>,
    pub(super) mode: Signal<ContentMode>,
    pub(super) searching: Signal<bool>,
    pub(super) query: Signal<String>,
    pub(super) repeating: Signal<Option<String>>,
    pub(super) looping: Signal<bool>,
    pub(super) revealed: Signal<Option<String>>,
    pub(super) editing: Signal<Option<Editing>>,
    pub(super) draft: Signal<String>,
    pub(super) caret: Signal<u32>,
    pub(super) side_width: Signal<f32>,
    pub(super) brief_editing: Signal<Option<BriefPart>>,
    pub(super) video_on_top: Signal<bool>,
    pub(super) video_height: Signal<f32>,
    pub(super) fullscreen: Signal<bool>,
    pub(super) practice: Signal<Practice>,
    pub(super) reps: Signal<u32>,
    pub(super) waiting: Signal<bool>,
    pub(super) stop_at: Signal<Option<i64>>,
    wait: Stored<Option<Spawned<()>>>,
    pub(super) current: Memo<Option<usize>>,
    pub(super) scrub: Signal<Option<i64>>,
    pub(super) scrubbed: Memo<Option<usize>>,
    pub(super) shown: Memo<Vec<usize>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum BriefPart {
    Overview,
    Chapter(String),
    Insight(String),
    Note(String),
}

pub(super) const SIDE_WIDTH: f32 = 400.0;
pub(super) const SIDE_MIN: f32 = 280.0;
pub(super) const SIDE_MAX: f32 = 760.0;
pub(super) const VIDEO_HEIGHT: f32 = 320.0;
pub(super) const VIDEO_MIN: f32 = 160.0;
pub(super) const VIDEO_MAX: f32 = 720.0;

impl Review {
    pub(super) fn new(id: &str) -> Review {
        let store = store();
        let owned = id.to_owned();
        let job = computed(move || store.job(&owned));
        let position_ms = signal(store.setting(|s| s.playback_positions_ms.get(id).copied()).unwrap_or(0));
        let has_translation = job.with_untracked(|job| {
            job.as_ref()
                .and_then(|job| job.document.as_ref())
                .is_some_and(|d| d.segments.iter().any(Segment::has_translation))
        });
        let has_video = job.with_untracked(|job| {
            job.as_ref().is_some_and(|job| {
                if crate::services::playable::needs_help(&job.source_path) {
                    crate::services::playable::keeps_picture(&job.source_path)
                } else {
                    job.has_video()
                        || matches!(
                            listenook_core::subtitles::extension(&job.source_path).as_str(),
                            "mp4" | "mkv" | "avi"
                        )
                }
            })
        });
        let query = signal(String::new());
        let searching = signal(false);
        let current = computed(move || {
            let position = position_ms.get();
            job.with(|job| job.as_ref()?.document.as_ref()?.segment_at(position))
        });
        let scrub = signal(None::<i64>);
        let scrubbed = computed(move || {
            let at = scrub.get()?;
            job.with(|job| job.as_ref()?.document.as_ref()?.segment_at(at))
        });
        let shown = computed(move || {
            let needle = if searching.get() { query.with(|q| q.trim().to_lowercase()) } else { String::new() };
            job.with(|job| {
                let Some(document) = job.as_ref().and_then(|job| job.document.as_ref()) else {
                    return Vec::new();
                };
                document
                    .segments
                    .iter()
                    .enumerate()
                    .filter(|(_, segment)| {
                        needle.is_empty()
                            || segment.text.to_lowercase().contains(&needle)
                            || segment.translated_text.as_ref().is_some_and(|t| t.to_lowercase().contains(&needle))
                            || document.speaker_name(segment.speaker.as_deref()).to_lowercase().contains(&needle)
                    })
                    .map(|(index, _)| index)
                    .collect()
            })
        });
        Review {
            store,
            id: stored(id.to_owned()),
            job,
            player: element_ref(),
            list: element_ref(),
            position_ms,
            duration_ms: signal(0),
            paused: signal(true),
            rate: signal(store.saved_rate("playback_rate")),
            has_video,
            side: signal(if has_video { Side::Video } else { Side::None }),
            video_wanted: signal(has_video),
            mode: signal(if has_translation { ContentMode::Bilingual } else { ContentMode::Original }),
            searching,
            query,
            repeating: signal(None),
            looping: signal(false),
            revealed: signal(None),
            editing: signal(None),
            draft: signal(String::new()),
            caret: signal(0),
            brief_editing: signal(None),
            side_width: signal(
                store
                    .setting(|s| s.extra.get("reader_side_width").and_then(serde_json::Value::as_f64))
                    .map_or(SIDE_WIDTH, |width| (width as f32).clamp(SIDE_MIN, SIDE_MAX)),
            ),
            video_on_top: signal(
                store
                    .setting(|s| s.extra.get("reader_video_on_top").and_then(serde_json::Value::as_bool))
                    .unwrap_or(false),
            ),
            video_height: signal(
                store
                    .setting(|s| s.extra.get("reader_video_height").and_then(serde_json::Value::as_f64))
                    .map_or(VIDEO_HEIGHT, |height| (height as f32).clamp(VIDEO_MIN, VIDEO_MAX)),
            ),
            fullscreen: signal(false),
            practice: signal(Practice::None),
            reps: signal(0),
            waiting: signal(false),
            stop_at: signal(None),
            wait: stored(None),
            current,
            scrub,
            scrubbed,
            shown,
        }
    }

    pub(super) fn id(&self) -> String {
        self.id.with(|id| id.clone())
    }

    pub(super) fn segment(&self, index: usize) -> Option<Segment> {
        self.job.with(|job| job.as_ref()?.document.as_ref()?.segments.get(index).cloned())
    }

    fn segment_now(&self, index: usize) -> Option<Segment> {
        self.job.with_untracked(|job| job.as_ref()?.document.as_ref()?.segments.get(index).cloned())
    }

    fn play_start(&self, index: usize) -> i64 {
        self.job.with_untracked(|job| {
            job.as_ref().and_then(|job| job.document.as_ref()?.play_start(index)).unwrap_or_default()
        })
    }

    fn index_of(&self, segment_id: &str) -> Option<usize> {
        self.job.with_untracked(|job| {
            job.as_ref()?.document.as_ref()?.segments.iter().position(|segment| segment.id == segment_id)
        })
    }

    fn count(&self) -> usize {
        self.job
            .with_untracked(|job| job.as_ref().and_then(|job| job.document.as_ref()).map_or(0, |d| d.segments.len()))
    }

    pub(super) fn words(&self, index: usize) -> Option<Vec<(SharedString, i64, i64)>> {
        self.job.with(|job| {
            let document = job.as_ref()?.document.as_ref()?;
            let segment = document.segments.get(index)?;
            let words: Vec<_> = document
                .tokens
                .iter()
                .filter(|token| {
                    token.end_ms > 0 && token.start_ms >= segment.start_ms && token.end_ms <= segment.end_ms
                })
                .filter(|token| token.translation_status.as_deref() != Some("translation"))
                .collect();
            let timed: Vec<(String, i64, i64)> = document
                .tokens
                .iter()
                .filter(|token| token.segment_id.as_deref() == Some(segment.id.as_str()))
                .map(|token| (token.text.clone(), token.start_ms, token.end_ms))
                .collect();
            if timed.len() > 1 {
                return listenook_core::local::spans(&segment.text, &timed)
                    .map(|spans| spans.into_iter().map(|(text, start, end)| (text.into(), start, end)).collect());
            }
            let joined: String = words.iter().map(|token| token.text.as_str()).collect();
            let pieces: Vec<(String, i64, i64)> =
                words.iter().map(|token| (token.text.clone(), token.start_ms, token.end_ms)).collect();
            (words.len() > 1 && joined.trim() == segment.text.trim()).then(|| {
                listenook_core::local::whole_words(&pieces)
                    .into_iter()
                    .map(|(text, start, end)| (text.into(), start, end))
                    .collect()
            })
        })
    }

    pub(super) fn blind(&self) -> bool {
        self.blind_listening() || (self.side.get() == Side::Practice && self.practice.get() == Practice::Dictation)
    }

    pub(super) fn blind_listening(&self) -> bool {
        self.store.setting(|s| s.blind_listening_enabled)
    }

    pub(super) fn target(&self) -> Option<usize> {
        match self.repeating.get() {
            Some(id) => self.index_of(&id),
            None => self.current.get(),
        }
    }

    pub(super) fn target_or_first(&self) -> Option<usize> {
        untracked(|| self.target()).or_else(|| (self.count() > 0).then_some(0))
    }

    pub(super) fn seek(&self, position_ms: i64) {
        let position_ms = position_ms.max(0);
        self.position_ms.set(position_ms);
        self.player.seek(position_ms as f64 / 1000.0);
    }

    pub(super) fn toggle_play(&self) {
        self.cancel_wait();
        self.stop_at.set(None);
        self.paused.set(!self.paused.get_untracked());
    }

    pub(super) fn play_from(&self, index: usize) {
        self.go_to(index, true);
    }

    pub(super) fn jump_to(&self, index: usize) {
        let playing = !self.paused.get_untracked() || self.waiting.get_untracked();
        self.go_to(index, playing);
    }

    fn go_to(&self, index: usize, play: bool) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        batch(|| {
            self.stop_at.set(None);
            if self.repeating.get_untracked().is_some() {
                self.repeating.set(Some(segment.id.clone()));
                self.reps.set(0);
            }
            self.revealed.set(None);
        });
        self.seek(self.play_start(index));
        self.paused.set(!play);
    }

    pub(super) fn step(&self, by: isize) {
        let from = untracked(|| self.target()).map_or(0, |index| index as isize);
        let next = (from + by).clamp(0, self.count().saturating_sub(1) as isize) as usize;
        self.play_from(next);
    }

    pub(super) fn toggle_repeat(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        if self.repeating.get_untracked().as_deref() == Some(segment.id.as_str()) {
            self.repeating.set(None);
            return;
        }
        batch(|| {
            self.repeating.set(Some(segment.id.clone()));
            self.reps.set(0);
            self.stop_at.set(None);
        });
        self.seek(self.play_start(index));
        self.paused.set(false);
    }

    pub(super) fn hold_repeat(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        batch(|| {
            self.repeating.set(Some(segment.id));
            self.reps.set(0);
            self.stop_at.set(None);
            self.paused.set(false);
        });
    }

    pub(super) fn end_hold(&self, before: Option<String>) {
        batch(|| {
            self.repeating.set(before);
            self.reps.set(0);
        });
    }

    pub(super) fn replay_once(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        self.stop_at.set(Some(segment.end_ms));
        self.seek(self.play_start(index));
        self.paused.set(false);
    }

    fn cancel_wait(&self) {
        if let Some(wait) = self.wait.replace(None) {
            wait.cancel();
        }
        self.waiting.set(false);
    }

    pub(super) fn on_progress(&self, position_ms: i64, duration_ms: i64) {
        if duration_ms > 0 {
            self.duration_ms.set(duration_ms);
        }
        if self.paused.get_untracked() {
            return;
        }
        self.position_ms.set(position_ms);
        if self.stop_at.get_untracked().is_some_and(|end| position_ms >= end) {
            batch(|| {
                self.stop_at.set(None);
                self.paused.set(true);
            });
            return;
        }
        let Some(index) = self.repeating.get_untracked().and_then(|id| self.index_of(&id)) else {
            return;
        };
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        if position_ms < segment.end_ms {
            return;
        }
        if self.practice.get_untracked() != Practice::Mimic {
            self.seek(self.play_start(index));
            return;
        }
        let goal = self.store.settings().mimic_rep_goal;
        let reps = (self.reps.get_untracked() + 1).min(goal);
        let pause_ms = dictation::mimic_pause_ms(
            segment.end_ms - segment.start_ms,
            f64::from(self.rate.get_untracked()),
            self.store.settings().mimic_pause_seconds,
        );
        batch(|| {
            self.reps.set(reps);
            self.paused.set(true);
            self.waiting.set(true);
        });
        let review = *self;
        let wait = spawn(async move {
            timer(Duration::from_millis(pause_ms as u64)).await;
            review.waiting.set(false);
            review.wait.replace(None);
            if reps < goal {
                review.seek(review.play_start(index));
                review.paused.set(false);
            } else if index + 1 < review.count() {
                review.play_from(index + 1);
            } else {
                review.repeating.set(None);
            }
        });
        self.wait.replace(Some(wait));
    }

    pub(super) fn edit(&self, index: usize, translation: bool) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        batch(|| {
            self.draft.set(if translation {
                segment.translated_text.clone().unwrap_or_default()
            } else {
                segment.text.clone()
            });
            self.editing.set(Some(Editing { segment_id: segment.id, translation }));
        });
    }

    fn change(&self, done: &'static str, edit: impl FnOnce(&mut Document) -> bool) -> bool {
        let id = self.id();
        let before = self.job.with_untracked(|job| job.as_ref().and_then(|job| job.document.clone()));
        let mut changed = false;
        self.store.update_document(&id, |document| changed = edit(document));
        if let (true, Some(before)) = (changed, before) {
            let generation = keep_for_undo(id, before);
            toast_with_action(Tone::Success, tr(done), tr("Undo"), move || {
                undo_change(Some(generation));
            });
        }
        changed
    }

    pub(super) fn undo(&self) -> bool {
        let undone = undo_change(None);
        if undone {
            self.editing.set(None);
        }
        undone
    }

    pub(super) fn save_edit(&self) {
        let Some(editing) = self.editing.get_untracked() else {
            return;
        };
        let text = self.draft.get_untracked().trim().to_owned();
        if text.is_empty() && !editing.translation {
            self.remove_editing(&editing.segment_id);
            return;
        }
        self.change("Sentence updated", |document| {
            let Some(segment) = document.segments.iter_mut().find(|s| s.id == editing.segment_id) else {
                return false;
            };
            let current =
                if editing.translation { segment.translated_text.clone() } else { Some(segment.text.clone()) };
            let wanted = (!text.is_empty()).then_some(text);
            if current == wanted {
                return false;
            }
            if editing.translation {
                segment.translated_text = wanted;
            } else {
                segment.text = wanted.unwrap_or_default();
            }
            true
        });
        self.editing.set(None);
    }

    pub(super) fn delete_editing(&self) {
        if let Some(editing) = self.editing.get_untracked() {
            self.remove_editing(&editing.segment_id);
        }
    }

    fn remove_editing(&self, segment_id: &str) {
        let Some(index) = self.index_of(segment_id) else {
            return;
        };
        self.change("Sentence deleted", |document| listenook_core::structure::remove(document, index));
        batch(|| {
            self.editing.set(None);
            if self.repeating.get_untracked().as_deref() == Some(segment_id) {
                self.repeating.set(None);
            }
            if self.revealed.get_untracked().as_deref() == Some(segment_id) {
                self.revealed.set(None);
            }
        });
    }

    pub(super) fn split_editing(&self) {
        let Some(editing) = self.editing.get_untracked().filter(|editing| !editing.translation) else {
            return;
        };
        let (text, caret) = (self.draft.get_untracked(), self.caret.get_untracked() as usize);
        let Some(index) = self.index_of(&editing.segment_id) else {
            return;
        };
        let split = self.change("Sentence split", |document| {
            let mut trial = document.clone();
            trial.segments[index].text = text.clone();
            let split = listenook_core::structure::split_at(&mut trial, index, caret);
            if split {
                *document = trial;
            }
            split
        });
        if split {
            self.editing.set(None);
        }
    }

    pub(super) fn merge_editing(&self) {
        let Some(index) = self.editing.get_untracked().and_then(|editing| self.index_of(&editing.segment_id)) else {
            return;
        };
        if self.change("Sentences merged", |document| listenook_core::structure::merge_with_next(document, index)) {
            self.editing.set(None);
        }
    }

    pub(super) fn can_merge_editing(&self) -> bool {
        self.editing
            .get()
            .and_then(|editing| self.index_of(&editing.segment_id))
            .is_some_and(|index| index + 1 < self.count())
    }

    pub(super) fn rename_speaker(&self, speaker_id: &str, name: &str) {
        let name = name.trim().to_owned();
        if name.is_empty() {
            return;
        }
        self.change("Speaker renamed", |document| {
            match document.speakers.iter_mut().find(|speaker| speaker.id == speaker_id) {
                Some(speaker) if speaker.name == name => return false,
                Some(speaker) => speaker.name = name,
                None => document.speakers.push(listenook_core::Speaker { id: speaker_id.to_owned(), name }),
            }
            true
        });
    }
}

struct Undoable {
    generation: u64,
    job_id: String,
    before: Document,
}

thread_local! {
    static LAST_CHANGE: std::cell::RefCell<(u64, Option<Undoable>)> = const { std::cell::RefCell::new((0, None)) };
}

fn keep_for_undo(job_id: String, before: Document) -> u64 {
    LAST_CHANGE.with_borrow_mut(|(count, last)| {
        *count += 1;
        *last = Some(Undoable { generation: *count, job_id, before });
        *count
    })
}

fn undo_change(generation: Option<u64>) -> bool {
    let taken = LAST_CHANGE.with_borrow_mut(|(_, last)| {
        let matches = last.as_ref().is_some_and(|last| generation.is_none_or(|wanted| wanted == last.generation));
        if matches { last.take() } else { None }
    });
    let Some(Undoable { job_id, before, .. }) = taken else {
        return false;
    };
    store().update_document(&job_id, |document| {
        document.segments = before.segments;
        document.tokens = before.tokens;
        document.speakers = before.speakers;
    });
    true
}
