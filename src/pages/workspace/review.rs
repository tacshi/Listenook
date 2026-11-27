use std::{
    rc::Rc,
    time::{Duration, Instant},
};

use crate::pages::media::{MediaRef, media_ref};
use listenook_core::activity::Kind;
use listenook_core::transcript::structure::{self, Edit};
use listenook_core::{
    ContentMode, Document, Job, Segment, playback, playback::Loudness, transcript::dictation, transcript::highlights,
};
use nsh_core::prelude::*;

use crate::ui::{error_text, tr};
use crate::work::ai;
use crate::{
    state::{SettingsTab, Store, store},
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
    pub(super) original: bool,
    pub(super) translation: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Span {
    pub(super) first: String,
    pub(super) last: String,
}

impl Span {
    fn one(id: String) -> Span {
        Span { first: id.clone(), last: id }
    }
}

/// What happens when playback reaches the end of what is playing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Edge {
    /// A sentence played once: stop, back at its start when it is known.
    Stop(Option<usize>),
    /// A repeat: back to its first sentence.
    Loop(usize),
    /// A Mimic pass over this sentence: pause for the learner to say it.
    Mimic(usize),
    /// Skipped sentences come next: on to this one past them.
    Skip(usize),
}

#[derive(Debug, Clone, Copy)]
struct SentCut {
    at: Instant,
    from_ms: i64,
    waited_ms: f64,
    rate: f32,
}

/// The longest a seek stays silent when no tick shows it landed (a platform
/// that does not tick while paused).
const HUSH_AT_MOST: Duration = Duration::from_millis(400);

#[derive(Default)]
struct Drag {
    zones: Vec<(usize, f32, f32)>,
    finger: Option<f32>,
    viewport: Option<(f32, f32)>,
}

#[derive(Default)]
struct ListScroll {
    offset: f32,
    content: f32,
    viewport: f32,
    /// Where the list was when a finger, the trackpad or the scroll bar
    /// took hold of it, until it lets go.
    held_at: Option<f32>,
}

/// How far a held list moves before it counts as scrolled by hand (a
/// trackpad's resting fingers hold it without moving it).
const HAND_SCROLL: f32 = 4.0;

fn chain(found: &std::collections::BTreeMap<usize, (f32, f32)>, anchor: usize) -> Vec<(usize, f32, f32)> {
    const SLACK: f32 = 2.0;
    let Some(&(top, bottom)) = found.get(&anchor) else {
        return Vec::new();
    };
    let mut zones = std::collections::VecDeque::from([(anchor, top, bottom)]);
    let mut index = anchor;
    while let Some(&(top, bottom)) = found.get(&(index + 1)) {
        if (top - zones.back().map_or(top, |z| z.2)).abs() > SLACK {
            break;
        }
        index += 1;
        zones.push_back((index, top, bottom));
    }
    let mut index = anchor;
    while let Some(&(top, bottom)) = index.checked_sub(1).and_then(|above| found.get(&above)) {
        if (bottom - zones.front().map_or(bottom, |z| z.1)).abs() > SLACK {
            break;
        }
        index -= 1;
        zones.push_front((index, top, bottom));
    }
    zones.into()
}

#[derive(Clone, Copy)]
struct Row {
    token: u64,
    index: Memo<Option<usize>>,
    view: ElementRef,
}

#[derive(Debug, Clone, PartialEq)]
pub(super) struct Picked {
    pub(super) segment_id: String,
    pub(super) range: std::ops::Range<u32>,
    pub(super) text: String,
}

#[derive(Clone, Copy)]
pub(super) struct Review {
    pub(super) store: Store,
    id: Stored<String>,
    pub(super) job: Memo<Option<Rc<Job>>>,
    /// How loud the recording is, once measured: where its pauses are.
    loudness: Signal<Option<Rc<Loudness>>>,
    pub(super) player: MediaRef,
    pub(super) list: ElementRef,
    pub(super) position_ms: Signal<i64>,
    pub(super) duration_ms: Signal<i64>,
    pub(super) paused: Signal<bool>,
    pub(super) rate: Signal<f32>,
    pub(super) has_video: bool,
    pub(super) side: Signal<Side>,
    pub(super) mode: Signal<ContentMode>,
    pub(super) searching: Signal<bool>,
    pub(super) query: Signal<String>,
    pub(super) repeating: Signal<Option<Span>>,
    /// The first sentence of a stretch to skip, while its last is picked.
    pub(super) skip_from: Signal<Option<String>>,
    /// The sentence a drag on a repeat button started from, while the
    /// finger picks the other end of the repeat.
    pub(super) drag_anchor: Signal<Option<String>>,
    rows: Stored<Vec<Row>>,
    row_count: Stored<u64>,
    drag: Stored<Drag>,
    drag_task: Stored<Option<Spawned<()>>>,
    scroll: Stored<ListScroll>,
    /// The list keeps the sentence playing in view: until the user scrolls
    /// it by hand, and again once they pick a sentence, step, seek, press
    /// play or Jump to playing.
    pub(super) following: Signal<bool>,
    pub(super) looping: Signal<bool>,
    pub(super) revealed: Signal<Option<String>>,
    /// The sentences typed right in Type answer: shown from then on, blind
    /// or not.
    pub(super) answered: Signal<std::collections::BTreeSet<String>>,
    pub(super) editing: Signal<Option<Editing>>,
    pub(super) draft: Signal<String>,
    pub(super) translation_draft: Signal<String>,
    /// The sentences translated again on their own, waiting for the reply:
    /// one entry a request, so a second edit keeps it waiting.
    pub(super) retranslating: Signal<Vec<String>>,
    pub(super) caret: Signal<u32>,
    pub(super) side_width: Signal<f32>,
    pub(super) brief_editing: Signal<Option<BriefPart>>,
    pub(super) brief_items: Stored<Vec<(String, ElementRef)>>,
    pub(super) selection: Signal<Option<Picked>>,
    pub(super) video_on_top: Signal<bool>,
    pub(super) video_height: Signal<f32>,
    pub(super) fullscreen: Signal<bool>,
    pub(super) practice: Signal<Practice>,
    pub(super) reps: Signal<u32>,
    pub(super) waiting: Signal<bool>,
    pub(super) stop_at: Signal<Option<i64>>,
    /// Counts the times a sentence played on its own ends (Type answer
    /// plays it again after).
    pub(super) ended: Signal<u64>,
    wait: Stored<Option<Spawned<()>>>,
    /// The player is muted while a seek is in flight.
    pub(super) hushed: Signal<bool>,
    /// A sentence was cut off with a pause: the player plays on, muted,
    /// until the seek back lands, and pauses then.
    pub(super) holding: Signal<bool>,
    /// The seek in flight: from where, to where.
    landing: Stored<Option<(i64, i64)>>,
    unhush: Stored<Option<Spawned<()>>>,
    edge_timer: Stored<Option<Spawned<()>>>,
    /// The latest tick that played on: when it came, and where.
    last_tick: Stored<Option<(Instant, i64)>>,
    /// How long a cut takes to reach the player, as measured.
    lag_ms: Stored<f64>,
    /// The cut just sent, to measure that from: when, from which tick, how
    /// long after it, at what speed.
    sent_cut: Stored<Option<SentCut>>,
    pub(super) current: Memo<Option<usize>>,
    /// The sentence being said, as [`Document::segment_heard_at`] has it.
    heard: Memo<Option<usize>>,
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

/// What the reader's views do with it: they read what it shows and ask it to change, and it
/// keeps how it holds each part to itself.
impl Review {
    /// Reads the recording under review, followed reactively.
    pub(super) fn job_with<T>(&self, read: impl FnOnce(&Option<Rc<Job>>) -> T) -> T {
        self.job.with(read)
    }

    /// Reads the recording under review as it is now.
    pub(super) fn job_now_with<T>(&self, read: impl FnOnce(&Option<Rc<Job>>) -> T) -> T {
        self.job.with_untracked(read)
    }

