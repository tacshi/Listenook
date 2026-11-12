//! Provider payloads to transcripts: Soniox tokens become sentences, MOSS
//! segments are taken as they are, and `normalize_segments` joins what a
//! provider split in the middle of a sentence.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use crate::models::{Document, Segment, Speaker, Token, now_iso};

/// A silence longer than this starts a new sentence.
pub const PAUSE_MS: i64 = 1500;

static ENDS_SENTENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"[.!?。！？]["'”’)]?\s*$"#).unwrap());
static PUNCTUATION_ONLY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"^\s*[,.;:!?，。；：！？、…—\-"'“”‘’()\[\]{}]+\s*$"#).unwrap());

fn ends_sentence(text: &str) -> bool {
    ENDS_SENTENCE.is_match(text)
}

fn punctuation_only(text: &str) -> bool {
    PUNCTUATION_ONLY.is_match(text)
}

/// A Soniox transcript payload as a document. `target_language` is the
/// translation asked of Soniox, when one was.
pub fn parse_soniox(payload: &Value, target_language: Option<&str>) -> Document {
    let raw = payload
        .get("tokens")
        .or_else(|| payload.get("transcript").and_then(|t| t.get("tokens")))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let tokens: Vec<Token> = raw
        .into_iter()
        .filter_map(|value| serde_json::from_value::<Token>(value).ok())
        .filter(|token| !token.text.trim().is_empty())
        .collect();
    let translated = target_language.is_some_and(|t| !t.is_empty())
        || tokens.iter().any(|t| matches!(t.translation_status.as_deref(), Some("original" | "translation")));
    let mut segments =
        if translated { translated_segments(&tokens, target_language.unwrap_or("")) } else { plain_segments(&tokens) };
    for (index, segment) in segments.iter_mut().enumerate() {
        segment.id = format!("segment-{}", index + 1);
    }
    let mut ids: Vec<String> = tokens.iter().filter_map(|t| t.speaker.clone()).filter(|s| !s.is_empty()).collect();
    ids.sort();
    ids.dedup();
    let speakers =
        ids.into_iter().enumerate().map(|(index, id)| Speaker { id, name: format!("Speaker {}", index + 1) }).collect();
    let mut document = Document { tokens, segments, speakers, updated_at: now_iso() };
    normalize_segments(&mut document);
    document
}

fn segment_of(tokens: &[&Token]) -> Option<Segment> {
    let first = tokens.first()?;
    let text: String = tokens.iter().map(|t| t.text.as_str()).collect();
    Some(Segment {
        id: String::new(),
        start_ms: first.start_ms,
        end_ms: tokens.last().map_or(first.end_ms, |t| t.end_ms),
        text: text.trim().to_owned(),
        speaker: first.speaker.clone(),
        language: tokens.iter().find_map(|t| t.language.clone()),
        translated_text: None,
        preserve_boundary_before: false,
    })
}

fn plain_segments(tokens: &[Token]) -> Vec<Segment> {
    let mut segments = Vec::new();
    let mut current: Vec<&Token> = Vec::new();
    for token in tokens {
        if let Some(previous) = current.last()
            && !punctuation_only(&token.text)
        {
            let speaker_changed = matches!((&previous.speaker, &token.speaker), (Some(a), Some(b)) if a != b);
            let paused = token.start_ms > 0 && previous.end_ms > 0 && token.start_ms - previous.end_ms > PAUSE_MS;
            if speaker_changed || paused {
                segments.extend(segment_of(&current));
                current.clear();
            }
        }
        current.push(token);
        if ends_sentence(&token.text) {
            segments.extend(segment_of(&current));
            current.clear();
        }
    }
    segments.extend(segment_of(&current));
    segments
}

