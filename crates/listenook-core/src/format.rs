pub(crate) fn clock(ms: i64) -> String {
    let total = ms.max(0) / 1000;
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 { format!("{hours:02}:{minutes:02}:{seconds:02}") } else { format!("{minutes:02}:{seconds:02}") }
}

pub fn track_position(position_ms: i64, duration_ms: i64) -> i64 {
    let step = (duration_ms / 1000).max(250);
    position_ms.max(0) / step * step
}

pub fn cue_time(ms: i64, separator: char) -> String {
    let ms = ms.max(0);
    format!("{:02}:{:02}:{:02}{separator}{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

fn duration_words(ms: i64) -> String {
    let total = ms.max(0) / 1000;
    let (hours, minutes) = (total / 3600, total / 60 % 60);
    if hours > 0 {
        format!("{hours} h {minutes} min")
    } else if minutes > 0 {
        format!("{minutes} min")
    } else {
        format!("{total} s")
    }
}

fn bytes(size: i64) -> String {
    let size = size.max(0) as f64;
    if size >= 1e9 {
        format!("{:.1} GB", size / 1e9)
    } else if size >= 1e6 {
        format!("{:.1} MB", size / 1e6)
    } else if size >= 1e3 {
        format!("{:.0} KB", size / 1e3)
    } else {
        format!("{size:.0} B")
    }
}

pub fn minutes_since(iso: &str) -> Option<i64> {
    let then = chrono::DateTime::parse_from_rfc3339(iso).ok()?;
    Some((chrono::Utc::now() - then.with_timezone(&chrono::Utc)).num_minutes().max(0))
}

fn date(iso: &str) -> String {
    iso.split('T').next().unwrap_or(iso).to_owned()
}

pub fn safe_file_name(name: &str, fallback: &str) -> String {
    let cleaned: String =
        name.chars()
            .map(|c| {
                if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || c.is_control() {
                    '_'
                } else {
                    c
                }
            })
            .collect();
    let cleaned = cleaned.trim().trim_end_matches(['.', ' ']).trim();
    if cleaned.is_empty() { fallback.to_owned() } else { cleaned.to_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clocks() {
        assert_eq!(clock(65_000), "01:05");
        assert_eq!(clock(3_725_000), "01:02:05");
        assert_eq!(cue_time(3_725_042, ','), "01:02:05,042");
        assert_eq!(duration_words(3_900_000), "1 h 5 min");
    }

    #[test]
    fn a_track_moves_a_thousandth_of_its_length_at_a_time() {
        let half_hour = 1_800_000;
        assert_eq!(track_position(0, half_hour), 0);
        assert_eq!(track_position(1_799, half_hour), 0);
        assert_eq!(track_position(1_800, half_hour), 1_800);
        assert_eq!(track_position(900_050, half_hour), 900_000);
        assert_eq!(track_position(-40, half_hour), 0);
        assert_eq!(track_position(249, 30_000), 0);
        assert_eq!(track_position(260, 30_000), 250);
        assert_eq!(track_position(1_234, 0), 1_000);
    }

    #[test]
    fn file_names() {
        assert_eq!(safe_file_name("a/b: c?. ", "transcript"), "a_b_ c_");
        assert_eq!(safe_file_name(" .. ", "transcript"), "transcript");
    }
}

/// A value to show in words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shown<'a> {
    /// A time in a recording, as `m:ss`, or `h:mm:ss` past an hour.
    Clock(i64),
    /// How long something lasts, in words.
    Duration(i64),
    /// A file's size, in bytes, kilobytes or megabytes.
    Size(i64),
    /// When an ISO time was, as a date.
    Date(&'a str),
}

/// `value` in words.
pub fn shown(value: Shown) -> String {
    match value {
        Shown::Clock(ms) => clock(ms),
        Shown::Duration(ms) => duration_words(ms),
        Shown::Size(size) => bytes(size),
        Shown::Date(iso) => date(iso),
    }
}
