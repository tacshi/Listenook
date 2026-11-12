//! Dictation: what the user typed against what was said, word by word, and
//! the pause mimic practice leaves after a sentence.

use std::sync::LazyLock;

use regex::Regex;

static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*").unwrap());
static LATIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[A-Za-z]+").unwrap());

/// How one word of the comparison came out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DictationWord {
    /// Typed as said.
    Matching(String),
    /// Another word typed in its place: what was said, what was typed.
    Different(String, String),
    /// Said and not typed.
    Missing(String),
    /// Typed and not said.
    Extra(String),
}

/// The words of `text`, punctuation left out.
pub fn words(text: &str) -> Vec<String> {
    WORD.find_iter(text).map(|m| m.as_str().to_owned()).collect()
}

fn normalized(word: &str) -> String {
    word.to_lowercase().replace('’', "'")
}

/// Aligns the typed answer with the reference by edit distance over words,
/// ignoring case and the shape of apostrophes.
pub fn compare(reference: &str, answer: &str) -> Vec<DictationWord> {
    let (expected, actual) = (words(reference), words(answer));
    let same = |i: usize, j: usize| normalized(&expected[i]) == normalized(&actual[j]);
    let (n, m) = (expected.len(), actual.len());
    let mut costs = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in costs.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cost) in costs[0].iter_mut().enumerate() {
        *cost = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let substitute = costs[i - 1][j - 1] + usize::from(!same(i - 1, j - 1));
            costs[i][j] = substitute.min(costs[i - 1][j] + 1).min(costs[i][j - 1] + 1);
        }
    }
    let (mut i, mut j, mut out) = (n, m, Vec::new());
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && same(i - 1, j - 1) && costs[i][j] == costs[i - 1][j - 1] {
            out.push(DictationWord::Matching(expected[i - 1].clone()));
            (i, j) = (i - 1, j - 1);
        } else if i > 0 && costs[i][j] == costs[i - 1][j] + 1 {
            out.push(DictationWord::Missing(expected[i - 1].clone()));
            i -= 1;
        } else if j > 0 && costs[i][j] == costs[i][j - 1] + 1 {
            out.push(DictationWord::Extra(actual[j - 1].clone()));
            j -= 1;
        } else {
            out.push(DictationWord::Different(expected[i - 1].clone(), actual[j - 1].clone()));
            (i, j) = (i - 1, j - 1);
        }
    }
    out.reverse();
    out
}

/// Whether every word was typed as said.
pub fn is_correct(result: &[DictationWord]) -> bool {
    !result.is_empty() && result.iter().all(|word| matches!(word, DictationWord::Matching(_)))
}

/// Word checking supports English: by the sentence's language when known,
/// else by whether it has Latin letters.
pub fn supports_dictation(text: &str, language: Option<&str>) -> bool {
    match language.filter(|l| !l.is_empty()) {
        Some(language) => language.split(['-', '_']).next().is_some_and(|l| l.eq_ignore_ascii_case("en")),
        None => LATIN.is_match(text),
    }
}

/// The pause after a sentence in mimic practice. A fixed interval of 1–10
/// seconds, or automatic (0): the sentence's length at the playback speed
/// plus half a second, at least 1.5 seconds.
pub fn mimic_pause_ms(sentence_ms: i64, speed: f64, fixed_seconds: u32) -> i64 {
    if fixed_seconds > 0 {
        return i64::from(fixed_seconds.min(10)) * 1000;
    }
    let spoken = (sentence_ms.max(0) as f64 / speed.max(0.1)).round() as i64;
    (spoken + 500).max(1500)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_are_matched_missing_extra_or_different() {
        use DictationWord::*;
        let result = compare("Don’t stop the music, please.", "dont stop music now please");
        assert_eq!(
            result,
            [
                Different("Don’t".into(), "dont".into()),
                Matching("stop".into()),
                Missing("the".into()),
                Matching("music".into()),
                Extra("now".into()),
                Matching("please".into()),
            ]
        );
        assert!(is_correct(&compare("It's fine.", "it’s FINE")));
        assert!(!is_correct(&compare("", "")));
    }

    #[test]
    fn dictation_is_for_english() {
        assert!(supports_dictation("你好", Some("en-US")));
        assert!(!supports_dictation("Hello", Some("fr")));
        assert!(supports_dictation("Hello", None));
        assert!(!supports_dictation("你好", None));
    }

    #[test]
    fn the_automatic_pause_follows_the_sentence_and_speed() {
        assert_eq!(mimic_pause_ms(4000, 1.0, 0), 4500);
        assert_eq!(mimic_pause_ms(4000, 2.0, 0), 2500);
        assert_eq!(mimic_pause_ms(300, 1.0, 0), 1500);
        assert_eq!(mimic_pause_ms(4000, 1.0, 3), 3000);
    }
}
