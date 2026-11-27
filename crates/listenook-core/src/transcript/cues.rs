//! Sentences from subtitle cues. A cue times only where it starts and ends, and is often a piece
//! of a sentence; its words are timed by spreading its time over them, and the words of cues in
//! a row are cut into sentences as a transcription's are.

use crate::{
    models::{Document, Segment, Token},
    transcript::parser::{ends_sentence, is_spaced_letter, plain_segments, spaced_apart},
};

/// A file is joined into sentences when at least one cue in this many ends one. Fewer, and it is
/// one written without punctuation (as automatic captions are), whose sentences cannot be found.
const CUES_PER_SENTENCE_END: usize = 6;

/// Gives `document`, as read from a subtitle file (a segment per cue, no words), timed words and
/// its cues joined into sentences. A cue that holds two languages or two speakers stays on its
/// own, as does every cue of a file without punctuation.
pub fn into_sentences(document: &mut Document) {
    let cues = std::mem::take(&mut document.segments);
    let ends = cues.iter().filter(|cue| ends_sentence(&cue.text)).count();
    let punctuated = ends * CUES_PER_SENTENCE_END >= cues.len();
    let (mut segments, mut tokens, mut run) = (Vec::new(), Vec::new(), Vec::<Token>::new());
    for cue in cues {
        let mut words = timed_words(&cue);
        if punctuated && !stands_alone(&cue.text) {
            if let (Some(last), Some(first)) = (run.last(), words.first_mut())
                && spaced_apart(&last.text, &first.text)
            {
                first.text.insert(0, ' ');
            }
            run.append(&mut words);
            continue;
        }
        segments.extend(plain_segments(&run));
        tokens.append(&mut run);
        segments.push(Segment { preserve_boundary_before: true, ..cue });
        tokens.append(&mut words);
    }
    segments.extend(plain_segments(&run));
    tokens.append(&mut run);
    for (index, segment) in segments.iter_mut().enumerate() {
        segment.id = format!("subtitle-{}", index + 1);
    }
    own(&segments, &mut tokens);
    document.segments = segments;
    document.tokens = tokens;
}

/// Marks each of `tokens`, in order, with the sentence it is in: each of `segments` takes as many
/// as hold the letters of its text, so that timing words can replace one sentence's at a time.
fn own(segments: &[Segment], tokens: &mut [Token]) {
    let letters = |text: &str| text.chars().filter(|c| !c.is_whitespace()).count();
    let mut tokens = tokens.iter_mut();
    for segment in segments {
        let mut left = letters(&segment.text);
        while left > 0
            && let Some(token) = tokens.next()
        {
            left = left.saturating_sub(letters(&token.text));
            token.segment_id = Some(segment.id.clone());
        }
    }
}

/// Whether a cue's lines are two languages (one written with spaces between words, one without)
/// or two speakers (`- Hi.` over `- Hello.`), which joining would run together.
fn stands_alone(text: &str) -> bool {
    let lines: Vec<&str> = text.lines().collect();
    let unspaced = |line: &&str| line.chars().any(|c| c.is_alphanumeric() && !is_spaced_letter(c));
    lines.len() > 1
        && (lines.iter().any(|line| line.starts_with(['-', '–', '—']))
            || lines.iter().any(unspaced) != lines.iter().all(unspaced))
}

/// `cue`'s words, each with the space before it, its time spread over them by length: the first
/// starts as the cue does and the last ends with it.
fn timed_words(cue: &Segment) -> Vec<Token> {
    let mut texts: Vec<String> = Vec::new();
    for line in cue.text.lines() {
        let mut words = words(line);
        // A dash that opens a line (`- I don't know.`) goes with the word after it, not as a
        // mark of its own that would end the sentence before.
        if words.len() > 1 && words[0].chars().all(|c| matches!(c, '-' | '–' | '—')) {
            let dash = words.remove(0);
            words[0].insert_str(0, &dash);
        }
        if let (Some(last), Some(first)) = (texts.last(), words.first_mut())
            && spaced_apart(last, first)
        {
            first.insert(0, ' ');
        }
        texts.append(&mut words);
    }
    let length = |text: &str| text.chars().filter(|c| !c.is_whitespace()).count() as i64;
    let total = texts.iter().map(|text| length(text)).sum::<i64>().max(1);
    let span = cue.end_ms - cue.start_ms;
    let mut done = 0;
    texts
        .into_iter()
        .map(|text| {
            let start_ms = cue.start_ms + span * done / total;
            done += length(&text);
            Token {
                start_ms,
                end_ms: cue.start_ms + span * done / total,
                text,
                speaker: cue.speaker.clone(),
                ..Token::default()
            }
        })
        .collect()
}

