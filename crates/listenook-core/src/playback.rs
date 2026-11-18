//! Stopping playback exactly at a sentence's end.
//!
//! The player reports where it is in ticks (every 50 ms while a sentence
//! repeats), and the place right after a sentence's end is often the next
//! sentence's first sound. Waiting for the first tick past the end lets up to
//! a tick of it through, and what the app does about it (mute, pause, seek)
//! takes a while to reach the player: 27 ms on an iPad Pro. So the end is
//! timed from the ticks before it, that lag is measured from the tick the
//! player sends when the cut takes hold, and a seek stays silent until a tick
//! shows it has landed.

use std::time::Duration;

/// How close to the end (in real time, past the lag and margin) a tick has to
/// be to time the end from it: within the next tick, with room for that tick
/// to come late.
const TIMED_WITHIN_MS: f64 = 120.0;

/// The lag before any was measured: a little over an iPad Pro's.
pub const DEFAULT_LAG_MS: f64 = 30.0;

/// The longest lag believed: a later report is not the cut's.
const MAX_LAG_MS: f64 = 80.0;

/// How far before the end the cut takes hold, for the sound already on its
/// way to the speaker then.
const MARGIN_MS: f64 = 15.0;

/// The wait from a tick at `position_ms` until a cut sent then takes hold
/// just before `end_ms`, playing at `rate` with `lag_ms` between sending and
/// taking hold: zero when it is due, `None` while the end is too far off to
/// time from this tick.
pub fn time_to_end(position_ms: i64, end_ms: i64, rate: f32, lag_ms: f64) -> Option<Duration> {
    let left = (end_ms - position_ms) as f64 / f64::from(rate.max(0.1)) - lag_ms - MARGIN_MS;
    if left <= 0.0 {
        return Some(Duration::ZERO);
    }
    (left <= TIMED_WITHIN_MS).then(|| Duration::from_micros((left * 1000.0) as u64))
}

/// The lag one cut shows: it was sent `waited_ms` after a tick at `from_ms`,
/// and the player's next tick, at `reported_ms`, came when it took hold.
/// `None` when that tick cannot be the cut's.
pub fn lag(from_ms: i64, waited_ms: f64, reported_ms: i64, rate: f32) -> Option<f64> {
    let lag = (reported_ms - from_ms) as f64 / f64::from(rate.max(0.1)) - waited_ms;
    (0.0..=MAX_LAG_MS).contains(&lag).then_some(lag)
}

/// The lag to time the next cut with, after `measured` joins `estimate`.
pub fn adjusted_lag(estimate: f64, measured: f64) -> f64 {
    (estimate + measured) / 2.0
}

/// How far short of the target a forward seek may land (a tick's rounding).
const LANDING_SLACK_MS: i64 = 50;

/// Whether a tick at `position_ms` comes from where a seek from `from_ms` to
/// `to_ms` landed, rather than from the player still playing on from where it
/// was. Going back, all it plays on with is at or past `from_ms`; going
/// forward, it is short of `to_ms`.
pub fn landed(from_ms: i64, to_ms: i64, position_ms: i64) -> bool {
    if to_ms < from_ms { position_ms < from_ms } else { position_ms >= to_ms - LANDING_SLACK_MS }
}

/// How loud a recording is every 10 ms, to find the pauses between
/// sentences: a transcript's times can be off by a word's tail (Soniox gives
/// every token 60 ms, so a sentence "ends" 60 ms after its last token starts).
///
/// Each frame is its level plus its level with the highs lifted (dB each), so
/// the hiss of an "s" counts as loud as a vowel and a pause is quiet in both.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Loudness {
    frames: Vec<u8>,
}

/// The length of a frame.
pub const FRAME_MS: i64 = 10;

/// How much quieter than the loudest frame around it a frame has to be to
/// count as a pause: about 10 dB on each of the two levels.
const PAUSE_DIP: u8 = 20;

impl Loudness {
    pub fn from_frames(frames: Vec<u8>) -> Loudness {
        Loudness { frames }
    }

    pub fn frames(&self) -> &[u8] {
        &self.frames
    }

