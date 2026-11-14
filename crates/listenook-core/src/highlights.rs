use std::ops::Range;

use crate::models::{Document, Highlight};

fn char_len(text: &str) -> u32 {
    text.chars().count() as u32
}

fn byte_at(text: &str, char_offset: u32) -> usize {
    text.char_indices().nth(char_offset as usize).map_or(text.len(), |(byte, _)| byte)
}

fn char_at_byte(text: &str, byte: usize) -> u32 {
    char_len(&text[..byte])
}

fn char_at_utf16(text: &str, utf16: u32) -> u32 {
    let mut units = 0;
    for (index, c) in text.chars().enumerate() {
        if units >= utf16 {
            return index as u32;
        }
        units += c.len_utf16() as u32;
    }
    char_len(text)
}

pub fn slice(text: &str, highlight: Highlight) -> &str {
    &text[byte_at(text, highlight.start)..byte_at(text, highlight.end)]
}

fn overlaps(highlight: &Highlight, range: &Range<u32>) -> bool {
    highlight.start < range.end && highlight.end > range.start
}

pub fn overlapping(highlights: &[Highlight], range: Range<u32>) -> bool {
    highlights.iter().any(|h| overlaps(h, &range))
}

pub fn add(highlights: &mut Vec<Highlight>, range: Range<u32>) {
    let (mut start, mut end) = (range.start, range.end);
    if start >= end {
        return;
    }
    highlights.retain(|h| {
        if h.end < start || h.start > end {
            return true;
        }
        start = start.min(h.start);
        end = end.max(h.end);
        false
    });
    highlights.push(Highlight { start, end });
    highlights.sort_by_key(|h| h.start);
}

pub fn remove(highlights: &mut Vec<Highlight>, range: Range<u32>) {
    highlights.retain(|h| !overlaps(h, &range));
}

fn joins_word(c: char) -> bool {
    (c.is_alphanumeric() || c == '\'' || c == '’' || c == '-') && (c as u32) < 0x2E80
}

fn snap(text: &str, range: Range<u32>) -> Range<u32> {
    let chars: Vec<char> = text.chars().collect();
    let (mut start, mut end) = (range.start as usize, range.end as usize);
    while start > 0 && start < chars.len() && joins_word(chars[start]) && joins_word(chars[start - 1]) {
        start -= 1;
    }
    while end > 0 && end < chars.len() && joins_word(chars[end - 1]) && joins_word(chars[end]) {
        end += 1;
    }
    while start < end && chars[start].is_whitespace() {
        start += 1;
    }
    while end > start && chars[end - 1].is_whitespace() {
        end -= 1;
    }
    start as u32..end as u32
}

pub fn locate(text: &str, selected: &str, utf16_hint: Option<u32>) -> Option<Range<u32>> {
    let wanted = selected.trim();
    if wanted.is_empty() {
        return None;
    }
    let hint = utf16_hint.map(|hint| char_at_utf16(text, hint));
    let start = text
        .match_indices(wanted)
        .map(|(byte, _)| char_at_byte(text, byte))
        .min_by_key(|start| hint.map_or(0, |hint| start.abs_diff(hint)))?;
    let range = snap(text, start..start + char_len(wanted));
    (range.start < range.end).then_some(range)
}

pub fn runs(text: &str, highlights: &[Highlight]) -> Vec<(String, bool)> {
    let mut out: Vec<(String, bool)> = Vec::new();
    for (index, c) in text.chars().enumerate() {
        let marked = highlights.iter().any(|h| (h.start..h.end).contains(&(index as u32)));
        match out.last_mut() {
            Some((run, was)) if *was == marked => run.push(c),
            _ => out.push((c.to_string(), marked)),
        }
    }
    out
}

pub fn word_marks(text: &str, words: &[&str], highlights: &[Highlight]) -> Vec<bool> {
    let mut cursor = 0;
    words
        .iter()
        .map(|word| {
            let word = word.trim();
            if word.is_empty() {
                return false;
            }
            let Some(found) = text[cursor..].find(word) else {
                return false;
            };
            let byte = cursor + found;
            cursor = byte + word.len();
            let start = char_at_byte(text, byte);
            overlapping(highlights, start..start + char_len(word))
        })
        .collect()
}

