use std::time::Instant;

use listenook_core::sleep::Sleep;
use nsh_core::prelude::*;

/// The one sleep timer every player obeys: each reports what it plays, and
/// each pauses when `stops` moves on.
#[derive(Clone, Copy)]
pub(crate) struct SleepState {
    timer: Signal<Sleep>,
    stops: Signal<u32>,
    last_heard: Stored<Option<Instant>>,
}

/// What the players and the person tell the sleep timer.
#[derive(Debug)]
pub(crate) enum SleepAction {
    Set(Sleep),
    /// Pauses every player, as the timer does when it runs out: recording
    /// what the computer plays starts.
    PausePlayers,
    /// A player reported progress while playing.
    Heard,
}

impl SleepState {
    /// Does `action`.
    pub(crate) fn act(&self, action: SleepAction) {
        match action {
            SleepAction::Set(timer) => self.set(timer),
            SleepAction::PausePlayers => self.pause_players(),
            SleepAction::Heard => self.heard(),
        }
    }

    pub(crate) fn install() {
        super::install(Self { timer: signal(Sleep::Off), stops: signal(0), last_heard: stored(None) });
    }

    pub(crate) fn get() -> Self {
        super::installed()
    }

    pub(crate) fn timer(&self) -> Sleep {
        self.timer.get()
    }

    fn set(&self, timer: Sleep) {
        self.last_heard.with(|last| *last = None);
        self.timer.set(timer);
    }

    /// How many times the timer stopped playback, for players to pause on.
    pub(crate) fn stops(&self) -> u32 {
        self.stops.get()
    }

    /// Pauses every player, as the timer does when it runs out: recording
    /// what the computer plays starts.
    fn pause_players(&self) {
        self.stops.update(|count| *count += 1);
    }

    /// A player reported progress while playing.
    fn heard(&self) {
        let now = Instant::now();
        let since = self.last_heard.with(|last| last.replace(now)).map(|then| now.duration_since(then));
        if !self.timer.with_untracked(|timer| matches!(timer, Sleep::After { .. })) {
            return;
        }
        let since_ms = since.map_or(0, |since| since.as_millis() as i64);
        let mut timer = self.timer.get_untracked();
        let up = timer.heard(since_ms);
        batch(|| {
            self.timer.set(timer);
            if up {
                self.stops.update(|count| *count += 1);
            }
        });
    }

    /// What a player played reached its end; true when the timer stops
    /// playback there.
    pub(crate) fn ended(&self) -> bool {
        let mut timer = self.timer.get_untracked();
        if !timer.ended() {
            return false;
        }
        batch(|| {
            self.timer.set(timer);
            self.stops.update(|count| *count += 1);
        });
        true
    }
}