    /// How many sentences the list shows.
    pub(super) fn shown_count(&self) -> usize {
        self.shown.with(Vec::len)
    }

    /// The sentence the list shows in row `row`.
    pub(super) fn shown_at(&self, row: usize) -> Option<usize> {
        self.shown.with(|shown| shown.get(row).copied())
    }

    /// The row the list shows the sentence `index` in, if it shows it.
    pub(super) fn row_of(&self, index: usize) -> Option<usize> {
        self.shown.with(|shown| shown.iter().position(|shown| *shown == index))
    }

    /// The IDs of the sentences the list shows, in order.
    pub(super) fn shown_ids(&self) -> Vec<String> {
        self.shown.with(|shown| shown.iter().filter_map(|index| self.segment(*index).map(|s| s.id)).collect())
    }

    /// The list of sentences, for its view to bind.
    pub(super) fn list(&self) -> ElementRef {
        self.list
    }

    /// The player, for its view to bind.
    pub(super) fn player(&self) -> MediaRef {
        self.player
    }

    /// Brings the row `row` of the list into view, a third of the way down.
    pub(super) fn scroll_to_row(&self, row: usize, animated: bool) {
        self.list.scroll_to_index(row as u32, percentage(0.35), px(0.0), animated);
    }

    /// The player's media is loaded and lasts `duration_ms`: it starts where it was left,
    /// playing on when `plays` says so.
    pub(super) fn loaded(&self, duration_ms: i64, plays: bool) {
        self.duration_ms.set(duration_ms);
        let start_at = self.position_ms.get_untracked();
        if start_at > 0 {
            self.player.seek(start_at as f64 / 1000.0);
        }
        if plays {
            self.paused.set(false);
        }
    }

    pub(super) fn is_fullscreen(&self) -> bool {
        self.fullscreen.get()
    }

    pub(super) fn is_paused(&self) -> bool {
        self.paused.get()
    }

    pub(super) fn is_searching(&self) -> bool {
        self.searching.get()
    }

    /// The search's words, trimmed; none while the search is closed.
    pub(super) fn search_text(&self) -> String {
        if self.searching.get() { self.query.with(|q| q.trim().to_owned()) } else { String::new() }
    }

    pub(super) fn is_editing(&self) -> bool {
        self.editing.with(Option::is_some)
    }

    pub(super) fn is_looping(&self) -> bool {
        self.looping.get()
    }

    pub(super) fn toggle_looping(&self) {
        self.looping.update(|looping| *looping = !*looping);
    }

    pub(super) fn is_following(&self) -> bool {
        self.following.get()
    }

    pub(super) fn side(&self) -> Side {
        self.side.get()
    }

    pub(super) fn practice(&self) -> Practice {
        self.practice.get()
    }

    pub(super) fn mode(&self) -> ContentMode {
        self.mode.get()
    }

    pub(super) fn rate(&self) -> f32 {
        self.rate.get()
    }

    pub(super) fn position_ms(&self) -> i64 {
        self.position_ms.get()
    }

    pub(super) fn duration_ms(&self) -> i64 {
        self.duration_ms.get()
    }

    /// The stretch of sentences repeating, if any.
    pub(super) fn repeating(&self) -> Option<Span> {
        self.repeating.get()
    }

    /// The sentence playing, by index.
    pub(super) fn current(&self) -> Option<usize> {
        self.current.get()
    }

    /// The sentence the playhead is dragged to, while it is.
    pub(super) fn scrubbed(&self) -> Option<usize> {
        self.scrubbed.get()
    }

    pub(super) fn is_scrubbing(&self) -> bool {
        self.scrub.with(Option::is_some)
    }

    /// The editor's text, trimmed.
    pub(super) fn draft_text(&self) -> String {
        self.draft.with(|draft| draft.trim().to_owned())
    }

    /// The editor's translation as it is.
    pub(super) fn translation_draft_text(&self) -> String {
        self.translation_draft.get()
    }

    /// Puts `line` in the editor's translation, unless it was changed from `before` meanwhile.
    pub(super) fn offer_translation(&self, line: String, before: &str) {
        if self.translation_draft.with_untracked(|draft| draft == before) {
            self.translation_draft.set(line);
        }
    }

    /// The part of the brief being edited.
    pub(super) fn brief_part(&self) -> Option<BriefPart> {
        self.brief_editing.get()
    }

    pub(super) fn set_paused(&self, paused: bool) {
        self.paused.set(paused);
    }

    pub(super) fn set_rate(&self, rate: f32) {
        self.rate.set(rate);
    }

    /// The speed it plays at, unless the reader is gone.
    pub(super) fn try_rate(&self) -> Option<f32> {
        self.rate.try_get()
    }

    /// Plays at `rate`, unless the reader is gone.
    pub(super) fn try_set_rate(&self, rate: f32) {
        self.rate.try_set(rate);
    }

    pub(super) fn set_side(&self, side: Side) {
        self.side.set(side);
    }

    pub(super) fn set_mode(&self, mode: ContentMode) {
        self.mode.set(mode);
    }

    pub(super) fn set_practice(&self, practice: Practice) {
        self.practice.set(practice);
    }

    pub(super) fn set_searching(&self, searching: bool) {
        self.searching.set(searching);
    }

    /// The search field's text, for the field to bind.
    pub(super) fn query(&self) -> Signal<String> {
        self.query
    }

    pub(super) fn stop_repeating(&self) {
        self.repeating.set(None);
    }

    pub(super) fn is_repeating_any(&self) -> bool {
        self.repeating.with(Option::is_some)
    }

    /// Whether the first sentence of a stretch to skip is picked.
    pub(super) fn is_picking_skip(&self) -> bool {
        self.skip_from.with(Option::is_some)
    }

    pub(super) fn stop_picking_skip(&self) {
        self.skip_from.set(None);
    }

    /// Shows the sentence `current` hidden in blind listening, or hides the one shown.
    pub(super) fn toggle_revealed(&self, current: Option<String>) {
        self.revealed.update(|revealed| *revealed = if revealed.is_some() { None } else { current });
    }

    pub(super) fn hide_revealed(&self) {
        self.revealed.set(None);
    }

    /// Whether words of a sentence are selected.
    pub(super) fn has_selection(&self) -> bool {
        self.selection.with(Option::is_some)
    }

    pub(super) fn has_selection_now(&self) -> bool {
        self.selection.with_untracked(Option::is_some)
    }

    /// Reads what the editor edits, if it is open.
    pub(super) fn editing_with<T>(&self, read: impl FnOnce(Option<&Editing>) -> T) -> T {
        self.editing.with(|editing| read(editing.as_ref()))
    }

    pub(super) fn close_editor(&self) {
        self.editing.set(None);
    }

    /// The editor's text, for the field to bind.
    pub(super) fn draft(&self) -> Signal<String> {
        self.draft
    }

    /// The editor's translation, for the field to bind.
    pub(super) fn translation_draft(&self) -> Signal<String> {
        self.translation_draft
    }

    /// Where the caret is in the editor's text.
    pub(super) fn set_caret(&self, at: u32) {
        self.caret.set(at);
    }

    /// Whether the sentence `id` waits for its translation.
    pub(super) fn is_retranslating(&self, id: &str) -> bool {
        self.retranslating.with(|waiting| waiting.iter().any(|waiting| waiting == id))
    }

    /// Where the person drags the playhead to, while they drag it.
    pub(super) fn scrub_to(&self, at: Option<i64>) {
        self.scrub.set(at);
    }

    /// Shows the reader full screen, or not.
    pub(super) fn set_fullscreen(&self, on: bool) {
        self.fullscreen.set(on);
        self.store.act(crate::state::Action::SetImmersive(on));
    }

    pub(super) fn set_video_on_top(&self, on_top: bool) {
        self.video_on_top.set(on_top);
    }

    /// Counts the sentence `id` as typed right in Type answer.
    pub(super) fn answered(&self, id: String) {
        self.answered.update(|answered| {
            answered.insert(id);
        });
    }

