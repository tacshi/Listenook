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
    run_together(out)
}

/// Words run together or apart compared as the same: `the right` typed for a transcript's
/// `theright` (a provider can leave a space out), or `theright` for `the right`. They count as
/// matching, with the words as typed, one mark per word typed.
fn run_together(words: Vec<DictationWord>) -> Vec<DictationWord> {
    use DictationWord::{Different, Extra, Matching, Missing};
    let joins = |a: &str, b: &str, whole: &str| format!("{}{}", normalized(a), normalized(b)) == normalized(whole);
    let mut out: Vec<DictationWord> = Vec::with_capacity(words.len());
    let mut words = words.into_iter().peekable();
    while let Some(word) = words.next() {
        let merged = match (&word, words.peek()) {
            (Different(whole, a), Some(Extra(b))) | (Extra(a), Some(Different(whole, b))) if joins(a, b, whole) => {
                Some(vec![Matching(a.clone()), Matching(b.clone())])
            }
            (Different(first, typed), Some(Missing(second))) | (Missing(first), Some(Different(second, typed)))
                if joins(first, second, typed) =>
            {
                Some(vec![Matching(typed.clone())])
            }
            _ => None,
        };
        match merged {
            Some(merged) => {
                words.next();
                out.extend(merged);
            }
            None => out.push(word),
        }
    }
    out
}

/// What to fix first in `answer` after `result` (its comparison), in bytes: the first word
/// typed wrong or not wanted, so typing replaces it, or an empty range where the first
/// missing word goes (after the word typed before it). `None` when it is all right.
pub fn first_fix(answer: &str, result: &[DictationWord]) -> Option<std::ops::Range<usize>> {
    let spans: Vec<std::ops::Range<usize>> = WORD.find_iter(answer).map(|m| m.range()).collect();
    let mut typed = 0;
    for word in result {
        match word {
            DictationWord::Matching(_) => typed += 1,
            DictationWord::Different(..) | DictationWord::Extra(_) => return spans.get(typed).cloned(),
            DictationWord::Missing(_) => {
                let at = typed.checked_sub(1).map_or(0, |before| spans[before].end);
                return Some(at..at);
            }
        }
    }
    None
}

/// `answer` with room to type a missing word at byte `at` ([`first_fix`]'s empty range),
/// and where the caret goes: a space is added there, and the caret is on the side the word
/// goes (after the word before it, before the first one at the start), so typing the word
/// alone puts it between its neighbours.
pub fn room_for_missing(answer: &str, at: usize) -> (String, usize) {
    let mut text = answer.to_owned();
    text.insert(at, ' ');
    (text, if at == 0 { 0 } else { at + 1 })
}

/// `word` as a hint: its first letter (two for a word of six letters or more) and a dot for
/// each letter after, apostrophes and hyphens kept; `whole`, the word itself.
pub fn hint(word: &str, whole: bool) -> String {
    if whole {
        return word.to_owned();
    }
    let letters = word.chars().filter(|c| c.is_alphanumeric()).count();
    let shown = if letters >= 6 { 2 } else { 1 };
    let mut seen = 0;
    word.chars()
        .map(|c| {
            if !c.is_alphanumeric() {
                return c;
            }
            seen += 1;
            if seen <= shown { c } else { '•' }
        })
        .collect()
}

/// Whether `typed` is close to `expected`: the same but for apostrophes (`dont`), or a letter
/// off (`thing`, `swalow`; two in a word of eight letters or more). Still a mistake, but one
/// of spelling, not of hearing.
pub fn is_near(expected: &str, typed: &str) -> bool {
    let bare = |word: &str| normalized(word).chars().filter(|c| c.is_alphanumeric()).collect::<Vec<char>>();
    let (a, b) = (bare(expected), bare(typed));
    if a == b {
        return true;
    }
    let longest = a.len().max(b.len());
    let allowed = if longest >= 8 {
        2
    } else if longest >= 3 {
        1
    } else {
        0
    };
    allowed > 0 && a.len().abs_diff(b.len()) <= allowed && edits(&a, &b) <= allowed
}