/// The words of `line`, each but the first with the space before it; in a script written
/// without spaces, each character is one, and punctuation stays with the word before it.
fn words(line: &str) -> Vec<String> {
    let unspaced = |c: char| c.is_alphanumeric() && !is_spaced_letter(c);
    let (mut words, mut space, mut before) = (Vec::<String>::new(), false, None::<char>);
    for c in line.chars() {
        if c.is_whitespace() {
            space = true;
            continue;
        }
        let starts = space || unspaced(c) || (before.is_some_and(unspaced) && c.is_alphanumeric());
        match words.last_mut() {
            Some(word) if !starts => word.push(c),
            Some(_) if space => words.push(format!(" {c}")),
            _ => words.push(c.to_string()),
        }
        (space, before) = (false, Some(c));
    }
    words
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cue(start_ms: i64, end_ms: i64, text: &str) -> Segment {
        Segment { start_ms, end_ms, text: text.into(), preserve_boundary_before: true, ..Segment::default() }
    }

    fn joined(cues: Vec<Segment>) -> Document {
        let mut document = Document { segments: cues, ..Document::default() };
        into_sentences(&mut document);
        document
    }

    fn sentences(document: &Document) -> Vec<(&str, i64, i64)> {
        document.segments.iter().map(|s| (s.text.as_str(), s.start_ms, s.end_ms)).collect()
    }

    #[test]
    fn pieces_of_a_sentence_join_and_keep_where_each_cue_starts() {
        let document = joined(vec![
            cue(0, 2000, "But how many of these people came"),
            cue(2000, 3000, "by small boat?"),
            cue(3000, 4000, "Many."),
        ]);
        assert_eq!(
            sentences(&document),
            [("But how many of these people came by small boat?", 0, 3000), ("Many.", 3000, 4000)]
        );
        let by = document.tokens.iter().find(|t| t.text == " by").unwrap();
        assert_eq!(by.start_ms, 2000, "the second cue's first word starts when that cue does");
        let owners: Vec<&str> = document.tokens.iter().filter_map(|t| t.segment_id.as_deref()).collect();
        assert_eq!(owners, [["subtitle-1"; 10].as_slice(), &["subtitle-2"]].concat());
    }

    #[test]
    fn a_sentence_ending_inside_a_cue_ends_there() {
        let document =
            joined(vec![cue(0, 2000, "person asks. Here's the number"), cue(2000, 3000, "of people housed.")]);
        let found = sentences(&document);
        assert_eq!(found[0].0, "person asks.");
        assert_eq!(found[1].0, "Here's the number of people housed.");
        assert_eq!(found[0].2, found[1].1, "one sentence ends as the next starts");
        assert!(found[0].2 > 0 && found[0].2 < 2000);
    }

    #[test]
    fn splitting_a_joined_sentence_at_a_cue_cuts_at_its_time() {
        let mut document = joined(vec![cue(0, 2000, "But how many came"), cue(2600, 3000, "by small boat?")]);
        let at = "But how many came ".chars().count();
        assert!(crate::transcript::structure::apply(&mut document, crate::transcript::structure::Edit::SplitAt(0, at)));
        assert_eq!(document.segments[1].start_ms, 2600);
    }

    #[test]
    fn a_cue_that_opens_with_a_mark_is_spaced_from_the_one_before() {
        let said = joined(vec![cue(0, 1000, "He looked at me and said,"), cue(1000, 2000, "\"You're not going.\"")]);
        assert_eq!(sentences(&said), [("He looked at me and said, \"You're not going.\"", 0, 2000)]);
        let costs = joined(vec![cue(0, 1000, "It only costs"), cue(1000, 2000, "$5 a month.")]);
        assert_eq!(sentences(&costs)[0].0, "It only costs $5 a month.");
        let asked = joined(vec![cue(0, 1000, "Hola, María,"), cue(1000, 2000, "¿cómo estás?")]);
        assert_eq!(sentences(&asked)[0].0, "Hola, María, ¿cómo estás?");
        let trailed = joined(vec![cue(0, 1000, "I was thinking…"), cue(1000, 2000, "maybe we should go.")]);
        assert_eq!(sentences(&trailed)[0].0, "I was thinking… maybe we should go.");
    }

    #[test]
    fn a_cue_that_opens_with_a_dash_starts_its_own_sentence() {
        let document = joined(vec![cue(1000, 3000, "Where is he?"), cue(30000, 32000, "- I don't know.")]);
        assert_eq!(sentences(&document), [("Where is he?", 1000, 3000), ("- I don't know.", 30000, 32000)]);
    }

    #[test]
    fn chinese_cues_join_without_spaces_and_each_character_is_timed() {
        let document = joined(vec![cue(0, 1000, "2023年达到峰值，"), cue(1000, 2000, "略低于12万人。")]);
        assert_eq!(sentences(&document), [("2023年达到峰值，略低于12万人。", 0, 2000)]);
        let texts: Vec<&str> = document.tokens.iter().map(|t| t.text.as_str()).collect();
        assert_eq!(texts[..6], ["2023", "年", "达", "到", "峰", "值，"]);
    }

    #[test]
    fn two_languages_or_two_speakers_in_a_cue_stay_apart() {
        let document = joined(vec![
            cue(0, 1000, "Hello there,\n你好，"),
            cue(1000, 2000, "- Hi.\n- Hello."),
            cue(2000, 3000, "my friend."),
        ]);
        assert_eq!(
            sentences(&document),
            [("Hello there,\n你好，", 0, 1000), ("- Hi.\n- Hello.", 1000, 2000), ("my friend.", 2000, 3000)]
        );
    }

    #[test]
    fn a_file_without_punctuation_keeps_its_cues() {
        let cues = (0..8).map(|n| cue(n * 1000, n * 1000 + 1000, "words without an end")).collect::<Vec<_>>();
        let document = joined(cues);
        assert_eq!(document.segments.len(), 8);
        assert_eq!(document.tokens.len(), 8 * 4);
    }
}
