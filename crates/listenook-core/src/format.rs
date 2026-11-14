pub fn clock(ms: i64) -> String {
    let total = ms.max(0) / 1000;
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 { format!("{hours:02}:{minutes:02}:{seconds:02}") } else { format!("{minutes:02}:{seconds:02}") }
}

pub fn cue_time(ms: i64, separator: char) -> String {
    let ms = ms.max(0);
    format!("{:02}:{:02}:{:02}{separator}{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

pub fn duration_words(ms: i64) -> String {
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

pub fn bytes(size: i64) -> String {
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

pub fn date(iso: &str) -> String {
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
    fn file_names() {
        assert_eq!(safe_file_name("a/b: c?. ", "transcript"), "a_b_ c_");
        assert_eq!(safe_file_name(" .. ", "transcript"), "transcript");
    }
}