    /// Keeps the repetitions counted at most `goal`.
    pub(super) fn cap_reps(&self, goal: u32) {
        self.reps.update(|reps| *reps = (*reps).min(goal));
    }

    /// Edits `part` of the brief, or closes its editor.
    pub(super) fn edit_brief_part(&self, part: Option<BriefPart>) {
        self.brief_editing.set(part);
    }

    /// The items of the brief that show, by key, with their views.
    pub(super) fn brief_items(&self) -> Vec<(String, ElementRef)> {
        self.brief_items.with(|items| items.clone())
    }

    pub(super) fn add_brief_item(&self, key: String, view: ElementRef) {
        self.brief_items.with(|items| items.push((key, view)));
    }

    pub(super) fn clear_brief_items(&self) {
        self.brief_items.with(Vec::clear);
    }
}

impl Review {
    pub(super) fn new(id: &str) -> Review {
        let store = store();
        let owned = id.to_owned();
        let job = computed(move || store.job(&owned));
        let position_ms = signal(store.playback_position(id).unwrap_or(0));
        let has_translation = job.with_untracked(|job| {
            job.as_ref().and_then(|job| job.document()).is_some_and(|d| d.segments.iter().any(Segment::has_translation))
        });
        let has_video = job.with_untracked(|job| {
            job.as_ref().is_some_and(|job| {
                job.has_video()
                    || matches!(
                        listenook_core::media::subtitles::extension(&job.source_path).as_str(),
                        "mp4" | "mkv" | "avi" | "webm"
                    )
            })
        });
        let video_wanted = has_video
            && store
                .setting(|s| s.extra.get("reader_video_wanted").and_then(serde_json::Value::as_bool))
                .unwrap_or(true);
        // The language the reader was last shown in, for a transcript that has a translation.
        let remembered_mode = store
            .setting(|s| s.extra.get("reader_content_mode").and_then(serde_json::Value::as_str).map(ContentMode::parse))
            .unwrap_or(ContentMode::Bilingual);
        // The Brief is made from the transcript: with none yet, it stays shut.
        let brief_open = job.with_untracked(|job| job.as_ref().is_some_and(|job| job.has_transcript()))
            && store
                .setting(|s| s.extra.get("reader_brief_open").and_then(serde_json::Value::as_bool))
                .unwrap_or(false);
        let query = signal(String::new());
        let searching = signal(false);
        let loudness = signal(None::<Rc<Loudness>>);
        let segment_at = move |position: i64| {
            loudness
                .with(|loudness| job.with(|job| job.as_ref()?.document()?.segment_at(position, loudness.as_deref())))
        };
        let current = computed(move || segment_at(position_ms.get()));
        let heard = computed(move || {
            let position = position_ms.get();
            loudness.with(|loudness| {
                job.with(|job| job.as_ref()?.document()?.segment_heard_at(position, loudness.as_deref()))
            })
        });
        let scrub = signal(None::<i64>);
        let scrubbed = computed(move || segment_at(scrub.get()?));
        // The pauses between sentences, from the recording itself, measured
        // once for each recording the job points at.
        let source = computed(move || job.with(|job| job.as_ref().map(|job| job.source_path.clone())));
        let job_id = id.to_owned();
        effect(move || {
            let Some(source) = source.get() else {
                return;
            };
            let job_id = job_id.clone();
            spawn(async move {
                let measured = blocking(move || crate::services::audio::loudness(&job_id, &source)).await;
                loudness.try_set(measured.ok().flatten().map(Rc::new));
            });
        });
        let shown = computed(move || {
            let needle = if searching.get() { query.with(|q| q.trim().to_lowercase()) } else { String::new() };
            job.with(|job| {
                let Some(document) = job.as_ref().and_then(|job| job.document()) else {
                    return Vec::new();
                };
                document
                    .segments
                    .iter()
                    .enumerate()
                    .filter(|(index, segment)| {
                        if segment.skipped {
                            // One row for each skipped run, and none while searching.
                            return needle.is_empty()
                                && index.checked_sub(1).is_none_or(|before| !document.segments[before].skipped);
                        }
                        needle.is_empty()
                            || segment.text.to_lowercase().contains(&needle)
                            || segment.translated_text.as_ref().is_some_and(|t| t.to_lowercase().contains(&needle))
                            || document.speaker_name(segment.speaker.as_deref()).to_lowercase().contains(&needle)
                    })
                    .map(|(index, _)| index)
                    .collect()
            })
        });
        let review = Review {
            store,
            id: stored(id.to_owned()),
            job,
            loudness,
            player: media_ref(),
            list: element_ref(),
            position_ms,
            duration_ms: signal(0),
            paused: signal(true),
            rate: signal(store.saved_rate("playback_rate")),
            has_video,
            side: signal(if brief_open {
                Side::Brief
            } else if video_wanted {
                Side::Video
            } else {
                Side::None
            }),
            mode: signal(if has_translation { remembered_mode } else { ContentMode::Original }),
            searching,
            query,
            repeating: signal(None),
            skip_from: signal(None),
            drag_anchor: signal(None),
            rows: stored(Vec::new()),
            row_count: stored(0),
            drag: stored(Drag::default()),
            drag_task: stored(None),
            scroll: stored(ListScroll::default()),
            following: signal(true),
            looping: signal(false),
            revealed: signal(None),
            answered: signal(std::collections::BTreeSet::new()),
            editing: signal(None),
            draft: signal(String::new()),
            translation_draft: signal(String::new()),
            retranslating: signal(Vec::new()),
            caret: signal(0),
            brief_editing: signal(None),
            brief_items: stored(Vec::new()),
            selection: signal(None),
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
            ended: signal(0),
            wait: stored(None),
            hushed: signal(false),
            holding: signal(false),
            landing: stored(None),
            unhush: stored(None),
            edge_timer: stored(None),
            last_tick: stored(None),
            lag_ms: stored(playback::DEFAULT_LAG_MS),
            sent_cut: stored(None),
            current,
            heard,
            scrub,
            scrubbed,
            shown,
        };
        // A player kept muted through a pause sounds again once it plays,
        // unless a seek it waits for is still in flight.
        effect(move || {
            let playing = !review.paused.get();
            untracked(|| {
                if playing && review.landing.with(|landing| landing.is_none()) && review.hushed.get() {
                    review.hushed.set(false);
                }
            });
        });
        review
    }

    pub(super) fn id(&self) -> String {
        self.id.with(|id| id.clone())
    }

    pub(super) fn segment(&self, index: usize) -> Option<Segment> {
        self.job.with(|job| job.as_ref()?.document()?.segments.get(index).cloned())
    }

    fn segment_now(&self, index: usize) -> Option<Segment> {
        self.job.with_untracked(|job| job.as_ref()?.document()?.segments.get(index).cloned())
    }

    fn play_start(&self, index: usize) -> i64 {
        self.job.with_untracked(|job| {
            let loudness = self.loudness.with_untracked(Option::clone);
            job.as_ref().and_then(|job| job.document()?.play_start(index, loudness.as_deref())).unwrap_or_default()
        })
    }

    fn play_end(&self, index: usize) -> Option<i64> {
        let loudness = self.loudness.with_untracked(Option::clone);
        self.job.with_untracked(|job| job.as_ref()?.document()?.play_end(index, loudness.as_deref()))
    }

    fn index_of(&self, segment_id: &str) -> Option<usize> {
        self.job.with_untracked(|job| {
            job.as_ref()?.document()?.segments.iter().position(|segment| segment.id == segment_id)
        })
    }

    fn count(&self) -> usize {
        self.job.with_untracked(|job| job.as_ref().and_then(|job| job.document()).map_or(0, |d| d.segments.len()))
    }

    fn document_now<T>(&self, f: impl FnOnce(&Document) -> Option<T>) -> Option<T> {
        self.job.with_untracked(|job| {
            let document = job.as_ref()?.document()?;
            f(&document)
        })
    }