    pub fn measure(samples: &[i16], rate: u32) -> Loudness {
        let mut meter = LoudnessMeter::new(rate);
        meter.push(samples);
        meter.finish()
    }

    /// The middle of the quietest frame from `from_ms` to `to_ms`, when it
    /// is a pause: clearly quieter than the loudest frame there.
    ///
    /// A sentence marked to start at `next_ms` often has a stop in its first
    /// word ("It got", "Each", "I turned"), as quiet as the pause before it
    /// under background music. A frame past `next_ms` with a word's sound
    /// between it and the quietest frame before `next_ms` is that stop, so
    /// the pause is the frame before.
    pub fn pause_between(&self, from_ms: i64, to_ms: i64, next_ms: i64) -> Option<i64> {
        let first = usize::try_from(from_ms.max(0) / FRAME_MS).ok()?;
        let last = usize::try_from(to_ms / FRAME_MS).ok()?.min(self.frames.len().checked_sub(1)?);
        let frames = self.frames.get(first..=last).filter(|frames| !frames.is_empty())?;
        let quietest = |frames: &[u8]| frames.iter().enumerate().min_by_key(|(_, level)| **level).map(|(at, _)| at);
        let loudest = *frames.iter().max()?;
        let pause = |at: usize| {
            (loudest.saturating_sub(frames[at]) >= PAUSE_DIP).then(|| (first + at) as i64 * FRAME_MS + FRAME_MS / 2)
        };
        let at = quietest(frames)?;
        let Some(next) = usize::try_from(next_ms.max(0) / FRAME_MS).ok().and_then(|next| next.checked_sub(first))
        else {
            return pause(at);
        };
        if at <= next {
            return pause(at);
        }
        let before = quietest(&frames[..=next])?;
        let word_between =
            frames[before + 1..at].iter().max().is_some_and(|level| *level >= frames[before].saturating_add(PAUSE_DIP));
        pause(if word_between { before } else { at })
    }
}

/// Measures [`Loudness`] from samples as they are decoded.
pub struct LoudnessMeter {
    frame: usize,
    filled: usize,
    level: f64,
    lifted: f64,
    previous: f64,
    frames: Vec<u8>,
}

impl LoudnessMeter {
    pub fn new(rate: u32) -> LoudnessMeter {
        let frame = (rate as usize * FRAME_MS as usize / 1000).max(1);
        LoudnessMeter { frame, filled: 0, level: 0.0, lifted: 0.0, previous: 0.0, frames: Vec::new() }
    }

    pub fn push(&mut self, samples: &[i16]) {
        for sample in samples {
            let sample = f64::from(*sample);
            let lifted = sample - 0.95 * self.previous;
            self.level += sample * sample;
            self.lifted += lifted * lifted;
            self.previous = sample;
            self.filled += 1;
            if self.filled == self.frame {
                let decibels = |sum: f64| 10.0 * (sum / self.frame as f64 + 1.0).log10();
                self.frames.push((decibels(self.level) + decibels(self.lifted)).round().clamp(0.0, 255.0) as u8);
                (self.filled, self.level, self.lifted) = (0, 0.0, 0.0);
            }
        }
    }

    pub fn finish(self) -> Loudness {
        Loudness { frames: self.frames }
    }
}