fn translated_segments(tokens: &[Token], target: &str) -> Vec<Segment> {
    let mut segments = Vec::new();
    let (mut originals, mut translations, mut plain): (Vec<&Token>, Vec<&Token>, Vec<Token>) =
        (Vec::new(), Vec::new(), Vec::new());
    let flush = |originals: &mut Vec<&Token>, translations: &mut Vec<&Token>, segments: &mut Vec<Segment>| {
        if originals.is_empty() {
            translations.clear();
            return;
        }
        let timed: Vec<&Token> = originals.iter().copied().filter(|t| t.start_ms != 0 || t.end_ms != 0).collect();
        let mut segment = segment_of(originals).unwrap_or_default();
        if let (Some(first), Some(last)) = (timed.first(), timed.last()) {
            segment.start_ms = first.start_ms;
            segment.end_ms = last.end_ms;
        }
        let translation: String = translations.iter().map(|t| t.text.as_str()).collect();
        let translation = translation.trim();
        segment.translated_text = if !translation.is_empty() {
            Some(translation.to_owned())
        } else if segment.language.as_deref().is_some_and(|l| l.eq_ignore_ascii_case(target)) {
            Some(segment.text.clone())
        } else {
            None
        };
        segments.push(segment);
        originals.clear();
        translations.clear();
    };
    for token in tokens {
        match token.translation_status.as_deref() {
            Some("original") => {
                segments.extend(plain_segments(&plain));
                plain.clear();
                if !translations.is_empty() {
                    flush(&mut originals, &mut translations, &mut segments);
                }
                originals.push(token);
            }
            Some("translation") => translations.push(token),
            _ => {
                flush(&mut originals, &mut translations, &mut segments);
                plain.push(token.clone());
            }
        }
    }
    flush(&mut originals, &mut translations, &mut segments);
    segments.extend(plain_segments(&plain));
    segments.sort_by_key(|s| s.start_ms);
    for segment in &mut segments {
        if segment.translated_text.is_none()
            && !target.is_empty()
            && segment.language.as_deref().is_some_and(|l| l.eq_ignore_ascii_case(target))
        {
            segment.translated_text = Some(segment.text.clone());
        }
    }
    segments
}

/// A MOSS task payload as a document: its segments in seconds, speakers
/// numbered as they first appear.
pub fn parse_moss(payload: &Value) -> Document {
    let ms = |value: Option<&Value>| -> i64 {
        let seconds = value.and_then(Value::as_f64).unwrap_or(0.0);
        if seconds.is_finite() && seconds > 0.0 { (seconds * 1000.0).round() as i64 } else { 0 }
    };
    let mut segments = Vec::new();
    let mut speakers: Vec<Speaker> = Vec::new();
    for (index, item) in payload.get("segments").and_then(Value::as_array).into_iter().flatten().enumerate() {
        let text = item.get("text").and_then(Value::as_str).unwrap_or("").trim();
        if text.is_empty() {
            continue;
        }
        let speaker = item.get("speaker").and_then(|v| match v {
            Value::String(s) => Some(s.clone()),
            Value::Null => None,
            other => Some(other.to_string()),
        });
        if let Some(id) = &speaker
            && !speakers.iter().any(|s| &s.id == id)
        {
            speakers.push(Speaker { id: id.clone(), name: format!("Speaker {}", speakers.len() + 1) });
        }
        let start_ms = ms(item.get("start"));
        segments.push(Segment {
            id: item
                .get("id")
                .map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_owned))
                .unwrap_or_else(|| format!("moss-{index}")),
            start_ms,
            end_ms: ms(item.get("end")).max(start_ms),
            text: text.to_owned(),
            speaker,
            ..Segment::default()
        });
    }
    if segments.is_empty()
        && let Some(text) = payload.get("text").and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty())
    {
        segments.push(Segment {
            id: "moss-0".into(),
            end_ms: ms(payload.get("duration")),
            text: text.to_owned(),
            ..Segment::default()
        });
    }
    let mut document = Document { tokens: Vec::new(), segments, speakers, updated_at: now_iso() };
    normalize_segments(&mut document);
    document
}

fn join_text(left: &str, right: &str) -> String {
    let (left, right) = (left.trim_end(), right.trim_start());
    let spaced = left.chars().last().is_some_and(|c| c.is_ascii_alphanumeric() || matches!(c, ',' | ';' | ':'))
        && right.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && !punctuation_only(right);
    if spaced { format!("{left} {right}") } else { format!("{left}{right}") }
}

fn join_optional(left: Option<&str>, right: Option<&str>) -> Option<String> {
    match (left.filter(|t| !t.is_empty()), right.filter(|t| !t.is_empty())) {
        (Some(left), Some(right)) => Some(join_text(left, right)),
        (Some(one), None) | (None, Some(one)) => Some(one.to_owned()),
        (None, None) => None,
    }
}