    /// The next sentence to review after `after` (from the start with none),
    /// round from the start, never `after` itself.
    pub(super) fn next_to_review(&self, after: Option<usize>) -> Option<usize> {
        let from = after.map_or(0, |index| index + 1);
        self.document_now(|document| document.next_to_review(from)).filter(|&at| Some(at) != after)
    }

    /// How many sentences are left to review in Type answer.
    pub(super) fn left_to_review(&self) -> usize {
        self.job.with(|job| job.as_ref().and_then(|job| job.document()).map_or(0, |d| d.left_to_review()))
    }

    /// Marks sentence `id` to review, or done with, saving only a change.
    pub(super) fn set_to_review(&self, id: &str, due: bool) {
        let now = self.document_now(|document| document.segments.iter().find(|s| s.id == id).map(|s| s.to_review));
        if now.is_none_or(|now| now == due) {
            return;
        }
        self.store.update_document(&self.id(), |document| {
            if let Some(segment) = document.segments.iter_mut().find(|s| s.id == id) {
                segment.to_review = due;
            }
        });
    }

    /// The first sentence at or after `index` that is not skipped.
    pub(super) fn next_kept(&self, index: usize) -> Option<usize> {
        self.document_now(|document| document.next_kept(index))
    }

    /// `index`, or when it is skipped, the nearest sentence that is not,
    /// looking `forward` first.
    fn kept_near(&self, index: usize, forward: bool) -> Option<usize> {
        self.document_now(|document| {
            if forward {
                document.next_kept(index).or_else(|| document.prev_kept(index))
            } else {
                document.prev_kept(index).or_else(|| document.next_kept(index))
            }
        })
    }

    fn is_skipped(&self, index: usize) -> bool {
        self.document_now(|document| Some(document.segments.get(index)?.skipped)).unwrap_or(false)
    }

    /// The skipped run sentence `index` is in, first and last.
    pub(super) fn skipped_run(&self, index: usize) -> Option<(usize, usize)> {
        self.job.with(|job| job.as_ref()?.document()?.skipped_run(index))
    }

    /// Marks sentences `first` through `last` skipped, or brings them back.
    pub(super) fn set_skipped(&self, first: usize, last: usize, skipped: bool) {
        let done = if skipped { "Skipped" } else { "Brought back" };
        let changed =
            self.change(done, |document| listenook_core::ai::ads::set_skipped(document, &[(first, last)], skipped));
        if changed && skipped {
            batch(|| {
                if untracked(|| self.repeat_range()).is_some_and(|(a, b)| first <= a && b <= last) {
                    self.repeating.set(None);
                }
                if self.editing.get_untracked().is_some() {
                    self.editing.set(None);
                }
            });
        }
    }

    /// Starts a stretch to skip at sentence `index`: the next sentence
    /// tapped ends it.
    pub(super) fn begin_skip(&self, index: usize) {
        if let Some(segment) = self.segment_now(index) {
            batch(|| {
                self.editing.set(None);
                self.skip_from.set(Some(segment.id));
            });
        }
    }

    /// Where the stretch being picked starts.
    pub(super) fn skip_start(&self) -> Option<usize> {
        let id = self.skip_from.get()?;
        self.job.with(|job| job.as_ref()?.document()?.segments.iter().position(|segment| segment.id == id))
    }

    /// Skips from where the stretch started through sentence `index`,
    /// whichever comes first. Whether a stretch was being picked.
    pub(super) fn finish_skip(&self, index: usize) -> bool {
        let Some(start) = untracked(|| self.skip_start()) else {
            return false;
        };
        self.skip_from.set(None);
        self.set_skipped(start.min(index), start.max(index), true);
        true
    }

    pub(super) fn skip_editing_onward(&self) {
        if let Some(index) = self.editing.get_untracked().and_then(|editing| self.index_of(&editing.segment_id)) {
            self.begin_skip(index);
        }
    }

    /// Skips what the AI took for ads, and forgets the findings.
    pub(super) fn skip_found(&self) {
        let found = self.job.with_untracked(|job| job.as_ref().map(|job| job.ad_scan.found.clone()));
        let Some(found) = found.filter(|found| !found.is_empty()) else {
            return;
        };
        self.change("Ads skipped", |document| listenook_core::ai::ads::skip_found(document, &found));
        self.forget_found();
    }

    pub(super) fn forget_found(&self) {
        self.store.update_job(&self.id(), |job| job.apply(listenook_core::Change::ForgetAds));
    }

    pub(super) fn words(&self, index: usize) -> Option<Vec<(SharedString, i64, i64)>> {
        self.job.with(|job| {
            let document = job.as_ref()?.document()?;
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
            let shared = |spans: Vec<(String, i64, i64)>| {
                spans.into_iter().map(|(text, start, end)| (text.into(), start, end)).collect()
            };
            if timed.len() > 1 {
                return listenook_core::transcript::local::spans(&segment.text, &timed)
                    .or_else(|| listenook_core::transcript::local::retimed(&segment.text, &timed))
                    .map(shared);
            }
            if words.len() < 2 {
                return None;
            }
            let joined: String = words.iter().map(|token| token.text.as_str()).collect();
            let pieces: Vec<(String, i64, i64)> =
                words.iter().map(|token| (token.text.clone(), token.start_ms, token.end_ms)).collect();
            if joined.trim() == segment.text.trim() {
                Some(shared(listenook_core::transcript::local::whole_words(&pieces)))
            } else {
                listenook_core::transcript::local::retimed(&segment.text, &pieces).map(shared)
            }
        })
    }

    pub(super) fn blind(&self) -> bool {
        self.blind_listening() || (self.side.get() == Side::Practice && self.practice.get() == Practice::Dictation)
    }

    /// Practice is open, docked across the bottom of the reader under the
    /// transcript (the other panels take the side column).
    pub(super) fn docked(&self) -> bool {
        self.side.get() == Side::Practice && !self.fullscreen.get()
    }

    /// Whether sentence `id` shows while listening blind: revealed for now,
    /// or answered right in Type answer.
    pub(super) fn unveiled(&self, id: &str) -> bool {
        self.revealed.with(|revealed| revealed.as_deref() == Some(id))
            || self.answered.with(|answered| answered.contains(id))
    }

    pub(super) fn blind_listening(&self) -> bool {
        self.store.setting(|s| s.blind_listening_enabled)
    }

    pub(super) fn repeat_range(&self) -> Option<(usize, usize)> {
        let span = self.repeating.get()?;
        self.job.with(|job| {
            let segments = &job.as_ref()?.document()?.segments;
            let first = segments.iter().position(|segment| segment.id == span.first)?;
            let last = segments.iter().position(|segment| segment.id == span.last)?;
            Some((first.min(last), first.max(last)))
        })
    }

    pub(super) fn repeats(&self, index: usize) -> bool {
        self.repeat_range().is_some_and(|(first, last)| (first..=last).contains(&index))
    }

    pub(super) fn target(&self) -> Option<usize> {
        let target = match self.repeat_range() {
            Some((first, last)) => {
                Some(self.current.get().filter(|current| (first..=last).contains(current)).unwrap_or(first))
            }
            None => self.current.get(),
        }?;
        self.job.with(|job| {
            let document = job.as_ref()?.document()?;
            document.next_kept(target).or_else(|| document.prev_kept(target))
        })
    }

    /// The sentence shown as being said, in the transcript and over the
    /// video: [`Self::target`], but none once the sentence playing has been
    /// said and a long pause follows it.
    pub(super) fn spoken(&self) -> Option<usize> {
        let target = self.target()?;
        let done = self.current.get() == Some(target) && self.heard.get().is_none();
        (!done).then_some(target)
    }

    pub(super) fn target_or_first(&self) -> Option<usize> {
        untracked(|| self.target()).or_else(|| (self.count() > 0).then_some(0))
    }

    pub(super) fn seek(&self, position_ms: i64) {
        self.follow();
        self.jump(position_ms, false);
    }

