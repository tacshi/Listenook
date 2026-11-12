//! SRT, WebVTT and ASS/SSA files as transcripts. Imported cues keep their
//! own timings: nothing is recognized or aligned.

use std::{path::Path, sync::LazyLock};

use regex::Regex;

use crate::models::{Document, Segment, Speaker, now_iso};

/// The media a job can be made from.
pub const MEDIA_EXTENSIONS: &[&str] = &["mp3", "wav", "m4a", "ogg", "mp4", "mkv", "avi"];
/// The subtitle files that pair with media.
pub const SUBTITLE_EXTENSIONS: &[&str] = &["srt", "vtt", "ass", "ssa"];
const LANGUAGE_SUFFIXES: &[&str] = &["zh", "yue", "en", "de", "es", "fr", "it", "pt", "ru", "ko", "ja"];

static BRACKETED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[[^\]\r\n]*\]|>{2,}").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t]+").unwrap());
static BLANK_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\n(?:[ \t]*\n)+").unwrap());
static CLOCK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$").unwrap());
static VOICE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<v(?:\.\S+)*\s+([^>]+)>").unwrap());
static TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<[^>]*>").unwrap());
static ASS_OVERRIDE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\{[^}]*\}").unwrap());
static ASS_DRAW_ON: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\p[1-9]").unwrap());

/// One timed line of a subtitle file.
#[derive(Debug, Clone, PartialEq)]
pub struct Cue {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

/// What a subtitle file gave.
#[derive(Debug, Clone, PartialEq)]
pub struct ImportedSubtitles {
    pub document: Document,
    /// Cues left out: unreadable, empty or ending before they start.
    pub ignored: usize,
}

/// The lower-cased extension of a path.
pub fn extension(path: &str) -> String {
    Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase()
}

/// Whether a job can be made from the file.
pub fn is_media(path: &str) -> bool {
    MEDIA_EXTENSIONS.contains(&extension(path).as_str())
}

/// Whether the file is a subtitle file this app reads.
pub fn is_subtitle(path: &str) -> bool {
    SUBTITLE_EXTENSIONS.contains(&extension(path).as_str())
}

/// Whether a subtitle file belongs to a media file: beside it, with the same
/// name, or the same name and a language suffix (`talk.en.srt`).
pub fn pairs_with(subtitle: &str, media: &str) -> bool {
    let (subtitle, media) = (Path::new(subtitle), Path::new(media));
    if subtitle.parent() != media.parent() {
        return false;
    }
    let stem = |p: &Path| p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
    let (subtitle, media) = (stem(subtitle), stem(media));
    if subtitle == media {
        return true;
    }
    subtitle.rsplit_once('.').is_some_and(|(base, suffix)| {
        let primary = suffix.replace('_', "-");
        base == media && LANGUAGE_SUFFIXES.contains(&primary.split('-').next().unwrap_or(""))
    })
}

/// Bytes of a subtitle file as text: UTF-8 or UTF-16 by their marks, else
/// UTF-8, else Windows-1252.
pub fn decode(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    let utf16 = |rest: &[u8], big: bool| {
        let units: Vec<u16> = rest
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| if big { u16::from_be_bytes(*pair) } else { u16::from_le_bytes(*pair) })
            .collect();
        String::from_utf16_lossy(&units)
    };
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return utf16(rest, false);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return utf16(rest, true);
    }
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_owned(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// Removes `[sound]` notes and `>>` marks, and tidies the spaces of each line.
pub fn clean_caption(text: &str, keep_line_breaks: bool) -> String {
    let text = BRACKETED.replace_all(text, "").replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<String> = text
        .split('\n')
        .map(|line| SPACES.replace_all(line, " ").trim().to_owned())
        .filter(|line| !line.is_empty())
        .collect();
    lines.join(if keep_line_breaks { "\n" } else { " " })
}

fn clock_ms(text: &str) -> Option<i64> {
    let found = CLOCK.captures(text.trim())?;
    let number = |index: usize| found.get(index).map_or(0, |m| m.as_str().parse::<i64>().unwrap_or(0));
    let (minutes, seconds) = (number(2), number(3));
    if minutes >= 60 || seconds >= 60 {
        return None;
    }
    let fraction = found.get(4).map_or(0, |m| format!("{:0<3}", m.as_str()).parse::<i64>().unwrap_or(0));
    Some(((number(1) * 60 + minutes) * 60 + seconds) * 1000 + fraction)
}

fn timing(line: &str) -> Option<(i64, i64)> {
    let (start, end) = line.split_once("-->")?;
    Some((clock_ms(start.split_whitespace().next()?)?, clock_ms(end.split_whitespace().next()?)?))
}

/// Cues of an SRT or WebVTT text, and how many blocks could not be read.
fn block_cues(text: &str, vtt: bool) -> (Vec<Cue>, usize) {
    let mut text = text.replace("\r\n", "\n").replace('\r', "\n");
    if vtt {
        text = text.trim_start_matches('\u{feff}').to_owned();
        if text.lines().next().is_some_and(|l| l.to_ascii_uppercase().starts_with("WEBVTT")) {
            text = text.split_once('\n').map_or(String::new(), |(_, rest)| rest.to_owned());
        }
    }
    let (mut cues, mut invalid) = (Vec::new(), 0);
    for block in BLANK_LINE.split(text.trim_matches('\n')) {
        let lines: Vec<&str> = block.lines().collect();
        let Some(first) = lines.first().map(|l| l.trim()).filter(|l| !l.is_empty()) else {
            continue;
        };
        if vtt && ["NOTE", "STYLE", "REGION"].iter().any(|k| first.starts_with(k)) {
            continue;
        }
        let Some(at) = lines.iter().position(|l| l.contains("-->")) else {
            invalid += 1;
            continue;
        };
        match timing(lines[at]) {
            Some((start_ms, end_ms)) => {
                cues.push(Cue { start_ms, end_ms, text: lines[at + 1..].join("\n").trim().to_owned() })
            }
            None => invalid += 1,
        }
    }
    (cues, invalid)
}

fn ass_text(text: &str) -> String {
    let mut out = String::new();
    let (mut rest, mut drawing) = (text, false);
    while let Some(found) = ASS_OVERRIDE.find(rest) {
        if !drawing {
            out.push_str(&rest[..found.start()]);
        }
        if ASS_DRAW_ON.is_match(found.as_str()) {
            drawing = true;
        } else if found.as_str().contains("\\p0") {
            drawing = false;
        }
        rest = &rest[found.end()..];
    }
    if !drawing {
        out.push_str(rest);
    }
    clean_caption(&out.replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " "), true)
}

