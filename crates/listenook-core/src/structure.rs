use crate::models::{Document, Segment};

fn join(left: &str, right: &str) -> String {
    let (left, right) = (left.trim_end(), right.trim_start());
    let spaced = left.chars().last().is_some_and(|c| !c.is_whitespace() && c.is_ascii())
        && right.chars().next().is_some_and(|c| c.is_ascii_alphanumeric());
    if spaced { format!("{left} {right}") } else { format!("{left}{right}") }
}

pub fn can_merge(document: &Document, index: usize) -> bool {
    index + 1 < document.segments.len()
}

pub fn merge_with_next(document: &mut Document, index: usize) -> bool {
    if !can_merge(document, index) {
        return false;
    }
    let next = document.segments.remove(index + 1);
    let kept = &mut document.segments[index];
    kept.text = join(&kept.text, &next.text);
    kept.translated_text = match (kept.translated_text.take(), next.translated_text) {
        (Some(a), Some(b)) => Some(join(&a, &b)),
        (a, b) => a.or(b),
    };
    kept.end_ms = kept.end_ms.max(next.end_ms);
    if kept.language.is_none() {
        kept.language = next.language;
    }
    let kept_id = kept.id.clone();
    for token in &mut document.tokens {
        if token.segment_id.as_deref() == Some(next.id.as_str()) {
            token.segment_id = Some(kept_id.clone());
        }
    }
    true
}

pub fn remove(document: &mut Document, index: usize) -> bool {
    if index >= document.segments.len() {
        return false;
    }
    let gone = document.segments.remove(index);
    document.tokens.retain(|token| token.segment_id.as_deref() != Some(gone.id.as_str()));
    true
}

pub fn split_at(document: &mut Document, index: usize, at: usize) -> bool {
    let Some(segment) = document.segments.get(index).cloned() else {
        return false;
    };
    let total = segment.text.chars().count();
    let byte = segment.text.char_indices().nth(at).map_or(segment.text.len(), |(byte, _)| byte);
    let (first, second) = (segment.text[..byte].trim_end(), segment.text[byte..].trim_start());
    if first.is_empty() || second.is_empty() {
        return false;
    }
    let share = at as f64 / total.max(1) as f64;
    let by_length = segment.start_ms + ((segment.end_ms - segment.start_ms) as f64 * share).round() as i64;
    let letters = |text: &str| text.chars().filter(|c| !c.is_whitespace()).count();
    let before = letters(first);
    let mut seen = 0;
    let by_words = document
        .tokens
        .iter()
        .filter(|token| token.start_ms >= segment.start_ms && token.end_ms <= segment.end_ms && token.end_ms > 0)
        .find(|token| {
            seen += letters(&token.text);
            seen > before
        })
        .map(|token| token.start_ms);
    let cut_ms = by_words.unwrap_or(by_length).clamp(segment.start_ms, segment.end_ms);
    let mut suffix = 2;
    let mut id = format!("{}-{suffix}", segment.id);
    while document.segments.iter().any(|other| other.id == id) {
        suffix += 1;
        id = format!("{}-{suffix}", segment.id);
    }
    let tail = Segment {
        id,
        start_ms: cut_ms,
        end_ms: segment.end_ms,
        text: second.to_owned(),
        translated_text: None,
        ..segment.clone()
    };
    for token in &mut document.tokens {
        if token.segment_id.as_deref() == Some(segment.id.as_str()) && token.start_ms >= cut_ms {
            token.segment_id = Some(tail.id.clone());
        }
    }
    let head = &mut document.segments[index];
    head.text = first.to_owned();
    head.end_ms = cut_ms;
    document.segments.insert(index + 1, tail);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Token;

    #[test]
    fn a_cut_between_timed_words_falls_at_the_next_word_and_takes_its_words() {
        let words = ["a", "b", "c", "d", "e", "f", "g", "h"];
        let mut document = Document {
            segments: vec![Segment {
                id: "s".into(),
                start_ms: 0,
                end_ms: 8000,
                text: words.join(" "),
                ..Segment::default()
            }],
            tokens: words
                .iter()
                .enumerate()
                .map(|(index, word)| Token {
                    text: (*word).into(),
                    start_ms: index as i64 * 1000,
                    end_ms: index as i64 * 1000 + 900,
                    segment_id: Some("s".into()),
                    ..Token::default()
                })
                .collect(),
            ..Document::default()
        };
        assert!(split_at(&mut document, 0, 7));
        assert_eq!((document.segments[0].end_ms, document.segments[1].start_ms), (4000, 4000));
        let tail = document.segments[1].id.clone();
        let owners: Vec<bool> = document.tokens.iter().map(|t| t.segment_id.as_deref() == Some(&tail)).collect();
        assert_eq!(owners, [false, false, false, false, true, true, true, true]);
    }

    fn document() -> Document {
        let segment = |id: &str, start, end, text: &str, translated: Option<&str>| Segment {
            id: id.into(),
            start_ms: start,
            end_ms: end,
            text: text.into(),
            translated_text: translated.map(str::to_owned),
            speaker: Some("1".into()),
            ..Segment::default()
        };
        Document {
            segments: vec![
                segment("a", 0, 2000, "Hello there", Some("你好")),
                segment("b", 2000, 4000, "my friend.", Some("我的朋友。")),
            ],
            ..Document::default()
        }
    }

    #[test]
    fn merging_joins_text_translation_and_time() {
        let mut document = document();
        assert!(merge_with_next(&mut document, 0));
        assert_eq!(document.segments.len(), 1);
        assert_eq!(document.segments[0].text, "Hello there my friend.");
        assert_eq!(document.segments[0].translated_text.as_deref(), Some("你好我的朋友。"));
        assert_eq!((document.segments[0].start_ms, document.segments[0].end_ms), (0, 4000));
        assert!(!merge_with_next(&mut document, 0), "the last sentence has nothing after it");
    }

    #[test]
    fn removing_drops_the_sentence_and_its_words() {
        let mut document = document();
        document.tokens = vec![
            Token { text: "Hello".into(), segment_id: Some("a".into()), ..Token::default() },
            Token { text: "my".into(), segment_id: Some("b".into()), ..Token::default() },
        ];
        assert!(remove(&mut document, 0));
        assert_eq!(document.segments.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["b"]);
        assert_eq!(document.tokens.len(), 1);
        assert_eq!(document.tokens[0].text, "my");
        assert!(!remove(&mut document, 1));
    }

    #[test]
    fn splitting_cuts_text_and_time_and_refuses_the_ends() {
        let mut document = document();
        assert!(!split_at(&mut document, 0, 0));
        assert!(!split_at(&mut document, 0, 11));
        assert!(split_at(&mut document, 0, 5));
        let (head, tail) = (&document.segments[0], &document.segments[1]);
        assert_eq!((head.text.as_str(), tail.text.as_str()), ("Hello", "there"));
        assert_eq!((head.end_ms, tail.start_ms, tail.end_ms), (909, 909, 2000));
        assert_eq!(tail.id, "a-2");
        assert_eq!(tail.translated_text, None);
        assert_eq!(document.segments.len(), 3);
    }

    #[test]
    fn a_split_follows_word_times_when_there_are_words() {
        let mut document = document();
        document.tokens = vec![
            Token { text: "Hello".into(), start_ms: 0, end_ms: 400, ..Token::default() },
            Token { text: " there".into(), start_ms: 1500, end_ms: 1900, ..Token::default() },
        ];
        assert!(split_at(&mut document, 0, 5));
        assert_eq!(document.segments[1].start_ms, 1500);
    }
}