    /// Whether the player reports where it is every 50 ms rather than every
    /// 500 ms: in the foreground, or while the end of a sentence is watched
    /// (Type answer stops at each one).
    pub(super) fn ticks_often(&self) -> bool {
        lifecycle() != nsh_core::element::Lifecycle::Background
            || self.repeating.with(Option::is_some)
            || self.stop_at.with(Option::is_some)
            || self.practice.with(|practice| *practice == Practice::Dictation)
    }

    /// Moves playback to `position_ms`. Until a seek lands the player goes on
    /// sounding from where it was (some 30 ms on AVPlayer, more on slow
    /// media): past a sentence's end, that is the next sentence's head. So a
    /// `quiet` jump, one that plays on from a sentence's start, keeps the
    /// player muted until a tick shows the new place.
    fn jump(&self, position_ms: i64, quiet: bool) {
        let position_ms = position_ms.max(0);
        self.disarm();
        if quiet && untracked(|| self.ticks_often()) {
            // A seek on top of one still in flight: the player is still where
            // the first one left from.
            let from = self.landing.with(|landing| landing.map(|(from, _)| from));
            let from = from.unwrap_or_else(|| self.position_ms.get_untracked());
            self.landing.with(|landing| *landing = Some((from, position_ms)));
            self.hushed.set(true);
            let review = *self;
            let fallback = spawn(async move {
                timer(HUSH_AT_MOST).await;
                review.unhush.replace(None);
                review.settle();
            });
            if let Some(earlier) = self.unhush.replace(Some(fallback)) {
                earlier.cancel();
            }
        } else {
            self.settle();
        }
        self.position_ms.set(position_ms);
        self.player.seek(position_ms as f64 / 1000.0);
    }

    /// The seek in flight landed (or is no longer waited for): sound again,
    /// once it plays. A sentence cut off with a pause stays muted until then:
    /// AVPlayer can play on for over half a second after a pause that comes
    /// with a seek, past the time a seek alone takes.
    fn settle(&self) {
        if let Some(fallback) = self.unhush.replace(None) {
            fallback.cancel();
        }
        self.landing.with(|landing| *landing = None);
        if self.holding.get_untracked() {
            self.holding.set(false);
        }
        if self.hushed.get_untracked() && !self.paused.get_untracked() {
            self.hushed.set(false);
        }
    }

    pub(super) fn toggle_play(&self) {
        if self.practice.get_untracked() == Practice::Dictation {
            // Type answer plays one sentence at a time: from its start, or
            // not at all while it waits to play again.
            let waited = self.waiting.get_untracked();
            self.cancel_wait();
            let target = untracked(|| self.target());
            match (self.paused.get_untracked(), target) {
                (true, Some(index)) if !waited => self.replay_once(index),
                _ => batch(|| {
                    self.stop_at.set(None);
                    self.paused.set(true);
                }),
            }
            return;
        }
        self.cancel_wait();
        self.stop_at.set(None);
        if self.paused.get_untracked() {
            self.follow();
        }
        self.paused.set(!self.paused.get_untracked());
    }

    /// Stops playing, and any wait to play again: the sleep timer is up.
    pub(super) fn pause(&self) {
        self.cancel_wait();
        batch(|| {
            self.stop_at.set(None);
            self.paused.set(true);
        });
    }

    pub(super) fn play_from(&self, index: usize) {
        let Some(index) = self.kept_near(index, true) else {
            return;
        };
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        let inside = untracked(|| self.repeats(index));
        batch(|| {
            self.stop_at.set(None);
            if self.repeating.get_untracked().is_some() && !inside {
                self.repeating.set(Some(Span::one(segment.id.clone())));
                self.reps.set(0);
            }
            self.revealed.set(None);
        });
        self.jump(self.play_start(index), true);
        self.paused.set(false);
    }

    /// Whether the recording has a transcript yet: until it does, the reader only plays it.
    pub(super) fn has_text(&self) -> bool {
        self.job.with(|job| job.as_ref().is_some_and(|job| job.has_transcript()))
    }

    /// A sentence back or on; with no transcript, 15 seconds back or 30 on.
    pub(super) fn step(&self, by: isize) {
        if !untracked(|| self.has_text()) {
            let jump = if by < 0 { -15_000 } else { 30_000 };
            let end = self.duration_ms.get_untracked();
            let to = self.position_ms.get_untracked() + jump;
            self.seek(if end > 0 { to.clamp(0, end) } else { to.max(0) });
            return;
        }
        let from = untracked(|| self.target()).map_or(0, |index| index as isize);
        let next = (from + by).clamp(0, self.count().saturating_sub(1) as isize) as usize;
        if let Some(next) = self.kept_near(next, by >= 0) {
            self.follow();
            self.play_from(next);
        }
    }

    pub(super) fn toggle_repeat(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        if untracked(|| self.repeats(index)) {
            self.repeating.set(None);
            return;
        }
        self.start_repeat(index, segment, false);
    }

    /// Loops sentence `index` alone, from its start (Mimic counts each pass
    /// through it).
    pub(super) fn repeat_from_start(&self, index: usize) {
        if let Some(segment) = self.segment_now(index) {
            self.cancel_wait();
            self.start_repeat(index, segment, true);
        }
    }

    /// Loops sentence `index` alone. Unless `restart`, a sentence already
    /// playing plays on to its end and loops from there; another one plays
    /// from its start.
    fn start_repeat(&self, index: usize, segment: Segment, restart: bool) {
        let here = self.current.get_untracked() == Some(index);
        batch(|| {
            self.repeating.set(Some(Span::one(segment.id)));
            self.reps.set(0);
            self.stop_at.set(None);
        });
        if restart || !here {
            self.jump(self.play_start(index), true);
        }
        self.paused.set(false);
    }

    pub(super) fn repeat_through(&self, index: usize) {
        let Some((first, last)) = untracked(|| self.repeat_range()) else {
            self.toggle_repeat(index);
            return;
        };
        self.set_repeat(first.min(index), last.max(index));
    }

    pub(super) fn repeat_one(&self, index: usize) {
        if let Some(segment) = self.segment_now(index) {
            self.repeating.set(Some(Span::one(segment.id)));
        }
    }

    fn set_repeat(&self, first: usize, last: usize) {
        if let (Some(first), Some(last)) = (self.segment_now(first), self.segment_now(last)) {
            self.repeating.set(Some(Span { first: first.id, last: last.id }));
        }
    }

    pub(super) fn track_row(&self, index: Memo<Option<usize>>, row: ElementRef) -> u64 {
        let token = self.row_count.with(|count| {
            *count += 1;
            *count
        });
        self.rows.with(|rows| rows.push(Row { token, index, view: row }));
        let rows = self.rows;
        cleanup(move || {
            rows.try_with(|rows| rows.retain(|row| row.token != token));
        });
        token
    }

    pub(super) fn scrolled(&self, event: &ScrollEvent) {
        let by_hand = self.scroll.with(|scroll| {
            scroll.offset = event.offset.y.0;
            scroll.content = event.content_size.height.0;
            scroll.viewport = event.size.height.0;
            scroll.held_at.is_some_and(|at| (scroll.offset - at).abs() > HAND_SCROLL)
        });
        if by_hand {
            self.stop_following();
        }
    }

    /// A finger, the trackpad or the scroll bar took hold of the list
    /// (`Some`, where it was) or let go of it.
    pub(super) fn held(&self, at: Option<f32>) {
        self.scroll.with(|scroll| scroll.held_at = at);
    }

    /// The user scrolled the list: it stops bringing the sentence playing
    /// back into view.
    pub(super) fn stop_following(&self) {
        if self.following.get_untracked() {
            self.following.set(false);
        }
    }

    pub(super) fn follow(&self) {
        if !self.following.get_untracked() {
            self.following.set(true);
        }
    }

    pub(super) fn dragging(&self) -> bool {
        self.drag_anchor.with(Option::is_some)
    }

    fn anchor(&self) -> Option<usize> {
        let anchor = self.drag_anchor.get_untracked()?;
        self.index_of(&anchor)
    }

