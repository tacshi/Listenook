use std::{ops::Range, sync::LazyLock};

use regex::Regex;
use serde_json::Value;

use crate::models::{Document, Segment, Speaker, Token, now_iso};

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
        highlights: Vec::new(),
        skipped: false,
        to_review: false,
    })
}

/// Whether `next` carries on a word that a full stop in `previous` sits inside, as in `7` `.`
/// `6`: it follows straight on, with no space, in a digit or small letter.
fn carries_on(previous: &str, next: &str) -> bool {
    previous.trim_end().ends_with('.') && next.chars().next().is_some_and(|c| c.is_ascii_digit() || c.is_lowercase())
}

fn plain_segments(tokens: &[Token]) -> Vec<Segment> {
    let mut segments = Vec::new();
    let mut current: Vec<&Token> = Vec::new();
    let mut ended = false;
    for token in tokens {
        if let Some(previous) = current.last()
            && !punctuation_only(&token.text)
        {
            let speaker_changed = matches!((&previous.speaker, &token.speaker), (Some(a), Some(b)) if a != b);
            let paused = token.start_ms > 0 && previous.end_ms > 0 && token.start_ms - previous.end_ms > PAUSE_MS;
            if speaker_changed || paused || (ended && !carries_on(&previous.text, &token.text)) {
                push_sentence(&mut segments, &current);
                current.clear();
            }
        }
        ended = ends_sentence(&token.text) || (ended && punctuation_only(&token.text));
        current.push(token);
    }
    push_sentence(&mut segments, &current);
    segments
}

/// A sentence wider than this (see [`width`]) is too long to repeat after in one go, so it is
/// cut into clauses.
pub const LONG_SENTENCE: usize = 100;
/// The narrowest clause a long sentence is cut into, so `I mean,` is never one on its own.
const SHORTEST_CLAUSE: usize = 20;
/// Words a clause can start with when there is no comma to cut a long sentence at.
const JOINING_WORDS: [&str; 8] = ["and", "but", "because", "which", "while", "although", "though", "whereas"];

/// How much room `text` takes: two for a wide (CJK) character, one for any other.
fn width(text: &str) -> usize {
    text.chars().map(|c| if c.is_alphanumeric() && !is_spaced_letter(c) { 2 } else { 1 }).sum()
}

/// The word `tokens[at]` is part of, lowercased and without its punctuation; a word starts at
/// a token that starts with a space.
fn word_at(tokens: &[&Token], at: usize) -> String {
    let start = (0..=at).rev().find(|&index| tokens[index].text.starts_with(char::is_whitespace)).unwrap_or(0);
    let end = (at + 1..tokens.len()).find(|&index| tokens[index].text.starts_with(char::is_whitespace));
    tokens[start..end.unwrap_or(tokens.len())]
        .iter()
        .flat_map(|token| token.text.chars())
        .filter(|c| c.is_alphanumeric() || *c == '\'')
        .flat_map(char::to_lowercase)
        .collect()
}

/// How good a place it is to cut a long sentence after `tokens[at]`, if it is one at all: after
/// a semicolon or colon, then a comma (but not inside `1,500` or `very, very`), then before a
/// word like `and` or `because`.
fn clause_break(tokens: &[&Token], at: usize) -> Option<f64> {
    let (here, next) = (&tokens[at].text, &tokens[at + 1].text);
    let mark = here.trim_end().chars().last()?;
    if matches!(mark, '；' | '：') {
        return Some(2.5);
    }
    if matches!(mark, '，' | '、') {
        return Some(2.0);
    }
    if !next.starts_with(char::is_whitespace) {
        return None;
    }
    let after = word_at(tokens, at + 1);
    match mark {
        ';' | ':' => Some(2.5),
        ',' if word_at(tokens, at) != after => Some(2.0),
        ',' => None,
        _ if JOINING_WORDS.contains(&after.as_str()) => Some(1.0),
        _ => None,
    }
}

