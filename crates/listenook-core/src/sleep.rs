//! The sleep timer: stops playback after a while of listening, or when what is
//! playing ends.
//!
//! The time counts only while something plays, so pausing holds it, and it
//! counts in real time whatever the playback speed.

/// The longest gap between two playback reports still counted whole: a longer
/// one means playback paused or stalled in between.
const GAP_MS: i64 = 2_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Sleep {
    #[default]
    Off,
    /// Stops once `left_ms` more is heard, of the `minutes` chosen.
    After { minutes: i64, left_ms: i64 },
    /// Stops when what is playing reaches its end.
    AtEnd,
}

impl Sleep {
    pub fn minutes(minutes: i64) -> Self {
        Sleep::After { minutes, left_ms: minutes * 60_000 }
    }

    /// The minutes chosen, while it counts them down.
    pub fn minutes_chosen(self) -> Option<i64> {
        match self {
            Sleep::After { minutes, .. } => Some(minutes),
            _ => None,
        }
    }

    pub fn is_on(self) -> bool {
        self != Sleep::Off
    }

    /// Playback went on `since_ms` after its last report; true when that
    /// used the time up, and the timer is then off.
    pub fn heard(&mut self, since_ms: i64) -> bool {
        let Sleep::After { left_ms, .. } = self else {
            return false;
        };
        *left_ms -= since_ms.clamp(0, GAP_MS);
        if *left_ms > 0 {
            return false;
        }
        *self = Sleep::Off;
        true
    }

    /// What was playing reached its end; true when the timer waited for it,
    /// and it is then off.
    pub fn ended(&mut self) -> bool {
        if *self != Sleep::AtEnd {
            return false;
        }
        *self = Sleep::Off;
        true
    }

    /// The time left, rounded up to the second, for a countdown.
    pub fn left_ms(self) -> Option<i64> {
        match self {
            Sleep::After { left_ms, .. } => Some((left_ms + 999) / 1000 * 1000),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_down_while_heard_and_stops_once() {
        let mut sleep = Sleep::minutes(5);
        for _ in 0..599 {
            assert!(!sleep.heard(500));
        }
        assert_eq!(sleep.left_ms(), Some(1000));
        assert!(sleep.heard(500));
        assert_eq!(sleep, Sleep::Off);
        assert!(!sleep.heard(500));
    }

    #[test]
    fn a_pause_between_reports_is_not_counted() {
        let mut sleep = Sleep::minutes(5);
        sleep.heard(10 * 60_000);
        assert_eq!(sleep, Sleep::After { minutes: 5, left_ms: 5 * 60_000 - GAP_MS });
        sleep.heard(-20);
        assert_eq!(sleep, Sleep::After { minutes: 5, left_ms: 5 * 60_000 - GAP_MS });
        assert_eq!(sleep.minutes_chosen(), Some(5));
    }

    #[test]
    fn the_countdown_rounds_up() {
        assert_eq!(Sleep::After { minutes: 1, left_ms: 59_001 }.left_ms(), Some(60_000));
        assert_eq!(Sleep::After { minutes: 1, left_ms: 60_000 }.left_ms(), Some(60_000));
        assert_eq!(Sleep::AtEnd.left_ms(), None);
    }

    #[test]
    fn only_the_end_of_episode_timer_waits_for_the_end() {
        let mut at_end = Sleep::AtEnd;
        assert!(!at_end.heard(1000));
        assert!(at_end.ended());
        assert_eq!(at_end, Sleep::Off);
        let mut timed = Sleep::minutes(10);
        assert!(!timed.ended());
        assert!(timed.is_on());
        assert!(!Sleep::Off.ended());
    }
}