    /// A drag on sentence `index`'s repeat button: the repeat starts there,
    /// and the finger picks the sentence it reaches to, above or below.
    pub(super) fn begin_repeat_drag(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        self.drag_anchor.set(Some(segment.id.clone()));
        self.start_repeat(index, segment, false);
        self.drag.with(|drag| *drag = Drag::default());
        let (list, drag) = (self.list, self.drag);
        spawn(async move {
            if let Some(measure) = list.measure().await {
                let top = measure.page.y.0;
                drag.try_with(|drag| drag.viewport = Some((top, top + measure.frame.size.height.0)));
            }
        });
        self.measure_rows();
        let review = *self;
        let mover = spawn(async move {
            let mut tick = 0u32;
            loop {
                timer(Duration::from_millis(16)).await;
                if !review.dragging() {
                    return;
                }
                tick += 1;
                if review.auto_scroll() && tick.is_multiple_of(4) {
                    review.measure_rows();
                }
            }
        });
        if let Some(old) = self.drag_task.replace(Some(mover)) {
            old.cancel();
        }
    }

    fn auto_scroll(&self) -> bool {
        const EDGE: f32 = 64.0;
        const FASTEST: f32 = 18.0;
        let Some((finger, (top, bottom))) = self.drag.with(|drag| drag.finger.zip(drag.viewport)) else {
            return false;
        };
        let push = if finger > bottom - EDGE {
            ((finger - (bottom - EDGE)) / EDGE).min(1.0)
        } else if finger < top + EDGE {
            -((top + EDGE - finger) / EDGE).min(1.0)
        } else {
            return false;
        };
        let (offset, content, viewport) = self.scroll.with(|s| (s.offset, s.content, s.viewport));
        let to = (offset + push * FASTEST).clamp(0.0, (content - viewport).max(0.0));
        if (to - offset).abs() < 0.5 {
            return false;
        }
        self.scroll.with(|s| s.offset = to);
        self.list.scroll_to_offset(px(to), false);
        self.drag_to(finger);
        true
    }

    fn measure_rows(&self) {
        let Some(anchor) = self.anchor() else {
            return;
        };
        // The rows are chained out from the end the finger moves, which stays
        // in view while the anchor may have scrolled away.
        let moving = match untracked(|| self.repeat_range()) {
            Some((first, _)) if first < anchor => first,
            Some((_, last)) => last,
            None => anchor,
        };
        let rows = self.rows.with(|rows| rows.clone());
        let (drag, scroll) = (self.drag, self.scroll);
        let review = *self;
        spawn(async move {
            let offset = scroll.with(|s| s.offset);
            let measures: Vec<_> =
                rows.into_iter().filter_map(|row| Some((row.index.get_untracked()?, row.view.measure()))).collect();
            let mut found = std::collections::BTreeMap::new();
            for (index, measure) in measures {
                if let Some(measure) = measure.await {
                    let top = measure.page.y.0 + offset;
                    found.insert(index, (top, top + measure.frame.size.height.0));
                }
            }
            let zones = chain(&found, moving);
            if zones.is_empty() {
                return;
            }
            drag.try_with(|drag| drag.zones = zones);
            if let Some(finger) = drag.try_with(|drag| drag.finger).flatten() {
                review.drag_to(finger);
            }
        });
    }

    /// The finger of a repeat drag is at `y`: the repeat becomes the anchor
    /// through the sentence under it, made anew on each move, so a sentence the
    /// finger passed and came back from drops out again, and the repeat kept is
    /// the one under the finger when it lifts.
    pub(super) fn drag_to(&self, y: f32) {
        if !self.dragging() {
            return;
        }
        self.drag.with(|drag| drag.finger = Some(y));
        let Some(anchor) = self.anchor() else {
            return;
        };
        let at = y + self.scroll.with(|s| s.offset);
        let under = self.drag.with(|drag| {
            let (low, high) = (drag.zones.first()?, drag.zones.last()?);
            if at < low.1 {
                return Some(low.0);
            }
            if at >= high.2 {
                return Some(high.0);
            }
            drag.zones.iter().find(|(_, top, bottom)| (*top..*bottom).contains(&at)).map(|(index, ..)| *index)
        });
        if let Some(under) = under {
            self.set_repeat(anchor.min(under), anchor.max(under));
        }
    }

    pub(super) fn finish_repeat_drag(&self) {
        if let Some(task) = self.drag_task.replace(None) {
            task.cancel();
        }
        self.drag_anchor.set(None);
        self.drag.with(|drag| *drag = Drag::default());
    }

    pub(super) fn hold_repeat(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        self.cancel_wait();
        batch(|| {
            self.repeating.set(Some(Span::one(segment.id)));
            self.reps.set(0);
            self.stop_at.set(None);
            self.paused.set(false);
        });
    }

    pub(super) fn end_hold(&self, before: Option<Span>) {
        batch(|| {
            self.repeating.set(before);
            self.reps.set(0);
        });
    }

    pub(super) fn replay_once(&self, index: usize) {
        let Some(end) = self.play_end(index) else {
            return;
        };
        self.cancel_wait();
        self.stop_at.set(Some(end));
        self.jump(self.play_start(index), true);
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
        self.measure_lag(position_ms);
        if let Some((from, to)) = self.landing.with(|landing| *landing) {
            if !playback::landed(from, to, position_ms) {
                // Still sounding from before the seek: not where it is going.
                return;
            }
            self.settle();
        }
        if self.paused.get_untracked() {
            return;
        }
        self.position_ms.set(position_ms);
        self.last_tick.with(|last| *last = Some((Instant::now(), position_ms)));
        crate::state::activity::ActivityState::get().act(crate::state::activity::ActivityAction::Note(Kind::Listen));
        crate::state::sleep::SleepState::get().act(crate::state::sleep::SleepAction::Heard);
        self.disarm();
        if self.out_of_skipped(position_ms) {
            return;
        }
        let Some((end, edge)) = self.edge() else {
            return;
        };
        // The sound already on its way to the listener plays on after the
        // cut, so the cut goes ahead of the end by that too.
        let heard_ms = crate::services::output_latency_ms();
        let lag_ms = self.lag_ms.with(|lag| *lag) + heard_ms;
        match playback::time_to_end(position_ms, end, self.rate.get_untracked(), lag_ms) {
            Some(wait) if wait.is_zero() => self.reach(edge),
            Some(wait) => self.arm(wait, (end, edge)),
            None => {}
        }
    }

    /// Playing in a skipped run (after a seek, or from where it was left):
    /// on to the sentence after it, or stop when there is none. Whether it
    /// was there.
    fn out_of_skipped(&self, position_ms: i64) -> bool {
        let loudness = self.loudness.with_untracked(Option::clone);
        let after = self.document_now(|document| {
            let at = document.segment_at(position_ms, loudness.as_deref())?;
            document.segments[at].skipped.then(|| document.next_kept(at))
        });
        match after {
            None => false,
            Some(Some(next)) => {
                self.jump(self.play_start(next), true);
                true
            }
            Some(None) => {
                self.paused.set(true);
                true
            }
        }
    }

    /// Where what is playing ends, and what happens there.
    fn edge(&self) -> Option<(i64, Edge)> {
        if let Some(end) = self.stop_at.get_untracked() {
            return Some((end, Edge::Stop(self.current.get_untracked())));
        }
        let range = untracked(|| self.repeat_range());
        if let Some((first, _)) = range
            && self.practice.get_untracked() == Practice::Mimic
        {
            return Some((self.play_end(first)?, Edge::Mimic(first)));
        }
        if range.is_none() && self.practice.get_untracked() == Practice::Dictation {
            // Type answer never plays on into the next sentence.
            let current = self.current.get_untracked()?;
            return Some((self.play_end(current)?, Edge::Stop(Some(current))));
        }
        if let Some(skip) = self.skip_edge(range) {
            return Some(skip);
        }
        let (first, last) = range?;
        Some((self.play_end(last)?, Edge::Loop(self.next_kept(first).unwrap_or(first))))
    }