/// Where to cut a sentence's tokens so no clause is wider than [`LONG_SENTENCE`] where that can
/// be helped: at the strongest break, nearest the middle and in a pause, again and again.
fn clauses(tokens: &[&Token], span: Range<usize>, out: &mut Vec<Range<usize>>) {
    let total: usize = tokens[span.clone()].iter().map(|token| width(&token.text)).sum();
    if total <= LONG_SENTENCE || span.len() < 2 {
        out.push(span);
        return;
    }
    let mut best: Option<(f64, usize)> = None;
    let mut left = 0;
    for at in span.start..span.end - 1 {
        left += width(&tokens[at].text);
        let right = total - left;
        if left < SHORTEST_CLAUSE || right < SHORTEST_CLAUSE {
            continue;
        }
        let Some(strength) = clause_break(&tokens[span.clone()], at - span.start) else {
            continue;
        };
        let pause = (tokens[at + 1].start_ms - tokens[at].end_ms).clamp(0, 1200) as f64 / 400.0;
        let uneven = 3.0 * left.abs_diff(right) as f64 / total as f64;
        let score = strength + pause - uneven;
        if best.is_none_or(|(most, _)| score > most) {
            best = Some((score, at));
        }
    }
    match best {
        Some((_, at)) => {
            clauses(tokens, span.start..at + 1, out);
            clauses(tokens, at + 1..span.end, out);
        }
        None => out.push(span),
    }
}

