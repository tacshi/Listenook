//! A long sentence as the lines of a subtitle. A sentence stays one unit
//! everywhere else; over a picture it shows a line at a time, cut where the
//! speaker pauses or the text has a comma, so no line is longer than can be
//! read at a glance.

use std::ops::Range;

/// The widest a line may be, in the width of a Latin letter: about two rows
/// of a subtitle.
pub const MAX_WIDTH: usize = 84;
/// The longest a line may stay up.
pub const MAX_MS: i64 = 7000;
/// A line narrower than this is a poor place to stop.
const MIN_WIDTH: usize = 16;

/// What a line's width counts: a character of a script written without
/// spaces is as wide as two Latin letters.
fn width(text: &str) -> usize {
    text.chars()
        .map(|c| match c as u32 {
            0x1100..=0x115F
            | 0x2E80..=0x303E
            | 0x3040..=0xA4CF
            | 0xAC00..=0xD7A3
            | 0xF900..=0xFAFF
            | 0xFE30..=0xFE4F
            | 0xFF00..=0xFF60
            | 0xFFE0..=0xFFE6 => 2,
            _ => 1,
        })
        .sum()
}

/// Punctuation that closes what is before it.
fn closes(c: char) -> bool {
    matches!(
        c,
        ',' | '.'
            | ';'
            | ':'
            | '!'
            | '?'
            | '…'
            | ')'
            | ']'
            | '}'
            | '”'
            | '’'
            | '，'
            | '。'
            | '；'
            | '：'
            | '！'
            | '？'
            | '、'
            | '）'
            | '」'
            | '』'
    )
}

/// The words with the punctuation that closes a word kept on it: a
/// transcript may time the comma after a word as part of the next one
/// (`"divorce"`, `", but"`), and a line must not start with it.
pub fn tidy<S: AsRef<str>>(words: &[(S, i64, i64)]) -> Vec<(String, i64, i64)> {
    let mut out: Vec<(String, i64, i64)> = Vec::with_capacity(words.len());
    for (text, start, end) in words {
        let text = text.as_ref();
        let closing = text.len() - text.trim_start_matches(closes).len();
        match out.last_mut() {
            Some((before, ..)) if closing > 0 => {
                before.push_str(&text[..closing]);
                out.push((text[closing..].to_owned(), *start, *end));
            }
            _ => out.push((text.to_owned(), *start, *end)),
        }
    }
    out
}

/// How good a place to stop the end of `word` is, by its punctuation.
fn stop(word: &str) -> f64 {
    let tail: Vec<char> = word.trim_end().chars().rev().take_while(|c| !c.is_alphanumeric()).collect();
    if tail.iter().any(|c| matches!(c, '.' | '!' | '?' | '。' | '！' | '？')) {
        3.0
    } else if tail.iter().any(|c| matches!(c, ';' | ':' | '…' | '—' | '–' | '；' | '：')) {
        2.5
    } else if tail.iter().any(|c| matches!(c, ',' | '，' | '、')) {
        2.0
    } else {
        0.0
    }
}

/// The lines a sentence's timed words show as, each a range of them: the
/// whole sentence when it is short, else cut where the speaker pauses or
/// the punctuation allows, into lines of about even length. `words` are in
/// the order they are said, each with what stands before it.
pub fn lines<S: AsRef<str>>(words: &[(S, i64, i64)]) -> Vec<Range<usize>> {
    let widths: Vec<usize> = words.iter().map(|(text, ..)| width(text.as_ref())).collect();
    let mut out = Vec::new();
    cut(words, &widths, 0..words.len(), &mut out);
    out
}

