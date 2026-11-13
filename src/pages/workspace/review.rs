//! The state of one open transcript: its player, what is shown, and the
//! practice modes. Made when a transcript opens and gone when it closes;
//! what must outlive that (the position, the settings) goes to the store.

use std::{rc::Rc, time::Duration};

use listenook_core::{ContentMode, Job, Segment, dictation};
use nsh_core::prelude::*;

use crate::state::{Store, store};

/// What the side panel shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Side {
    None,
    Practice,
    Brief,
    Video,
}

/// The practice mode running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Practice {
    None,
    Dictation,
    Mimic,
}

/// A text being edited: the sentence, and whether it is its translation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Editing {
    pub(super) segment_id: String,
    pub(super) translation: bool,
}

/// One open transcript. `Copy`, as the signals it is made of.
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
    /// Whether the recording has a picture.
    pub(super) has_video: bool,
    pub(super) side: Signal<Side>,
    /// Whether the picture is wanted beside the transcript: where closing
    /// Practice or the AI Brief goes back to.
    pub(super) video_wanted: Signal<bool>,
    pub(super) mode: Signal<ContentMode>,
    pub(super) searching: Signal<bool>,
    pub(super) query: Signal<String>,
    /// The sentence that loops, by id.
    pub(super) repeating: Signal<Option<String>>,
    /// The sentence shown in spite of blind listening, by id.
    pub(super) revealed: Signal<Option<String>>,
    pub(super) editing: Signal<Option<Editing>>,
    pub(super) draft: Signal<String>,
    /// Where the caret is in the text being edited, in characters.
    pub(super) caret: Signal<u32>,
    /// The recording's loudness over time, once computed.
    /// How wide the side panel is; the divider is dragged to change it.
    pub(super) side_width: Signal<f32>,
    /// The part of the AI Brief being edited.
    pub(super) brief_editing: Signal<Option<BriefPart>>,
    /// Whether the video is above the transcript rather than beside it,
    /// and how tall it is there.
    pub(super) video_on_top: Signal<bool>,
    pub(super) video_height: Signal<f32>,
    /// The video fills the window, with the sentence over it.
    pub(super) fullscreen: Signal<bool>,
    pub(super) practice: Signal<Practice>,
    /// How many times the looping sentence was played in mimic practice.
    pub(super) reps: Signal<u32>,
    /// Mimic practice is between two passes of the sentence.
    pub(super) waiting: Signal<bool>,
    /// Where a single replay stops.
    pub(super) stop_at: Signal<Option<i64>>,
    wait: Stored<Option<Spawned<()>>>,
    /// The current sentence's index among all sentences.
    pub(super) current: Memo<Option<usize>>,
    /// The sentences the list shows, as indices among all sentences.
    pub(super) shown: Memo<Vec<usize>>,
}

/// A part of an AI Brief that can be edited on its own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum BriefPart {
    Overview,
    Chapter(String),
    Insight(String),
    Note(String),
}

/// The side panel's width: as it starts, and how far it can be dragged.
pub(super) const SIDE_WIDTH: f32 = 400.0;
pub(super) const SIDE_MIN: f32 = 280.0;
pub(super) const SIDE_MAX: f32 = 760.0;
/// The video's height above the transcript: as it starts, and how far it
/// can be dragged.
pub(super) const VIDEO_HEIGHT: f32 = 320.0;
pub(super) const VIDEO_MIN: f32 = 160.0;
pub(super) const VIDEO_MAX: f32 = 720.0;