/// Adds a sentence, cut into clauses if it is too long to practise ([`LONG_SENTENCE`]); the
/// clauses stay apart when the transcript is normalized.
fn push_sentence(segments: &mut Vec<Segment>, tokens: &[&Token]) {
    let mut spans = Vec::new();
    clauses(tokens, 0..tokens.len(), &mut spans);
    for (index, span) in spans.into_iter().enumerate() {
        if let Some(segment) = segment_of(&tokens[span]) {
            segments.push(Segment { preserve_boundary_before: index > 0, ..segment });
        }
    }
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

/// Whether `c` is a letter or digit of a script that puts spaces between words (Latin with its
/// accents, Cyrillic, Greek, Hangul, Arabic and the like), not of one written without them
/// (Chinese, Japanese, Thai, Lao, Khmer, Myanmar).
pub(crate) fn is_spaced_letter(c: char) -> bool {
    c.is_alphanumeric()
        && !matches!(c as u32,
            0x0E00..=0x0EFF // Thai, Lao
            | 0x1000..=0x109F // Myanmar
            | 0x1780..=0x17FF // Khmer
            | 0x2E80..=0x9FFF // CJK radicals and symbols, kana, CJK ideographs
            | 0xF900..=0xFAFF // CJK compatibility ideographs
            | 0xFF00..=0xFFEF // fullwidth and halfwidth forms
            | 0x20000..=0x3FFFF) // CJK ideographs beyond the basic plane
}

fn join_text(left: &str, right: &str) -> String {
    let (left, right) = (left.trim_end(), right.trim_start());
    let spaced = left.chars().last().is_some_and(|c| is_spaced_letter(c) || matches!(c, ',' | ';' | ':'))
        && right.chars().next().is_some_and(is_spaced_letter)
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

/// Where a space belongs that a transcript left out, as char offsets into `text` (the space
/// goes before the char there): after a comma, semicolon, colon, question or exclamation
/// mark between two words (`money,right`), and after a full stop between a lowercase letter
/// and a capital (`end.Next`). Numbers (`1,500`, `10:30`, `3.5`), abbreviations (`U.S.`) and
/// scripts written without spaces are left as they are.
pub fn missing_spaces(text: &str) -> Vec<u32> {
    let latin = |c: char| c.is_alphabetic() && (c.is_ascii() || ('\u{00C0}'..='\u{024F}').contains(&c));
    let chars: Vec<char> = text.chars().collect();
    chars
        .windows(3)
        .enumerate()
        .filter(|(_, three)| {
            let [before, mark, after] = [three[0], three[1], three[2]];
            match mark {
                ',' | ';' | ':' | '?' | '!' => latin(before) && latin(after),
                '.' => latin(before) && before.is_lowercase() && latin(after) && after.is_uppercase(),
                _ => false,
            }
        })
        .map(|(at, _)| at as u32 + 2)
        .collect()
}

/// Puts in the spaces a transcript left out ([`missing_spaces`]), moving highlights after
/// each along; whether any went in. Some providers send a word without its space.
pub fn tidy_spacing(document: &mut Document) -> bool {
    let mut changed = false;
    for segment in &mut document.segments {
        let at = missing_spaces(&segment.text);
        if at.is_empty() {
            continue;
        }
        let mut text = String::with_capacity(segment.text.len() + at.len());
        for (index, c) in segment.text.chars().enumerate() {
            if at.contains(&(index as u32)) {
                text.push(' ');
            }
            text.push(c);
        }
        let before = |offset: u32, inclusive: bool| {
            at.iter().filter(|&&space| if inclusive { space <= offset } else { space < offset }).count() as u32
        };
        for highlight in &mut segment.highlights {
            highlight.start += before(highlight.start, true);
            highlight.end += before(highlight.end, false);
        }
        segment.text = text;
        changed = true;
    }
    changed
}

pub fn normalize_segments(document: &mut Document) {
    tidy_spacing(document);
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

    #[test]
    fn a_space_left_out_after_punctuation_goes_back_in() {
        let tidied = |text: &str| {
            let segment = Segment { text: text.into(), ..Segment::default() };
            let mut document = Document { segments: vec![segment], ..Document::default() };
            tidy_spacing(&mut document);
            document.segments.remove(0).text
        };
        assert_eq!(tidied("It's too scary to lose money,right?"), "It's too scary to lose money, right?");
        assert_eq!(tidied("Really?Yes!Go;now:here"), "Really? Yes! Go; now: here");
        assert_eq!(tidied("That's the end.Next one."), "That's the end. Next one.");
        for kept in ["1,500 people at 10:30", "Pi is 3.14", "the U.S.A. and Mr. Smith", "e.g. this", "你好,世界"] {
            assert_eq!(tidied(kept), kept);
        }
    }

    #[test]
    fn highlights_move_with_the_spaces_put_in() {
        let text = "lose money,right now";
        let money = crate::models::Highlight { start: 5, end: 11 };
        let right = crate::models::Highlight { start: 11, end: 16 };
        let segment = Segment { text: text.into(), highlights: vec![money, right], ..Segment::default() };
        let mut document = Document { segments: vec![segment], ..Document::default() };
        assert!(tidy_spacing(&mut document));
        let segment = &document.segments[0];
        let words: Vec<&str> = segment.highlights.iter().map(|h| crate::highlights::slice(&segment.text, *h)).collect();
        assert_eq!(words, ["money,", "right"]);
        assert!(!tidy_spacing(&mut document), "once is enough");
    }

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

    fn texts_of(pieces: &[&str]) -> Vec<String> {
        let tokens: Vec<Value> = pieces
            .iter()
            .enumerate()
            .map(|(index, text)| token(text, index as i64 * 200, index as i64 * 200 + 150, "1"))
            .collect();
        parse_soniox(&json!({ "tokens": tokens }), None).segments.into_iter().map(|s| s.text).collect()
    }

    fn spoken(text: &str) -> Vec<String> {
        text.split(' ').map(|word| format!(" {word}")).collect()
    }

    #[test]
    fn a_full_stop_inside_a_number_does_not_end_the_sentence() {
        let pieces = [" Both", " screens", " are", " 7", ".", "6", " inches", " wide.", " That's", " big."];
        assert_eq!(texts_of(&pieces), ["Both screens are 7.6 inches wide.", "That's big."]);
        assert_eq!(texts_of(&[" It", " is", " 7", ".", " Six", " more."]), ["It is 7.", "Six more."]);
    }

    #[test]
    fn a_sentence_too_long_to_practise_is_cut_into_clauses() {
        let long = "I mean, when you have something that is almost the size of an iPad mini, it is fantastic to have \
                    that in your pocket, but also being able to take it down to this very, very tiny outer screen.";
        let words = spoken(long);
        let pieces: Vec<&str> = words.iter().map(String::as_str).collect();
        assert_eq!(
            texts_of(&pieces),
            [
                "I mean, when you have something that is almost the size of an iPad mini,",
                "it is fantastic to have that in your pocket,",
                "but also being able to take it down to this very, very tiny outer screen.",
            ]
        );
        let words =
            spoken("We tried this and we liked it so much that we kept going back to it for weeks and weeks on end.");
        let pieces: Vec<&str> = words.iter().map(String::as_str).collect();
        assert_eq!(texts_of(&pieces).len(), 1, "short enough to keep whole");
        let words = spoken(
            "We tried the new phone for a whole month in the city and we liked it so much that we kept on going back \
             to it every single day for weeks on end without stopping once.",
        );
        let pieces: Vec<&str> = words.iter().map(String::as_str).collect();
        assert_eq!(
            texts_of(&pieces),
            [
                "We tried the new phone for a whole month in the city",
                "and we liked it so much that we kept on going back to it every single day for weeks on end without \
                 stopping once."
            ],
            "with no comma, before a joining word"
        );
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
