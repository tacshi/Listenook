//! Counts the time spent learning: seconds while something plays, and while a
//! practice mode is open and in use. Every surface advances one shared clock,
//! so overlapping reports never count a second twice.

use std::time::{Duration, Instant};

use listenook_core::activity::{self, Activity, Kind, NaiveDate};
use nsh_core::prelude::*;

use crate::services::persist;

/// A longer gap between two reports is a pause, a suspension or idleness: it
/// restarts the clock instead of counting.
const GAP: Duration = Duration::from_secs(5);
/// Practice with nothing playing counts while the last input is this recent.
const IDLE: Duration = Duration::from_secs(120);
/// How often counted time reaches the charts.
const FOLD: Duration = Duration::from_secs(15);
/// How often counted time is written without telling Sync.
const SAVE: Duration = Duration::from_secs(30);

/// The clock behind the counting, apart from the app so it can be tested.
#[derive(Debug, Default)]
pub(crate) struct Tracker {
    last_note: Option<Instant>,
    last_input: Option<Instant>,
    practicing: bool,
    pending_ms: [u64; 2],
}

fn slot(kind: Kind) -> usize {
    match kind {
        Kind::Listen => 0,
        Kind::Practice => 1,
    }
}

/// What the clock hears of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Event {
    /// Something played, as a playback progress report says.
    Played(Kind),
    /// The person did something in a practice mode.
    Input,
    /// A practice mode opened or closed.
    Practicing(bool),
}

impl Tracker {
    pub(crate) fn hear(&mut self, now: Instant, event: Event) {
        match event {
            Event::Played(kind) => self.note(now, kind),
            Event::Input => self.last_input = Some(now),
            Event::Practicing(on) => {
                self.practicing = on;
                if on {
                    self.last_input = Some(now);
                }
            }
        }
    }

    fn note(&mut self, now: Instant, kind: Kind) {
        let kind = if self.practicing { Kind::Practice } else { kind };
        if let Some(last) = self.last_note {
            let elapsed = now.saturating_duration_since(last);
            if elapsed <= GAP {
                self.pending_ms[slot(kind)] += elapsed.as_millis() as u64;
            }
        }
        self.last_note = Some(now);
        self.last_input = Some(now);
    }

    /// The practice heartbeat: counts while a practice mode is open and was
    /// used recently.
    pub(crate) fn heartbeat(&mut self, now: Instant) {
        if self.practicing && self.last_input.is_some_and(|at| now.saturating_duration_since(at) < IDLE) {
            let input = self.last_input;
            self.note(now, Kind::Practice);
            self.last_input = input;
        }
    }

    /// Nothing reported for a while.
    pub(crate) fn quiet(&self, now: Instant) -> bool {
        self.last_note.is_none_or(|at| now.saturating_duration_since(at) > GAP)
    }

    pub(crate) fn has_pending(&self) -> bool {
        self.pending_ms.iter().any(|ms| *ms >= 1000)
    }

    /// Whole seconds counted since the last take, by kind.
    pub(crate) fn take(&mut self) -> [(Kind, u32); 2] {
        let mut out = [(Kind::Listen, 0), (Kind::Practice, 0)];
        for (index, kind) in [Kind::Listen, Kind::Practice].into_iter().enumerate() {
            let secs = self.pending_ms[index] / 1000;
            self.pending_ms[index] -= secs * 1000;
            out[index] = (kind, secs as u32);
        }
        out
    }
}

struct Book {
    tracker: Tracker,
    day: NaiveDate,
    last_fold: Instant,
    last_save: Instant,
    unsaved: bool,
    unshared: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct ActivityState {
    log: Signal<Activity>,
    book: Stored<Book>,
}

/// What counts toward the time spent learning, and when to write it.
#[derive(Debug)]
pub(crate) enum ActivityAction<'a> {
    /// Something played: called on each playback progress report.
    Note(Kind),
    /// The user did something in a practice mode.
    Touch,
    SetPracticing(bool),
    /// Writes the time counted so far now, and tells Sync: the app is going to the background,
    /// where the system may end it, or quitting.
    Flush,
    /// Once a second, from the shell.
    Tick,
    /// Another device's log, from Sync.
    Adopt(&'a Activity),
}

impl ActivityState {
    /// Does `action`.
    pub(crate) fn act(&self, action: ActivityAction<'_>) {
        match action {
            ActivityAction::Note(kind) => self.note(kind),
            ActivityAction::Touch => self.touch(),
            ActivityAction::SetPracticing(on) => self.set_practicing(on),
            ActivityAction::Flush => self.flush(),
            ActivityAction::Tick => self.tick(),
            ActivityAction::Adopt(theirs) => self.adopt(theirs),
        }
    }

    /// Makes the activity state from the log the library keeps.
    pub(crate) fn install() {
        let log = persist::data_root().as_deref().map(persist::load_activity).unwrap_or_default();
        super::install(Self::new(log));
    }

    pub(crate) fn get() -> Self {
        super::installed()
    }

    fn new(log: Activity) -> Self {
        let now = Instant::now();
        Self {
            log: signal(log),
            book: stored(Book {
                tracker: Tracker::default(),
                day: activity::today(),
                last_fold: now,
                last_save: now,
                unsaved: false,
                unshared: false,
            }),
        }
    }

    pub(crate) fn log(&self) -> Activity {
        self.log.get()
    }

    pub(crate) fn with<T>(&self, read: impl FnOnce(&Activity) -> T) -> T {
        self.log.with(read)
    }