fn ass_cues(text: &str) -> (Vec<Cue>, usize) {
    let mut format: Vec<String> =
        ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            .map(str::to_owned)
            .to_vec();
    let (mut cues, mut invalid, mut in_events) = (Vec::<Cue>::new(), 0, false);
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_events = line.eq_ignore_ascii_case("[events]");
        } else if !in_events {
            continue;
        } else if let Some(fields) = line.strip_prefix("Format:") {
            format = fields.split(',').map(|f| f.trim().to_lowercase()).collect();
        } else if let Some(fields) = line.strip_prefix("Dialogue:") {
            let fields: Vec<&str> = fields.splitn(format.len(), ',').collect();
            let field = |name: &str| format.iter().position(|f| f == name).and_then(|i| fields.get(i)).copied();
            let times = field("start").and_then(clock_ms).zip(field("end").and_then(clock_ms));
            match (times, field("text")) {
                (Some((start_ms, end_ms)), Some(text)) => cues.push(Cue { start_ms, end_ms, text: ass_text(text) }),
                _ => invalid += 1,
            }
        }
    }
    cues.sort_by_key(|c| (c.start_ms, c.end_ms));
    let mut merged: Vec<Cue> = Vec::new();
    for cue in cues {
        match merged.last_mut() {
            Some(last) if last.start_ms == cue.start_ms && last.end_ms == cue.end_ms => {
                if !last.text.lines().any(|l| l == cue.text) {
                    last.text = format!("{}\n{}", last.text, cue.text);
                }
            }
            _ => merged.push(cue),
        }
    }
    (merged, invalid)
}