/// The fewest letters added, removed, changed or swapped with the next to turn `a` into `b`
/// (`jsut` is one swap from `just`).
fn edits(a: &[char], b: &[char]) -> usize {
    let mut d = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let changed = d[i - 1][j - 1] + usize::from(a[i - 1] != b[j - 1]);
            d[i][j] = changed.min(d[i - 1][j] + 1).min(d[i][j - 1] + 1);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = d[i][j].min(d[i - 2][j - 2] + 1);
            }
        }
    }
    d[a.len()][b.len()]
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
    fn a_fix_is_the_first_word_typed_wrong_or_where_one_is_missing() {
        let fix = |reference: &str, answer: &str| first_fix(answer, &compare(reference, answer));
        assert_eq!(fix("I envision a digestive system.", "I envision a digestive systemm"), Some(23..30));
        assert_eq!(fix("Don’t stop the music, please.", "dont stop music now please"), Some(0..4));
        assert_eq!(fix("Welcome back to the show.", "welcome to the show"), Some(7..7));
        assert_eq!(fix("Welcome back to the show.", "back to the show"), Some(0..0));
        assert_eq!(fix("Welcome back.", "welcome back now"), Some(13..16));
        assert_eq!(fix("Welcome back.", "welcome back"), None);
    }

    #[test]
    fn words_run_together_or_apart_still_match() {
        let reference = "you send it to the left or theright, or the middle";
        let answer = "you send it to the left or the right or the middle";
        let marks = compare(reference, answer);
        assert!(is_correct(&marks), "{marks:?}");
        assert_eq!(marks.len(), words(answer).len(), "a mark for each word typed");
        assert_eq!(first_fix(answer, &marks), None);
        let joined = compare("Turn to the right now.", "turn to theright now");
        assert!(is_correct(&joined), "{joined:?}");
        assert_eq!(joined.len(), 4, "one mark for the one word typed");
        assert!(!is_correct(&compare("It's all right.", "it's alright")), "not the same letters");
        let typo = compare("the right one", "the rite one");
        assert!(!is_correct(&typo), "a word typed wrong is still wrong");
    }

    #[test]
    fn a_missing_word_gets_its_own_space_to_type_into() {
        let typed = |answer: &str, at: usize, word: &str| {
            let (mut text, caret) = room_for_missing(answer, at);
            text.insert_str(caret, word);
            text
        };
        assert_eq!(typed("things you have", 6, "that"), "things that you have");
        assert_eq!(typed("back to the show", 0, "welcome"), "welcome back to the show");
        assert_eq!(typed("swallow", 7, "right"), "swallow right");
        let reference = "Each task that you do are things that you have to swallow, right?";
        let answer = "each task that you do are things you have to swallow right";
        let fix = first_fix(answer, &compare(reference, answer)).unwrap();
        assert!(is_correct(&compare(reference, &typed(answer, fix.start, "that"))));
    }

    #[test]
    fn a_hint_shows_the_first_letters_then_the_word() {
        assert_eq!(hint("swallow", false), "sw•••••");
        assert_eq!(hint("that", false), "t•••");
        assert_eq!(hint("don't", false), "d••'•");
        assert_eq!(hint("left-right", false), "le••-•••••");
        assert_eq!(hint("that", true), "that");
    }

    #[test]
    fn a_letter_off_is_near_a_different_word_is_not() {
        for (expected, typed) in
            [("don't", "dont"), ("things", "thing"), ("swallow", "swalow"), ("envision", "envisoin"), ("just", "jsut")]
        {
            assert!(is_near(expected, typed), "{typed} for {expected}");
        }
        for (expected, typed) in [("right", "rite"), ("the", "a"), ("to", "so"), ("things", "rings!x")] {
            assert!(!is_near(expected, typed), "{typed} for {expected}");
        }
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