/// The subtitle to repeat, as (start, end), when playback was at `before`: the one already
/// repeating while it still plays, else the latest one to start of those playing. With
/// overlapping subtitles, an earlier one that ends first must not take the repeat over.
pub fn repeated_cue(
    cues: impl IntoIterator<Item = (i64, i64)>,
    held: Option<(i64, i64)>,
    before: i64,
) -> Option<(i64, i64)> {
    let covers = |(start, end): (i64, i64)| start <= before && before < end;
    held.filter(|&cue| covers(cue))
        .or_else(|| cues.into_iter().filter(|&cue| covers(cue)).max_by_key(|&(start, _)| start))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_subtitle_repeating_keeps_the_repeat_when_another_overlaps_it() {
        let cues = [(0, 5000), (4000, 8000), (9000, 10_000)];
        let held = repeated_cue(cues, None, 6000);
        assert_eq!(held, Some((4000, 8000)), "the one playing is repeated");
        assert_eq!(repeated_cue(cues, held, 4500), Some((4000, 8000)), "not the earlier one ending at 5 s");
        assert_eq!(repeated_cue(cues, None, 8500), None, "between subtitles nothing repeats");
        assert_eq!(repeated_cue(cues, held, 9500), Some((9000, 10_000)), "once past it, the next one");
    }

    fn tone(hertz: f64, amplitude: f64, ms: usize) -> Vec<i16> {
        (0..ms * 16)
            .map(|n| (amplitude * (2.0 * std::f64::consts::PI * hertz * n as f64 / 16_000.0).sin()) as i16)
            .collect()
    }

    #[test]
    fn a_hiss_is_as_loud_as_a_hum_of_the_same_level() {
        let hum = Loudness::measure(&tone(150.0, 3000.0, 100), 16_000);
        let hiss = Loudness::measure(&tone(6000.0, 3000.0, 100), 16_000);
        assert_eq!(hum.frames().len(), 10);
        assert!(hiss.frames()[5] > hum.frames()[5] + 20, "{:?} {:?}", hiss.frames(), hum.frames());
    }

    #[test]
    fn a_pause_is_the_quietest_frame_well_below_the_loudest() {
        let mut samples = tone(200.0, 8000.0, 300);
        samples.extend(tone(200.0, 30.0, 60));
        samples.extend(tone(5000.0, 3000.0, 200));
        let loudness = Loudness::measure(&samples, 16_000);
        let pause = loudness.pause_between(200, 450, i64::MAX).unwrap();
        assert!((300..360).contains(&pause), "{pause}");
        assert_eq!(loudness.pause_between(0, 250, i64::MAX), None, "no pause inside a vowel");
        assert_eq!(loudness.pause_between(600, 900, i64::MAX), None, "past the end");
    }

    #[test]
    fn the_cut_is_sent_ahead_of_the_end_by_the_lag() {
        assert_eq!(time_to_end(18_600, 18_810, 1.0, 30.0), None);
        assert_eq!(time_to_end(18_700, 18_810, 1.0, 30.0), Some(Duration::from_millis(65)));
        assert_eq!(time_to_end(18_750, 18_810, 1.0, 27.0), Some(Duration::from_millis(18)));
        assert_eq!(time_to_end(18_600, 18_810, 2.0, 30.0), Some(Duration::from_millis(60)));
        assert_eq!(time_to_end(18_770, 18_810, 1.0, 30.0), Some(Duration::ZERO));
        assert_eq!(time_to_end(18_900, 18_810, 1.0, 30.0), Some(Duration::ZERO));
    }

    #[test]
    fn the_lag_is_what_the_player_played_after_the_cut_was_sent() {
        // Sent on the tick at 18 800; the player was at 18 827 when it took hold.
        assert_eq!(lag(18_800, 0.0, 18_827, 1.0), Some(27.0));
        // Sent 18 ms after the tick at 18 750, by a timer.
        assert_eq!(lag(18_750, 18.0, 18_795, 1.0), Some(27.0));
        assert_eq!(lag(18_750, 0.0, 18_804, 2.0), Some(27.0));
        assert_eq!(lag(18_800, 0.0, 18_790, 1.0), None, "a tick from before it was sent");
        assert_eq!(lag(18_800, 0.0, 18_950, 1.0), None, "a later tick");
        assert_eq!(adjusted_lag(30.0, 27.0), 28.5);
    }

    #[test]
    fn a_seek_back_has_landed_once_a_tick_is_behind_where_it_left() {
        assert!(!landed(36_480, 32_430, 36_504), "the player still plays on past the end");
        assert!(!landed(36_480, 32_430, 36_480));
        assert!(landed(36_480, 32_430, 32_430));
        assert!(landed(36_480, 32_430, 32_470));
    }

    #[test]
    fn a_seek_forward_has_landed_once_a_tick_reaches_it() {
        assert!(!landed(10_000, 20_000, 10_040));
        assert!(landed(10_000, 20_000, 19_990));
        assert!(landed(10_000, 20_000, 20_030));
    }
}