impl Review {
    /// The review of job `id`. Call in a body: its state belongs to that owner.
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
            shown,
        }
    }

    /// The job's id.
    pub(super) fn id(&self) -> String {
        self.id.with(|id| id.clone())
    }

    /// A sentence by its index, as it is now.
    pub(super) fn segment(&self, index: usize) -> Option<Segment> {
        self.job.with(|job| job.as_ref()?.document.as_ref()?.segments.get(index).cloned())
    }

    fn segment_now(&self, index: usize) -> Option<Segment> {
        self.job.with_untracked(|job| job.as_ref()?.document.as_ref()?.segments.get(index).cloned())
    }

    /// Where playing sentence `index` begins: a little before its marked
    /// start, so its first word is not cut off.
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

    /// The words of a sentence with their times, when the transcript has
    /// word timing and the sentence still reads as its words do.
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
            // Words timed on this machine name their sentence and leave out
            // what is not spoken (spaces, punctuation): give that back.
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
            // A service times pieces smaller than words: join them.
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

    /// Whether the text is hidden: blind listening is on, or the answer
    /// is being typed from hearing, which is blind listening by its nature.
    pub(super) fn blind(&self) -> bool {
        self.blind_listening() || (self.side.get() == Side::Practice && self.practice.get() == Practice::Dictation)
    }

    /// Whether the user turned blind listening on.
    pub(super) fn blind_listening(&self) -> bool {
        self.store.setting(|s| s.blind_listening_enabled)
    }

    /// The sentence practice works on: the looping one, else the current.
    pub(super) fn target(&self) -> Option<usize> {
        match self.repeating.get() {
            Some(id) => self.index_of(&id),
            None => self.current.get(),
        }
    }

    /// The sentence a command with no sentence named acts on: the one
    /// practice works on, else the first, since before the first sentence
    /// has begun (a recording just opened) none is current yet.
    pub(super) fn target_or_first(&self) -> Option<usize> {
        untracked(|| self.target()).or_else(|| (self.count() > 0).then_some(0))
    }

    // --- The player ----------------------------------------------------------

    /// Moves playback to a position.
    pub(super) fn seek(&self, position_ms: i64) {
        let position_ms = position_ms.max(0);
        self.position_ms.set(position_ms);
        self.player.seek(position_ms as f64 / 1000.0);
    }

    /// Plays or pauses. In mimic practice this starts or stops the loop.
    pub(super) fn toggle_play(&self) {
        self.cancel_wait();
        self.stop_at.set(None);
        self.paused.set(!self.paused.get_untracked());
    }

    /// Plays from the start of a sentence.
    pub(super) fn play_from(&self, index: usize) {
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
        self.paused.set(false);
    }

    /// Goes to the sentence before or after the current one.
    pub(super) fn step(&self, by: isize) {
        let from = untracked(|| self.target()).map_or(0, |index| index as isize);
        let next = (from + by).clamp(0, self.count().saturating_sub(1) as isize) as usize;
        self.play_from(next);
    }

    /// Loops a sentence, or stops looping it.
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

    /// Loops a sentence for as long as a key is held: playback goes on
    /// from where it is, and comes back to the sentence's start at its end.
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

    /// Ends [`Self::hold_repeat`]: back to the sentence that was looping
    /// before it, if one was, and playing on.
    pub(super) fn end_hold(&self, before: Option<String>) {
        batch(|| {
            self.repeating.set(before);
            self.reps.set(0);
        });
    }

    /// Plays a sentence once and pauses at its end.
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

    /// The player says where it is: keeps the position, and ends a pass of
    /// a looping sentence or a single replay.
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
        // Mimic: count the pass, leave the user time to say it, then play
        // it again, or the next sentence once the goal is met.
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

    // --- Editing -------------------------------------------------------------

    /// Starts editing a sentence's text or translation.
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

    /// Saves the edit. An empty original is not saved; an empty translation
    /// removes it.
    pub(super) fn save_edit(&self) {
        let Some(editing) = self.editing.get_untracked() else {
            return;
        };
        let text = self.draft.get_untracked().trim().to_owned();
        if text.is_empty() && !editing.translation {
            return;
        }
        self.store.update_document(&self.id(), |document| {
            if let Some(segment) = document.segments.iter_mut().find(|s| s.id == editing.segment_id) {
                if editing.translation {
                    segment.translated_text = (!text.is_empty()).then_some(text);
                } else {
                    segment.text = text;
                }
            }
        });
        self.editing.set(None);
    }

    /// Cuts the sentence being edited in two where the caret is, keeping
    /// what was typed.
    pub(super) fn split_editing(&self) {
        let Some(editing) = self.editing.get_untracked().filter(|editing| !editing.translation) else {
            return;
        };
        let (text, caret) = (self.draft.get_untracked(), self.caret.get_untracked() as usize);
        let Some(index) = self.index_of(&editing.segment_id) else {
            return;
        };
        let mut changed = false;
        self.store.update_document(&self.id(), |document| {
            document.segments[index].text = text.clone();
            changed = listenook_core::structure::split_at(document, index, caret);
        });
        if changed {
            self.editing.set(None);
        }
    }

    /// Joins the sentence being edited with the one after it.
    pub(super) fn merge_editing(&self) {
        let Some(index) = self.editing.get_untracked().and_then(|editing| self.index_of(&editing.segment_id)) else {
            return;
        };
        let mut changed = false;
        self.store.update_document(&self.id(), |document| {
            changed = listenook_core::structure::merge_with_next(document, index);
        });
        if changed {
            self.editing.set(None);
        }
    }

    /// Whether the sentence being edited has one after it to join.
    pub(super) fn can_merge_editing(&self) -> bool {
        self.editing
            .get()
            .and_then(|editing| self.index_of(&editing.segment_id))
            .is_some_and(|index| index + 1 < self.count())
    }

    /// Renames a speaker everywhere in the transcript.
    pub(super) fn rename_speaker(&self, speaker_id: &str, name: &str) {
        let name = name.trim().to_owned();
        if name.is_empty() {
            return;
        }
        self.store.update_document(&self.id(), |document| {
            match document.speakers.iter_mut().find(|speaker| speaker.id == speaker_id) {
                Some(speaker) => speaker.name = name,
                None => document.speakers.push(listenook_core::Speaker { id: speaker_id.to_owned(), name }),
            }
        });
    }
}
