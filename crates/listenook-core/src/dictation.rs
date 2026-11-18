use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization;

/// A word: a grouped or decimal number (`10,000`, `3.5`), or letters and digits with the
/// accents written as separate marks and the apostrophes inside it (`café`, `don't`).
static WORD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\p{N}+(?:[.,]\p{N}+)+|[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)*").unwrap()
});
static LATIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[A-Za-z]+").unwrap());

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DictationWord {
    Matching(String),
    Different(String, String),
    Missing(String),
    Extra(String),
}

pub fn words(text: &str) -> Vec<String> {
    WORD.find_iter(text).map(|m| m.as_str().to_owned()).collect()
}

/// How a word is compared: in one Unicode form (so `é` typed as one letter or as `e` and an
/// accent is the same), without case, with one kind of apostrophe, and a number without its
/// thousands commas (`10,000` is `10000`).
fn normalized(word: &str) -> String {
    let word = word.nfc().collect::<String>().to_lowercase().replace('’', "'");
    if word.chars().all(|c| c.is_numeric() || matches!(c, ',' | '.')) { word.replace(',', "") } else { word }
}

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

/// Where to start fixing `answer` after `result` (its comparison): the byte offset just
/// after the first word typed wrong or not wanted, or where the first missing word goes
/// (after the word typed before it). `None` when it is all right.
pub fn first_fix(answer: &str, result: &[DictationWord]) -> Option<usize> {
    let ends: Vec<usize> = WORD.find_iter(answer).map(|m| m.end()).collect();
    let mut typed = 0;
    for word in result {
        match word {
            DictationWord::Matching(_) => typed += 1,
            DictationWord::Different(..) | DictationWord::Extra(_) => return ends.get(typed).copied(),
            DictationWord::Missing(_) => return Some(typed.checked_sub(1).map_or(0, |before| ends[before])),
        }
    }
    None
}

pub fn is_correct(result: &[DictationWord]) -> bool {
    !result.is_empty() && result.iter().all(|word| matches!(word, DictationWord::Matching(_)))
}

pub fn supports_dictation(text: &str, language: Option<&str>) -> bool {
    match language.filter(|l| !l.is_empty()) {
        Some(language) => language.split(['-', '_']).next().is_some_and(|l| l.eq_ignore_ascii_case("en")),
        None => LATIN.is_match(text),
    }
}

pub fn mimic_pause_ms(sentence_ms: i64, speed: f64, fixed_seconds: u32) -> i64 {
    if fixed_seconds > 0 {
        return i64::from(fixed_seconds.min(10)) * 1000;
    }
    let spoken = (sentence_ms.max(0) as f64 / speed.max(0.1)).round() as i64;
    (spoken + 500).max(1500)
}

/// The gap before a sentence plays again while it is typed: typing takes
/// longer than saying it, so twice the time it plays for, at least 2 s and
/// at most 10 s.
pub fn replay_pause_ms(sentence_ms: i64, speed: f64) -> i64 {
    let spoken = (sentence_ms.max(0) as f64 / speed.max(0.1)).round() as i64;
    (spoken * 2).clamp(2000, 10_000)
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
    fn accents_however_typed_and_grouped_numbers_match() {
        assert!(is_correct(&compare("Caf\u{e9} au lait", "cafe\u{301} au lait")));
        assert!(is_correct(&compare("It costs 10,000 dollars.", "it costs 10000 dollars")));
        assert!(is_correct(&compare("Pi is 3.14.", "pi is 3.14")));
        assert_eq!(words("the 3rd of 1,500 people"), ["the", "3rd", "of", "1,500", "people"]);
        assert!(!is_correct(&compare("cafe", "caf\u{e9}")), "an accent still counts");
    }

    #[test]
    fn a_fix_starts_after_the_first_word_typed_wrong_or_where_one_is_missing() {
        let fix = |reference: &str, answer: &str| first_fix(answer, &compare(reference, answer));
        assert_eq!(fix("I envision a digestive system.", "I envision a digestive systemm"), Some(30));
        assert_eq!(fix("Don’t stop the music, please.", "dont stop music now please"), Some(4));
        assert_eq!(fix("Welcome back to the show.", "welcome to the show"), Some(7));
        assert_eq!(fix("Welcome back to the show.", "back to the show"), Some(0));
        assert_eq!(fix("Welcome back.", "welcome back now"), Some(16));
        assert_eq!(fix("Welcome back.", "welcome back"), None);
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
        assert_eq!(replay_pause_ms(3000, 1.0), 6000);
        assert_eq!(replay_pause_ms(3000, 2.0), 3000);
        assert_eq!(replay_pause_ms(500, 1.0), 2000);
        assert_eq!(replay_pause_ms(9000, 1.0), 10_000);
    }
}