/// Drops empty sentences and joins a piece to the one before it when it is
/// only punctuation, or continues an unfinished sentence of the same speaker
/// without a pause. Imported cues (`preserve_boundary_before`) stay apart.
pub fn normalize_segments(document: &mut Document) {
    document.segments.retain(|s| !s.text.trim().is_empty());
    if document.segments.len() < 2 {
        return;
    }
    let mut merged: Vec<Segment> = Vec::with_capacity(document.segments.len());
    let mut remapped: Vec<(String, String)> = Vec::new();
    for current in std::mem::take(&mut document.segments) {
        let Some(previous) = merged.last_mut() else {
            merged.push(current);
            continue;
        };
        if current.preserve_boundary_before {
            merged.push(current);
            continue;
        }
        let compatible = match (&previous.speaker, &current.speaker) {
            (Some(a), Some(b)) => a == b,
            _ => true,
        };
        let continuous =
            previous.end_ms <= 0 || current.start_ms <= 0 || current.start_ms - previous.end_ms <= PAUSE_MS;
        if punctuation_only(&current.text) || (compatible && continuous && !ends_sentence(&previous.text)) {
            previous.text = join_text(&previous.text, &current.text);
            previous.translated_text =
                join_optional(previous.translated_text.as_deref(), current.translated_text.as_deref());
            previous.end_ms = previous.end_ms.max(current.end_ms);
            if previous.speaker.is_none() {
                previous.speaker = current.speaker.clone();
            }
            if previous.language.is_none() {
                previous.language = current.language.clone();
            }
            remapped.push((current.id, previous.id.clone()));
        } else {
            merged.push(current);
        }
    }
    document.segments = merged;
    for token in &mut document.tokens {
        if let Some(id) = &token.segment_id
            && let Some((_, kept)) = remapped.iter().find(|(gone, _)| gone == id)
        {
            token.segment_id = Some(kept.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn token(text: &str, start: i64, end: i64, speaker: &str) -> Value {
        json!({"text": text, "start_ms": start, "end_ms": end, "speaker": speaker})
    }

    #[test]
    fn tokens_split_on_sentence_ends_speakers_and_pauses() {
        let payload = json!({"tokens": [
            token("Hello", 0, 300, "1"), token(" there.", 300, 600, "1"),
            token(" How", 700, 900, "1"), token(" are", 900, 1000, "1"),
            token(" Fine.", 1100, 1400, "2"),
            token(" Well", 5000, 5200, "2"),
        ]});
        let document = parse_soniox(&payload, None);
        let texts: Vec<&str> = document.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["Hello there.", "How are", "Fine.", "Well"]);
        assert_eq!(document.segments[2].speaker.as_deref(), Some("2"));
        assert_eq!(document.speakers.len(), 2);
        assert_eq!(document.segments[0].id, "segment-1");
    }

    #[test]
    fn soniox_translations_pair_with_their_originals() {
        let payload = json!({"tokens": [
            {"text": "Bonjour.", "start_ms": 10, "end_ms": 500, "language": "fr", "translation_status": "original"},
            {"text": "Hello.", "translation_status": "translation", "language": "en"},
            {"text": "Thanks.", "start_ms": 600, "end_ms": 900, "language": "en", "translation_status": "original"},
        ]});
        let document = parse_soniox(&payload, Some("en"));
        assert_eq!(document.segments.len(), 2);
        assert_eq!(document.segments[0].translated_text.as_deref(), Some("Hello."));
        assert_eq!(document.segments[1].translated_text.as_deref(), Some("Thanks."));
    }

    #[test]
    fn normalizing_joins_an_unfinished_sentence_but_not_an_imported_cue() {
        let segment = |id: &str, start, end, text: &str| Segment {
            id: id.into(),
            start_ms: start,
            end_ms: end,
            text: text.into(),
            ..Segment::default()
        };
        let mut document = Document {
            segments: vec![
                segment("a", 0, 500, "I think"),
                segment("b", 600, 900, "so."),
                segment("c", 1000, 1200, "!"),
                Segment { preserve_boundary_before: true, ..segment("d", 1300, 1500, "next") },
            ],
            ..Document::default()
        };
        normalize_segments(&mut document);
        let texts: Vec<&str> = document.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["I think so.!", "next"]);
        assert_eq!(document.segments[0].end_ms, 1200);
    }

    #[test]
    fn moss_segments_are_seconds_with_speakers_in_order() {
        let payload = json!({"segments": [
            {"start": 0.5, "end": 1.25, "text": " Hi. ", "speaker": "S2"},
            {"start": 2.0, "end": 1.0, "text": "Yes.", "speaker": "S1"},
        ]});
        let document = parse_moss(&payload);
        assert_eq!(document.segments[0].start_ms, 500);
        assert_eq!(document.segments[1].end_ms, 2000);
        assert_eq!(document.speaker_name(Some("S2")), "Speaker 1");
    }
}