pub fn reanchor(old_text: &str, new_text: &str, highlights: &[Highlight]) -> Vec<Highlight> {
    let mut out = Vec::new();
    for highlight in highlights {
        let piece = slice(old_text, *highlight);
        if piece.trim().is_empty() {
            continue;
        }
        let nearest = new_text
            .match_indices(piece)
            .map(|(byte, _)| char_at_byte(new_text, byte))
            .min_by_key(|start| start.abs_diff(highlight.start));
        if let Some(start) = nearest {
            add(&mut out, start..start + char_len(piece));
        }
    }
    out
}

pub fn shifted(highlights: &[Highlight], from: u32, to: u32, by: i64) -> Vec<Highlight> {
    highlights
        .iter()
        .filter_map(|h| {
            let (start, end) = (h.start.max(from), h.end.min(to));
            (start < end).then(|| Highlight {
                start: (i64::from(start) + by).max(0) as u32,
                end: (i64::from(end) + by).max(0) as u32,
            })
        })
        .collect()
}

pub fn count(document: &Document) -> usize {
    document.segments.iter().map(|s| s.highlights.len()).sum()
}

#[derive(Debug, Clone, PartialEq)]
pub struct HighlightContext {
    pub segment_id: String,
    pub selected: String,
    pub lines: Vec<(String, String)>,
}

impl HighlightContext {
    pub fn key(&self) -> String {
        format!("{}:{}", self.segment_id, self.selected.to_lowercase())
    }
}

pub fn unseen(document: &Document, seen: &[String]) -> usize {
    contexts(document).iter().filter(|c| !seen.contains(&c.key())).count()
}

pub fn contexts(document: &Document) -> Vec<HighlightContext> {
    let segments = &document.segments;
    let mut out = Vec::new();
    for (index, segment) in segments.iter().enumerate() {
        for highlight in &segment.highlights {
            let selected = slice(&segment.text, *highlight).trim().to_owned();
            if selected.is_empty() {
                continue;
            }
            let lines = [index.checked_sub(1), Some(index), Some(index + 1)]
                .into_iter()
                .flatten()
                .filter_map(|at| segments.get(at))
                .filter(|s| !s.text.trim().is_empty())
                .map(|s| (s.id.clone(), s.text.trim().to_owned()))
                .collect();
            out.push(HighlightContext { segment_id: segment.id.clone(), selected, lines });
        }
    }
    out
}

fn primary(code: &str) -> String {
    code.split(['-', '_']).next().unwrap_or("").to_lowercase()
}

fn guessed_language(document: &Document) -> Option<String> {
    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for language in document.segments.iter().filter_map(|s| s.language.as_deref()) {
        *counts.entry(primary(language)).or_default() += 1;
    }
    if let Some((language, _)) = counts.into_iter().max_by_key(|(_, n)| *n) {
        return Some(language);
    }
    let (mut letters, mut han, mut kana, mut hangul) = (0usize, 0usize, 0usize, 0usize);
    for c in document.segments.iter().flat_map(|s| s.text.chars()).filter(|c| c.is_alphabetic()) {
        letters += 1;
        match c as u32 {
            0x3040..=0x30FF => kana += 1,
            0xAC00..=0xD7AF => hangul += 1,
            0x4E00..=0x9FFF => han += 1,
            _ => {}
        }
    }
    let share = |n: usize| letters > 0 && n * 5 > letters;
    if share(kana) {
        Some("ja".into())
    } else if share(hangul) {
        Some("ko".into())
    } else if share(han) {
        Some("zh".into())
    } else {
        None
    }
}

fn is_short(text: &str) -> bool {
    let words = text.split_whitespace().count();
    let wide = text.chars().filter(|c| (*c as u32) >= 0x2E80).count();
    if wide > 0 { wide <= 8 && words <= 2 } else { words <= 4 }
}

