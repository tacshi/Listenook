//! Time spent learning: seconds of listening and of practice per learning day,
//! kept per device so that devices syncing their logs add up without counting
//! a second twice.

use std::collections::BTreeMap;

use chrono::Datelike;
pub use chrono::{Days, NaiveDate};
use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Listen,
    Practice,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Day {
    pub listen_s: u32,
    pub practice_s: u32,
}

impl Day {
    pub fn total_s(&self) -> u32 {
        self.listen_s.saturating_add(self.practice_s)
    }

    fn add(&mut self, other: Day) {
        self.listen_s = self.listen_s.saturating_add(other.listen_s);
        self.practice_s = self.practice_s.saturating_add(other.practice_s);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Activity {
    pub version: u32,
    /// Device id → learning day (`YYYY-MM-DD`) → time spent that day.
    pub devices: BTreeMap<String, BTreeMap<String, Day>>,
}

impl Default for Activity {
    fn default() -> Self {
        Self { version: VERSION, devices: BTreeMap::new() }
    }
}

pub fn day_key(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

pub fn parse_day(key: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(key, "%Y-%m-%d").ok()
}

/// A learning day runs from 2:00 to 2:00 local time, so a session that goes on
/// past midnight still counts toward the evening it started in.
const DAY_STARTS_AT: chrono::TimeDelta = chrono::TimeDelta::hours(2);

/// The learning day a local time falls in.
pub fn learning_day(at: chrono::NaiveDateTime) -> NaiveDate {
    (at - DAY_STARTS_AT).date()
}

pub fn today() -> NaiveDate {
    learning_day(chrono::Local::now().naive_local())
}

/// Monday = 0 … Sunday = 6.
pub fn weekday_index(day: NaiveDate) -> u32 {
    day.weekday().num_days_from_monday()
}

impl Activity {
    pub fn is_empty(&self) -> bool {
        self.devices.values().all(|days| days.values().all(|day| day.total_s() == 0))
    }

    pub fn add(&mut self, device: &str, day: NaiveDate, kind: Kind, secs: u32) {
        if secs == 0 || device.is_empty() {
            return;
        }
        let entry = self.devices.entry(device.to_owned()).or_default().entry(day_key(day)).or_default();
        match kind {
            Kind::Listen => entry.listen_s = entry.listen_s.saturating_add(secs),
            Kind::Practice => entry.practice_s = entry.practice_s.saturating_add(secs),
        }
    }

    /// Every day's time, summed across devices.
    pub fn totals(&self) -> BTreeMap<String, Day> {
        let mut totals: BTreeMap<String, Day> = BTreeMap::new();
        for days in self.devices.values() {
            for (key, day) in days {
                totals.entry(key.clone()).or_default().add(*day);
            }
        }
        totals
    }

    pub fn on(&self, day: NaiveDate) -> Day {
        let key = day_key(day);
        let mut total = Day::default();
        for days in self.devices.values() {
            if let Some(day) = days.get(&key) {
                total.add(*day);
            }
        }
        total
    }

    /// The `n` days ending with `last`, oldest first, days without time as zero.
    pub fn days(&self, last: NaiveDate, n: u32) -> Vec<(NaiveDate, Day)> {
        let totals = self.totals();
        (0..n)
            .rev()
            .filter_map(|back| last.checked_sub_days(Days::new(u64::from(back))))
            .map(|day| (day, totals.get(&day_key(day)).copied().unwrap_or_default()))
            .collect()
    }

    /// How many days with any time at all.
    pub fn active_days(&self) -> usize {
        self.totals().values().filter(|day| day.total_s() > 0).count()
    }

    /// Days in a row the goal was met, ending today, or yesterday while today
    /// has not met it yet.
    pub fn streak(&self, today: NaiveDate, goal_s: u32) -> u32 {
        let goal_s = goal_s.max(1);
        let totals = self.totals();
        let met = |day: NaiveDate| totals.get(&day_key(day)).is_some_and(|d| d.total_s() >= goal_s);
        let mut day = if met(today) { today } else { today - Days::new(1) };
        let mut count = 0;
        while met(day) {
            count += 1;
            match day.checked_sub_days(Days::new(1)) {
                Some(before) => day = before,
                None => break,
            }
        }
        count
    }

    /// Takes in another device's log. A device only ever adds to its own
    /// entries, so the larger value is the later one. Returns whether
    /// anything changed.
    pub fn merge(&mut self, other: &Activity) -> bool {
        let mut changed = false;
        for (device, days) in &other.devices {
            let mine = self.devices.entry(device.clone()).or_default();
            for (key, theirs) in days {
                let day = mine.entry(key.clone()).or_default();
                let merged = Day {
                    listen_s: day.listen_s.max(theirs.listen_s),
                    practice_s: day.practice_s.max(theirs.practice_s),
                };
                if merged != *day {
                    *day = merged;
                    changed = true;
                }
            }
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        parse_day(s).unwrap()
    }

    #[test]
    fn a_learning_day_turns_over_at_two() {
        let at = |s: &str| chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap();
        assert_eq!(learning_day(at("2026-11-25 23:30")), d("2026-11-25"));
        assert_eq!(learning_day(at("2026-11-26 01:59")), d("2026-11-25"));
        assert_eq!(learning_day(at("2026-11-26 02:00")), d("2026-11-26"));
    }

    #[test]
    fn time_adds_up_per_day_and_kind() {
        let mut log = Activity::default();
        log.add("a", d("2026-11-17"), Kind::Listen, 60);
        log.add("a", d("2026-11-17"), Kind::Listen, 30);
        log.add("a", d("2026-11-17"), Kind::Practice, 15);
        log.add("a", d("2026-11-16"), Kind::Practice, 5);
        assert_eq!(log.on(d("2026-11-17")), Day { listen_s: 90, practice_s: 15 });
        assert_eq!(log.on(d("2026-11-16")).total_s(), 5);
        assert_eq!(log.active_days(), 2);
    }

    #[test]
    fn devices_sum_up() {
        let mut log = Activity::default();
        log.add("a", d("2026-11-17"), Kind::Listen, 60);
        log.add("b", d("2026-11-17"), Kind::Listen, 40);
        assert_eq!(log.on(d("2026-11-17")).listen_s, 100);
    }

    #[test]
    fn days_fill_gaps_oldest_first() {
        let mut log = Activity::default();
        log.add("a", d("2026-11-15"), Kind::Listen, 60);
        let days = log.days(d("2026-11-17"), 4);
        let keys: Vec<String> = days.iter().map(|(day, _)| day_key(*day)).collect();
        assert_eq!(keys, ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"]);
        assert_eq!(days[1].1.listen_s, 60);
        assert_eq!(days[3].1, Day::default());
    }

    #[test]
    fn merging_keeps_the_larger_and_never_double_counts() {
        let mut here = Activity::default();
        here.add("a", d("2026-11-17"), Kind::Listen, 100);
        let mut there = Activity::default();
        there.add("a", d("2026-11-17"), Kind::Listen, 60);
        there.add("b", d("2026-11-17"), Kind::Practice, 30);
        assert!(here.merge(&there));
        assert!(!here.merge(&there));
        assert_eq!(here.on(d("2026-11-17")), Day { listen_s: 100, practice_s: 30 });
        let mut other = there.clone();
        other.merge(&here);
        assert_eq!(other, here);
    }

    #[test]
    fn a_streak_counts_met_days_in_a_row() {
        let mut log = Activity::default();
        for day in ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16"] {
            log.add("a", d(day), Kind::Listen, 1200);
        }
        log.add("a", d("2026-11-11"), Kind::Listen, 1200);
        // Today not met yet: the streak runs to yesterday.
        assert_eq!(log.streak(d("2026-11-17"), 1200), 4);
        log.add("a", d("2026-11-17"), Kind::Practice, 1200);
        assert_eq!(log.streak(d("2026-11-17"), 1200), 5);
        assert_eq!(log.streak(d("2026-11-17"), 1201), 0);
        assert_eq!(log.streak(d("2026-11-20"), 1200), 0);
    }

    #[test]
    fn an_older_file_reads() {
        let log: Activity = serde_json::from_str("{}").unwrap();
        assert!(log.is_empty());
        assert_eq!(log.version, VERSION);
    }
}