fn cut<S: AsRef<str>>(words: &[(S, i64, i64)], widths: &[usize], span: Range<usize>, out: &mut Vec<Range<usize>>) {
    if span.is_empty() {
        return;
    }
    let total: usize = widths[span.clone()].iter().sum();
    let lasts = words[span.end - 1].2 - words[span.start].1;
    let too_long = total > MAX_WIDTH || (lasts > MAX_MS && total > MIN_WIDTH * 2);
    if !too_long || span.len() < 2 {
        out.push(span);
        return;
    }
    // Stop after the word that scores best: punctuation and a pause count
    // for it, lines of uneven length and a scrap of a line against it.
    let mut best = (f64::MIN, span.start);
    let mut left = 0;
    for at in span.start..span.end - 1 {
        left += widths[at];
        let right = total - left;
        let pause = (words[at + 1].1 - words[at].2).clamp(0, 1200) as f64 / 400.0;
        let uneven = 3.0 * left.abs_diff(right) as f64 / total.max(1) as f64;
        let scrap = if left < MIN_WIDTH || right < MIN_WIDTH { 4.0 } else { 0.0 };
        let score = stop(words[at].0.as_ref()) + pause - uneven - scrap;
        if score > best.0 {
            best = (score, at);
        }
    }
    cut(words, widths, span.start..best.1 + 1, out);
    cut(words, widths, best.1 + 1..span.end, out);
}

/// The line that shows while the word at `said` is being said: the first
/// before any is.
pub fn line_of(lines: &[Range<usize>], said: Option<usize>) -> usize {
    said.and_then(|said| lines.iter().position(|line| line.contains(&said))).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Words a third of a second apart, with a pause after those that end
    /// with `|`.
    fn timed(text: &str) -> Vec<(String, i64, i64)> {
        let mut at = 0;
        text.split(' ')
            .enumerate()
            .map(|(index, word)| {
                let paused = word.ends_with('|');
                let word = word.trim_end_matches('|');
                let start = at;
                at += 330 + if paused { 900 } else { 0 };
                (if index == 0 { word.to_owned() } else { format!(" {word}") }, start, start + 300)
            })
            .collect()
    }

    fn texts(words: &[(String, i64, i64)]) -> Vec<String> {
        lines(words)
            .into_iter()
            .map(|line| words[line].iter().map(|(text, ..)| text.as_str()).collect::<String>().trim().to_owned())
            .collect()
    }

    #[test]
    fn a_short_sentence_is_one_line() {
        assert_eq!(texts(&timed("It's no secret.")), ["It's no secret."]);
    }

    #[test]
    fn a_long_sentence_is_cut_at_its_commas() {
        let words = timed(
            "It's no secret that I went through a few dark years after my divorce, but like the biggest habit \
             that happened was I was constantly delaying things, and I just got comfortable with like minimizing \
             the life tabs in my brain.",
        );
        assert_eq!(
            texts(&words),
            [
                "It's no secret that I went through a few dark years after my divorce,",
                "but like the biggest habit that happened was I was constantly delaying things,",
                "and I just got comfortable with like minimizing the life tabs in my brain.",
            ]
        );
    }

    #[test]
    fn without_punctuation_a_pause_is_where_a_line_ends() {
        let words = timed(
            "so what I ended up doing for the whole of last year was writing everything down| in one long list \
             on my phone that I kept with me",
        );
        assert_eq!(
            texts(&words),
            [
                "so what I ended up doing for the whole of last year was writing everything down",
                "in one long list on my phone that I kept with me",
            ]
        );
    }

    #[test]
    fn a_slow_sentence_is_cut_by_its_time() {
        let words: Vec<(String, i64, i64)> =
            ["Well,", " I", " suppose", " that", " it", " could", " be", " the", " right", " one"]
                .iter()
                .enumerate()
                .map(|(index, word)| ((*word).to_owned(), index as i64 * 1000, index as i64 * 1000 + 800))
                .collect();
        assert!(lines(&words).len() > 1);
    }

    #[test]
    fn a_comma_timed_with_the_next_word_goes_back_to_its_own() {
        let words = tidy(&[("divorce", 0, 1), (", but", 2, 3), (" “so", 4, 5)]);
        let texts: Vec<&str> = words.iter().map(|(text, ..)| text.as_str()).collect();
        assert_eq!(texts, ["divorce,", " but", " “so"]);
    }

    #[test]
    fn the_line_shown_is_the_one_being_said() {
        let lines = [0..3, 3..5];
        assert_eq!((line_of(&lines, None), line_of(&lines, Some(2)), line_of(&lines, Some(4))), (0, 0, 1));
    }
}