pub fn looks_like_learning(document: &Document, output_language: &str) -> bool {
    let picked: Vec<&str> =
        document.segments.iter().flat_map(|s| s.highlights.iter().map(|h| slice(&s.text, *h))).collect();
    if picked.is_empty() {
        return false;
    }
    let short = picked.iter().filter(|text| is_short(text)).count();
    let foreign = match guessed_language(document) {
        Some(language) => language != primary(output_language),
        None => primary(output_language) != "en",
    };
    foreign && short * 2 >= picked.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Segment;

    fn h(start: u32, end: u32) -> Highlight {
        Highlight { start, end }
    }

    #[test]
    fn adding_merges_touching_ranges_and_removing_drops_what_it_overlaps() {
        let mut list = vec![h(0, 3), h(10, 12)];
        add(&mut list, 3..5);
        assert_eq!(list, [h(0, 5), h(10, 12)]);
        add(&mut list, 4..11);
        assert_eq!(list, [h(0, 12)]);
        add(&mut list, 20..20);
        assert_eq!(list.len(), 1);
        remove(&mut list, 11..30);
        assert!(list.is_empty());
        assert!(!overlapping(&list, 0..5));
    }

    #[test]
    fn a_selection_is_found_near_its_hint_and_snapped_to_whole_words() {
        let text = "Take it, and take it for granted.";
        assert_eq!(locate(text, "take", Some(13)), Some(13..17));
        assert_eq!(locate(text, "ake it fo", Some(14)), Some(13..24));
        assert_eq!(locate(text, "  granted ", None), Some(25..32));
        assert_eq!(locate(text, "missing", None), None);
        assert_eq!(locate("你好吗朋友", "好吗", Some(1)), Some(1..3));
        assert_eq!(locate("naïve café", "café", Some(6)), Some(6..10));
    }

    #[test]
    fn runs_and_word_marks_follow_the_highlights() {
        let text = "We ship on Friday.";
        let marks = [h(3, 7)];
        assert_eq!(runs(text, &marks), [("We ".into(), false), ("ship".into(), true), (" on Friday.".into(), false)]);
        assert_eq!(word_marks(text, &["We", "ship", "on", "Friday."], &marks), [false, true, false, false]);
        assert_eq!(word_marks(text, &["We", "nope", "ship"], &marks), [false, false, true]);
    }

    #[test]
    fn highlights_follow_their_words_through_an_edit() {
        let old = "We ship on Friday.";
        let new = "Then we ship on Monday.";
        assert_eq!(reanchor(old, new, &[h(3, 7), h(11, 17)]), [h(8, 12)]);
    }

    #[test]
    fn contexts_carry_the_sentence_and_its_neighbours() {
        let segment = |id: &str, text: &str, highlights: Vec<Highlight>| Segment {
            id: id.into(),
            text: text.into(),
            highlights,
            ..Segment::default()
        };
        let document = Document {
            segments: vec![
                segment("a", "First.", vec![]),
                segment("b", "We ship on Friday.", vec![h(3, 7)]),
                segment("c", "Last.", vec![]),
                segment("d", "Never.", vec![]),
            ],
            ..Document::default()
        };
        let found = contexts(&document);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].selected, "ship");
        assert_eq!(found[0].lines.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert_eq!(count(&document), 1);
    }

    #[test]
    fn short_highlights_in_a_foreign_transcript_look_like_learning() {
        let document = |text: &str, language: Option<&str>, highlights: Vec<Highlight>| Document {
            segments: vec![Segment {
                id: "a".into(),
                text: text.into(),
                language: language.map(str::to_owned),
                highlights,
                ..Segment::default()
            }],
            ..Document::default()
        };
        let english = "We will take it for granted that the budget is approved by Friday.";
        assert!(looks_like_learning(&document(english, Some("en"), vec![h(8, 25)]), "zh-Hans"));
        assert!(looks_like_learning(&document(english, None, vec![h(8, 25)]), "zh-Hans"));
        assert!(!looks_like_learning(&document(english, Some("en"), vec![h(8, 25)]), "en"));
        assert!(!looks_like_learning(&document(english, Some("en"), vec![h(0, 66)]), "zh-Hans"));
        assert!(!looks_like_learning(&document(english, Some("en"), vec![]), "zh-Hans"));
        assert!(looks_like_learning(&document("我们周五发布这个版本。", None, vec![h(2, 4)]), "en"));
    }
}