fn decode_entities(text: &str) -> String {
    text.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

/// A subtitle file's text as a transcript. `extension` is `srt`, `vtt`,
/// `ass` or `ssa`; `duration_ms` cuts cues to the media's length when known.
pub fn import_subtitles(
    text: &str,
    extension: &str,
    duration_ms: Option<i64>,
) -> Result<ImportedSubtitles, &'static str> {
    let (cues, invalid) = match extension {
        "srt" => block_cues(text, false),
        "vtt" => block_cues(text, true),
        "ass" | "ssa" => ass_cues(text),
        _ => return Err("subtitle_format_unsupported"),
    };
    let mut ignored = invalid;
    let mut segments = Vec::new();
    let mut speakers: Vec<Speaker> = Vec::new();
    for (index, cue) in cues.iter().enumerate() {
        let voice = VOICE.captures(&cue.text).map(|found| found[1].trim().to_owned());
        let text = clean_caption(&decode_entities(&TAG.replace_all(&cue.text, "")), true);
        let mut end_ms = cue.end_ms;
        if let Some(duration) = duration_ms.filter(|d| *d > 0) {
            if cue.start_ms >= duration {
                ignored += 1;
                continue;
            }
            end_ms = end_ms.min(duration);
        }
        if text.is_empty() || end_ms <= cue.start_ms {
            ignored += 1;
            continue;
        }
        let speaker = voice.map(|name| {
            let at = speakers.iter().position(|s| s.name == name).unwrap_or_else(|| {
                speakers.push(Speaker { id: format!("subtitle-speaker-{}", speakers.len() + 1), name });
                speakers.len() - 1
            });
            speakers[at].id.clone()
        });
        segments.push(Segment {
            id: format!("subtitle-cue-{}", index + 1),
            start_ms: cue.start_ms,
            end_ms,
            text: text.trim().to_owned(),
            speaker,
            preserve_boundary_before: true,
            ..Segment::default()
        });
    }
    if segments.is_empty() {
        return Err("subtitle_no_valid_cues");
    }
    Ok(ImportedSubtitles {
        document: Document { tokens: Vec::new(), segments, speakers, updated_at: now_iso() },
        ignored,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cues_after_several_blank_lines_are_kept() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n \n\n3\n00:00:05,000 --> 00:00:06,000\nThree\n";
        let imported = import_subtitles(srt, "srt", None).unwrap();
        let texts: Vec<&str> = imported.document.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["One", "Two", "Three"]);
    }

    #[test]
    fn srt_cues_become_segments_and_bad_blocks_are_counted() {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello [laughs]\nthere\n\n2\nnonsense\n\n3\n00:00:03,000 --> 00:00:03,000\nzero\n";
        let imported = import_subtitles(srt, "srt", None).unwrap();
        assert_eq!(imported.document.segments.len(), 1);
        assert_eq!(imported.document.segments[0].text, "Hello\nthere");
        assert_eq!(imported.document.segments[0].id, "subtitle-cue-1");
        assert!(imported.document.segments[0].preserve_boundary_before);
        assert_eq!(imported.ignored, 2);
    }

    #[test]
    fn vtt_voices_name_speakers_and_notes_are_skipped() {
        let vtt = "WEBVTT\n\nNOTE made by hand\n\nintro\n00:01.000 --> 00:02.000 align:start\n<v Ann>Hi &amp; <i>welcome</i>\n\n00:03.000 --> 00:09.000\n<v Bob>Thanks\n";
        let imported = import_subtitles(vtt, "vtt", Some(5000)).unwrap();
        let segments = &imported.document.segments;
        assert_eq!(segments[0].text, "Hi & welcome");
        assert_eq!(imported.document.speaker_name(segments[1].speaker.as_deref()), "Bob");
        assert_eq!(segments[1].end_ms, 5000);
    }

    #[test]
    fn ass_dialogue_drops_overrides_and_merges_simultaneous_lines() {
        let ass = "[Script Info]\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.50,0:00:02.00,Default,,0,0,0,,{\\an8}Top, line\\Nsecond\nDialogue: 0,0:00:01.50,0:00:02.00,Default,,0,0,0,,Other\nDialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\p1}m 0 0 l 1 1{\\p0}";
        let imported = import_subtitles(ass, "ass", None).unwrap();
        assert_eq!(imported.document.segments.len(), 1);
        assert_eq!(imported.document.segments[0].start_ms, 1500);
        assert_eq!(imported.document.segments[0].text, "Top, line\nsecond\nOther");
        assert_eq!(imported.ignored, 1);
    }

    #[test]
    fn subtitles_pair_by_name_and_language_suffix() {
        assert!(pairs_with("/a/Talk.srt", "/a/talk.mp4"));
        assert!(pairs_with("/a/talk.zh-Hans.ass", "/a/talk.mp4"));
        assert!(!pairs_with("/a/talk.final.srt", "/a/talk.mp4"));
        assert!(!pairs_with("/b/talk.srt", "/a/talk.mp4"));
        assert!(is_media("x.MP3") && is_subtitle("x.vtt") && !is_media("x.txt"));
    }
}