    /// The end of the sentence playing when skipped ones come after it: on
    /// past them, back to the start of a repeat they end, or stop when
    /// nothing is left.
    fn skip_edge(&self, range: Option<(usize, usize)>) -> Option<(i64, Edge)> {
        let current = self.current.get_untracked()?;
        if self.is_skipped(current) {
            return None;
        }
        let after = self.document_now(|document| document.after_skip(current))?;
        let edge = match (range, after) {
            (Some((first, last)), _) if current < first || current >= last => return None,
            (Some((_, last)), Some(next)) if next <= last => Edge::Skip(next),
            (Some((first, _)), _) => Edge::Loop(self.next_kept(first).unwrap_or(first)),
            (None, Some(next)) => Edge::Skip(next),
            (None, None) => Edge::Stop(None),
        };
        Some((self.play_end(current)?, edge))
    }

    /// Acts on `edge` when playback gets there, `wait` from now, unless a
    /// tick, a pause or a change to what is playing comes first.
    fn arm(&self, wait: Duration, edge: (i64, Edge)) {
        let review = *self;
        let task = spawn(async move {
            timer(wait).await;
            review.edge_timer.replace(None);
            let due = !review.paused.get_untracked()
                && review.landing.with(|landing| landing.is_none())
                && review.edge() == Some(edge);
            if due {
                review.reach(edge.1);
            }
        });
        if let Some(earlier) = self.edge_timer.replace(Some(task)) {
            earlier.cancel();
        }
    }

    fn disarm(&self) {
        if let Some(armed) = self.edge_timer.replace(None) {
            armed.cancel();
        }
    }

    fn reach(&self, edge: Edge) {
        if let Some((tick_at, from_ms)) = self.last_tick.with(|last| *last) {
            let waited_ms = tick_at.elapsed().as_secs_f64() * 1000.0;
            let sent = SentCut { at: Instant::now(), from_ms, waited_ms, rate: self.rate.get_untracked() };
            self.sent_cut.with(|cut| *cut = Some(sent));
        }
        match edge {
            Edge::Stop(sentence) => {
                if let Some(index) = sentence {
                    self.rewind(index);
                }
                batch(|| {
                    self.stop_at.set(None);
                    self.paused.set(true);
                    self.ended.update(|ended| *ended += 1);
                });
            }
            Edge::Loop(first) | Edge::Skip(first) => self.jump(self.play_start(first), true),
            Edge::Mimic(index) => self.end_mimic_pass(index),
        }
    }

    /// Cuts a sentence off at its end the way a repeat does: a quiet jump
    /// back to its start, the player playing on until it lands. Paused at the
    /// same time as the seek, AVPlayer plays on half a second into the next
    /// sentence, muted or not; a seek alone lands in some 70 ms.
    fn rewind(&self, index: usize) {
        self.jump(self.play_start(index), true);
        if self.landing.with(|landing| landing.is_some()) {
            self.holding.set(true);
        }
    }

    /// The player ticks the moment a seek or a pause reaches it (AVPlayer
    /// does): where it was then shows how long the cut took.
    fn measure_lag(&self, position_ms: i64) {
        let Some(sent) = self.sent_cut.with(Option::take) else {
            return;
        };
        if sent.at.elapsed() > Duration::from_millis(100) {
            return;
        }
        if let Some(measured) = playback::lag(sent.from_ms, sent.waited_ms, position_ms, sent.rate) {
            self.lag_ms.with(|lag| *lag = playback::adjusted_lag(*lag, measured));
        }
    }