    /// Something played: called on each playback progress report.
    fn note(&self, kind: Kind) {
        let now = Instant::now();
        self.book.with(|book| book.tracker.hear(now, Event::Played(kind)));
        self.settle(now, false);
    }

    /// The user did something in a practice mode.
    fn touch(&self) {
        let now = Instant::now();
        self.book.with(|book| book.tracker.hear(now, Event::Input));
    }

    fn set_practicing(&self, on: bool) {
        let now = Instant::now();
        self.book.with(|book| book.tracker.hear(now, Event::Practicing(on)));
        if !on {
            self.settle(now, true);
        }
    }

    /// Writes the time counted so far now, and tells Sync: the app is going to the background,
    /// where the system may end it, or quitting.
    fn flush(&self) {
        self.settle(Instant::now(), true);
    }

    /// Once a second, from the shell.
    fn tick(&self) {
        let now = Instant::now();
        self.book.with(|book| book.tracker.heartbeat(now));
        let quiet = self.book.with(|book| book.tracker.quiet(now) && (book.unsaved || book.unshared));
        self.settle(now, quiet);
    }

    /// Folds counted time into the log when it is due, and writes it.
    /// `flush` folds and writes now, and tells Sync.
    fn settle(&self, now: Instant, flush: bool) {
        let today = activity::today();
        let (rolled, due) = self.book.with(|book| {
            let rolled = book.day != today;
            let due = flush || rolled || now.duration_since(book.last_fold) >= FOLD;
            (rolled, due && (book.tracker.has_pending() || rolled || flush))
        });
        if !due {
            return;
        }
        let (day, counted) = self.book.with(|book| {
            book.last_fold = now;
            let day = book.day;
            book.day = today;
            (day, book.tracker.take())
        });
        if counted.iter().any(|(_, secs)| *secs > 0) {
            let device = super::store().device_id();
            self.log.update(|log| {
                for (kind, secs) in counted {
                    log.add(&device, day, kind, secs);
                }
            });
            self.book.with(|book| {
                book.unsaved = true;
                book.unshared = true;
            });
        }
        let share = flush || rolled;
        let save = self.book.with(|book| (book.unsaved && now.duration_since(book.last_save) >= SAVE) || share);
        if save {
            self.save(now, share);
        }
    }

    fn save(&self, now: Instant, share: bool) {
        let Some(root) = persist::data_root() else {
            return;
        };
        let (unsaved, unshared) = self.book.with(|book| (book.unsaved, book.unshared));
        if !unsaved && !(share && unshared) {
            return;
        }
        let share = share && unshared;
        if let Err(error) = persist::save_activity(&root, &self.log.get_untracked(), share) {
            log::error!("saving the learning time: {error}");
            return;
        }
        self.book.with(|book| {
            book.last_save = now;
            book.unsaved = false;
            if share {
                book.unshared = false;
            }
        });
    }

    /// Another device's log, from Sync.
    fn adopt(&self, theirs: &Activity) {
        let mut mine = self.log.get_untracked();
        if !mine.merge(theirs) {
            return;
        }
        self.log.set(mine);
        if let Some(root) = persist::data_root()
            && let Err(error) = persist::save_activity(&root, &self.log.get_untracked(), false)
        {
            log::error!("saving the learning time: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(tracker: &mut Tracker) -> (u32, u32) {
        let [(_, listen), (_, practice)] = tracker.take();
        (listen, practice)
    }

    #[test]
    fn overlapping_reports_count_once() {
        let start = Instant::now();
        let mut tracker = Tracker::default();
        for tenth in 0..=100 {
            let at = start + Duration::from_millis(tenth * 100);
            tracker.hear(at, Event::Played(Kind::Listen));
            tracker.hear(at + Duration::from_millis(50), Event::Played(Kind::Listen));
        }
        assert_eq!(secs(&mut tracker), (10, 0));
    }

    #[test]
    fn a_long_gap_is_not_counted() {
        let start = Instant::now();
        let mut tracker = Tracker::default();
        tracker.hear(start, Event::Played(Kind::Listen));
        tracker.hear(start + Duration::from_secs(2), Event::Played(Kind::Listen));
        tracker.hear(start + Duration::from_secs(600), Event::Played(Kind::Listen));
        tracker.hear(start + Duration::from_secs(601), Event::Played(Kind::Listen));
        assert_eq!(secs(&mut tracker), (3, 0));
    }

    #[test]
    fn practice_counts_while_in_use_and_stops_when_idle() {
        let start = Instant::now();
        let mut tracker = Tracker::default();
        tracker.hear(start, Event::Practicing(true));
        for second in 1..=200 {
            tracker.heartbeat(start + Duration::from_secs(second));
        }
        // Counted until two minutes after the last input.
        assert_eq!(secs(&mut tracker), (0, 118));
        tracker.hear(start + Duration::from_secs(300), Event::Input);
        for second in 301..=310 {
            tracker.heartbeat(start + Duration::from_secs(second));
        }
        assert_eq!(secs(&mut tracker), (0, 9));
    }

    #[test]
    fn playing_while_practicing_counts_as_practice() {
        let start = Instant::now();
        let mut tracker = Tracker::default();
        tracker.hear(start, Event::Practicing(true));
        for second in 0..=10 {
            let at = start + Duration::from_secs(second);
            tracker.hear(at, Event::Played(Kind::Listen));
            tracker.heartbeat(at + Duration::from_millis(500));
        }
        assert_eq!(secs(&mut tracker), (0, 10));
    }
}