    fn end_mimic_pass(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        crate::state::activity::ActivityState::get().act(crate::state::activity::ActivityAction::Touch);
        let goal = self.store.settings().mimic_rep_goal;
        let reps = (self.reps.get_untracked() + 1).min(goal);
        let pause_ms = dictation::mimic_pause_ms(
            segment.end_ms - segment.start_ms,
            f64::from(self.rate.get_untracked()),
            self.store.settings().mimic_pause_seconds,
        );
        self.rewind(index);
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
                review.jump(review.play_start(index), true);
                review.paused.set(false);
            } else if let Some(next) = review.next_kept(index + 1) {
                review.play_from(next);
            } else {
                review.repeating.set(None);
            }
        });
        self.wait.replace(Some(wait));
    }

    pub(super) fn pick(&self, segment_id: &str, event: &TextSelectionEvent) {
        if event.text.trim().is_empty() {
            let stale = self.selection.get_untracked().filter(|s| s.segment_id == segment_id);
            if stale.is_some() {
                let review = *self;
                spawn(async move {
                    timer(Duration::from_millis(400)).await;
                    if review.selection.get_untracked() == stale {
                        review.selection.set(None);
                    }
                });
            }
            return;
        }
        let found = self.job.with_untracked(|job| {
            let document = job.as_ref()?.document()?;
            let segment = document.segments.iter().find(|s| s.id == segment_id)?;
            let range = highlights::locate(&segment.text, &event.text, event.start)?;
            Some(Picked { segment_id: segment_id.to_owned(), range, text: event.text.clone() })
        });
        self.selection.set(found);
    }

    pub(super) fn picked_in(&self, segment_id: Option<&str>) -> bool {
        self.selection.with(|s| s.as_ref().is_some_and(|s| Some(s.segment_id.as_str()) == segment_id))
    }

    pub(super) fn picked_marked(&self) -> bool {
        let Some(picked) = self.selection.get() else {
            return false;
        };
        self.job.with(|job| {
            job.as_ref().and_then(|job| job.document()).is_some_and(|d| {
                d.segments
                    .iter()
                    .find(|s| s.id == picked.segment_id)
                    .is_some_and(|s| highlights::overlapping(&s.highlights, picked.range.clone()))
            })
        })
    }

    pub(super) fn toggle_highlight(&self) {
        let Some(picked) = self.selection.get_untracked() else {
            return;
        };
        self.store.update_document(&self.id(), |document| {
            if let Some(segment) = document.segments.iter_mut().find(|s| s.id == picked.segment_id) {
                if highlights::overlapping(&segment.highlights, picked.range.clone()) {
                    highlights::remove(&mut segment.highlights, picked.range.clone());
                } else {
                    highlights::add(&mut segment.highlights, picked.range.clone());
                }
            }
        });
        self.selection.set(None);
    }

    /// Clears the text selected in a sentence, as a tap outside it does in a
    /// text view. A sentence's area clears on taps inside it alone (iOS, and
    /// Android), so a tap elsewhere takes the focus off it, which clears it.
    pub(super) fn clear_selection(&self) {
        if self.selection.with_untracked(Option::is_some) {
            self.selection.set(None);
            dismiss_keyboard();
        }
    }

    pub(super) fn copy_selection(&self) {
        if let Some(picked) = self.selection.get_untracked() {
            super::copy(picked.text, None);
        }
    }

    pub(super) fn edit(&self, index: usize) {
        let Some(segment) = self.segment_now(index) else {
            return;
        };
        let mode = self.mode.get_untracked();
        let translated = segment.has_translation();
        let original = mode != ContentMode::Translated || !translated;
        let translation = mode != ContentMode::Original;
        batch(|| {
            self.draft.set(segment.text.clone());
            self.translation_draft.set(segment.translated_text.clone().unwrap_or_default());
            self.editing.set(Some(Editing { segment_id: segment.id, original, translation }));
        });
    }

    fn change(&self, done: &'static str, edit: impl FnOnce(&mut Document) -> bool) -> bool {
        let id = self.id();
        let before = self.job.with_untracked(|job| job.as_ref().and_then(|job| job.document()));
        let mut changed = false;
        self.store.update_document(&id, |document| changed = edit(document));
        if let (true, Some(before)) = (changed, before) {
            let generation = super::undo::keep(id, before);
            toast_with_action(Tone::Success, tr(done), tr("Undo"), move || {
                super::undo::undo(Some(generation));
            });
        }
        changed
    }

    pub(super) fn undo(&self) -> bool {
        let undone = super::undo::undo(None);
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
        if text.is_empty() && editing.original {
            self.remove_editing(&editing.segment_id);
            return;
        }
        let translation = self.translation_draft.get_untracked().trim().to_owned();
        let mut stale = None;
        self.change("Sentence updated", |document| {
            let Some(segment) = document.segments.iter_mut().find(|s| s.id == editing.segment_id) else {
                return false;
            };
            let mut changed = false;
            let wanted = (!translation.is_empty()).then_some(translation);
            if editing.original && segment.text != text {
                segment.highlights = highlights::reanchor(&segment.text, &text, &segment.highlights);
                // A corrected sentence whose translation nobody touched still
                // carries the translation of what it used to say.
                stale = (segment.has_translation() && (!editing.translation || segment.translated_text == wanted))
                    .then(|| text.clone());
                segment.text = text;
                changed = true;
            }
            if editing.translation && segment.translated_text != wanted {
                segment.translated_text = wanted;
                changed = true;
            }
            changed
        });
        self.editing.set(None);
        if let Some(source) = stale.filter(|_| self.can_translate()) {
            self.retranslate(editing.segment_id, source);
        }
    }

    /// Whether the AI is set up to translate a sentence.
    pub(super) fn can_translate(&self) -> bool {
        self.store.ai_ready()
    }

    /// Translates sentence `segment_id` again on its own, from `source`,
    /// what it reads now, apart from the recording's translation. The reply
    /// lands only while the sentence still reads `source`: an undo, another
    /// edit or a delete in the meantime drops it.
    pub(super) fn retranslate(&self, segment_id: String, source: String) {
        let Some(mut waiting) = self.retranslating.try_get() else {
            return;
        };
        waiting.push(segment_id.clone());
        self.retranslating.set(waiting);
        let (review, id, target) = (*self, self.id(), self.translation_target());
        self.store.run(async move {
            let result = ai::translate_line(&source, &target).await;
            if let Some(mut waiting) = review.retranslating.try_get() {
                if let Some(at) = waiting.iter().position(|waits| *waits == segment_id) {
                    waiting.remove(at);
                }
                review.retranslating.try_set(waiting);
            }
            let line = match result {
                Ok(line) => line,
                Err(code) if ai::needs_setup(&code) => {
                    toast_with_action(Tone::Error, error_text(&code), tr("Settings"), move || {
                        review.store.act(crate::state::Action::OpenSettings(SettingsTab::Ai))
                    });
                    return;
                }
                Err(code) => {
                    toast_with_action(Tone::Error, error_text(&code), tr("Retry"), move || {
                        review.retranslate(segment_id.clone(), source.clone())
                    });
                    return;
                }
            };
            let mut old = None;
            review.store.update_document(&id, |document| {
                if let Some(segment) = document.segments.iter_mut().find(|s| s.id == segment_id && s.text == source) {
                    old = segment.translated_text.replace(line.clone());
                }
            });
            // An editor opened on the sentence meanwhile shows the new
            // translation, unless its box was changed by hand.
            let open_here = review.editing.try_get().flatten().is_some_and(|e| e.segment_id == segment_id);
            if open_here && old.is_some_and(|old| review.translation_draft.get_untracked().trim() == old) {
                review.translation_draft.set(line);
            }
        });
    }

    /// The language this recording is translated into.
    pub(super) fn translation_target(&self) -> String {
        let target = self.store.job_now(&self.id()).map(|job| job.translation_state.target_language.clone());
        target
            .filter(|t| !t.is_empty())
            .or_else(|| Some(self.store.setting(|s| s.translation_preferences.target_language.clone())))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| "en".into())
    }

    pub(super) fn skip_editing(&self) {
        if let Some(index) = self.editing.get_untracked().and_then(|editing| self.index_of(&editing.segment_id)) {
            self.set_skipped(index, index, true);
        }
    }

    /// Whether the AI took sentence `index` for part of an ad, and nobody
    /// has acted on that yet.
    pub(super) fn found_ad(&self, index: usize) -> bool {
        self.job
            .with(|job| {
                let job = job.as_ref()?;
                let document = job.document()?;
                Some(job.ads().found.iter().any(|finding| {
                    listenook_core::ai::ads::locate(finding, &document)
                        .is_some_and(|(first, last)| (first..=last).contains(&index))
                }))
            })
            .unwrap_or(false)
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
        self.change("Sentence deleted", |document| structure::apply(document, Edit::Remove(index)));
        batch(|| {
            self.editing.set(None);
            if self.repeating.get_untracked().is_some_and(|span| span.first == segment_id || span.last == segment_id) {
                self.repeating.set(None);
            }
            if self.revealed.get_untracked().as_deref() == Some(segment_id) {
                self.revealed.set(None);
            }
        });
    }

    pub(super) fn split_editing(&self) {
        let Some(editing) = self.editing.get_untracked().filter(|editing| editing.original) else {
            return;
        };
        let (text, caret) = (self.draft.get_untracked(), self.caret.get_untracked() as usize);
        let translation = editing.translation.then(|| self.translation_draft.get_untracked().trim().to_owned());
        let Some(index) = self.index_of(&editing.segment_id) else {
            return;
        };
        // The halves of a translated sentence, to translate again: the first keeps the whole
        // sentence's translation and the second has none.
        let mut halves = Vec::new();
        let split = self.change("Sentence split", |document| {
            let mut trial = document.clone();
            trial.segments[index].text = text.clone();
            if let Some(translation) = &translation {
                trial.segments[index].translated_text = (!translation.is_empty()).then(|| translation.clone());
            }
            let translated = trial.segments[index].has_translation();
            let split = structure::apply(&mut trial, Edit::SplitAt(index, caret));
            if split {
                if translated {
                    halves = trial.segments[index..=index + 1].iter().map(|s| (s.id.clone(), s.text.clone())).collect();
                }
                *document = trial;
            }
            split
        });
        if split {
            self.editing.set(None);
            if self.can_translate() {
                for (id, text) in halves {
                    self.retranslate(id, text);
                }
            }
        }
    }

    pub(super) fn merge_editing(&self) {
        let Some(editing) = self.editing.get_untracked() else {
            return;
        };
        let Some(index) = self.index_of(&editing.segment_id) else {
            return;
        };
        let text = editing.original.then(|| self.draft.get_untracked().trim().to_owned()).filter(|t| !t.is_empty());
        let translation = editing.translation.then(|| self.translation_draft.get_untracked().trim().to_owned());
        let merged = self.change("Sentences merged", |document| {
            let mut trial = document.clone();
            let segment = &mut trial.segments[index];
            if let Some(text) = &text {
                segment.highlights = highlights::reanchor(&segment.text, text, &segment.highlights);
                segment.text = text.clone();
            }
            if let Some(translation) = &translation {
                segment.translated_text = (!translation.is_empty()).then(|| translation.clone());
            }
            let merged = structure::apply(&mut trial, Edit::MergeWithNext(index));
            if merged {
                *document = trial;
            }
            merged
        });
        if merged {
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

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::chain;

    #[test]
    fn spare_rows_off_screen_are_left_out_of_the_drop_zones() {
        let mut found: BTreeMap<usize, (f32, f32)> =
            (0..16).map(|i| (i, (56.0 + 88.0 * i as f32, 144.0 + 88.0 * i as f32))).collect();
        for spare in 16..22 {
            found.insert(spare, (44.0, 132.0));
        }
        let zones = chain(&found, 3);
        assert_eq!(zones.first().map(|z| z.0), Some(0));
        assert_eq!(zones.last().map(|z| z.0), Some(15));
    }

    #[test]
    fn rows_measured_after_a_gap_are_left_out() {
        let found = BTreeMap::from([(4, (0.0, 80.0)), (5, (80.0, 160.0)), (6, (400.0, 480.0)), (3, (-300.0, -220.0))]);
        assert_eq!(chain(&found, 5).iter().map(|z| z.0).collect::<Vec<_>>(), vec![4, 5]);
    }
}
