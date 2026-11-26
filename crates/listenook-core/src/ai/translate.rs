use std::sync::LazyLock;

use regex::Regex;

use super::Ask;
use crate::models::{Document, Segment, TranslationStatus, language_name};

const BATCH_SEGMENTS: usize = 20;
const BATCH_CHARACTERS: usize = 8000;

const SYSTEM_PROMPT: &str = "You are a professional subtitle translator. Translate faithfully and naturally. Preserve meaning, tone, names, and speaker intent. Return only the requested numbered lines without explanations.";

static NUMBERED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d+)[.)]\s*(.*)$").unwrap());
const REFUSALS: &[&str] =
    &["i can't translate", "i cannot translate", "unable to translate", "抱歉，我无法", "对不起，我不能"];

#[derive(Debug, Clone, PartialEq)]
struct Batch {
    ids: Vec<String>,
    texts: Vec<String>,
}

/// The translation of a transcript's sentences into one language, a batch of numbered
/// lines at a time.
#[derive(Debug, Clone)]
pub struct Translation {
    name: &'static str,
    batches: Vec<Batch>,
    answered: usize,
    translated: u32,
    missing: u32,
    whole: bool,
}

impl Translation {
    /// The translation into `target` of the sentences in `only`, or of every one not yet
    /// translated nor skipped; `Err` with the code to show for a language it cannot name.
    pub fn new(segments: &[Segment], only: Option<&[String]>, target: &str) -> Result<Translation, &'static str> {
        Self::of(batches(segments, only), target, only.is_none())
    }

    /// The translation of one line on its own.
    pub fn line(text: &str, target: &str) -> Result<Translation, &'static str> {
        Self::of(vec![Batch { ids: vec![String::new()], texts: vec![text.to_owned()] }], target, false)
    }

    fn of(batches: Vec<Batch>, target: &str, whole: bool) -> Result<Translation, &'static str> {
        let name = language_name(target).ok_or("translation_invalid_language")?;
        Ok(Translation { name, batches, answered: 0, translated: 0, missing: 0, whole })
    }

    /// How many sentences it translates.
    pub fn total(&self) -> u32 {
        self.batches.iter().map(|batch| batch.ids.len() as u32).sum()
    }

    /// The sentences translated so far.
    pub fn translated(&self) -> u32 {
        self.translated
    }

    /// What to ask the model next, or `None` once every batch is answered.
    pub fn ask(&self) -> Option<Ask> {
        let batch = self.batches.get(self.answered)?;
        Some(Ask { system: SYSTEM_PROMPT, prompt: user_prompt(&batch.texts, self.name), json: false })
    }

    /// Takes the model's reply to [`ask`](Self::ask): each sentence it translated, by ID,
    /// with its translation.
    pub fn answer(&mut self, reply: &str) -> Vec<(String, String)> {
        let Some(batch) = self.batches.get(self.answered) else {
            return Vec::new();
        };
        self.answered += 1;
        let lines = parse_reply(reply, batch.texts.len());
        self.missing += lines.iter().filter(|line| line.is_none()).count() as u32;
        let done: Vec<(String, String)> =
            batch.ids.iter().zip(lines).filter_map(|(id, line)| Some((id.clone(), line?))).collect();
        self.translated += done.len() as u32;
        done
    }

    /// How it ended, having stopped at `error` or not, with what `document` holds now: its
    /// status, and the code to show for one that failed or left sentences out.
    pub fn outcome(&self, error: Option<String>, document: Option<&Document>) -> (TranslationStatus, Option<String>) {
        let untranslated = document.is_some_and(|d| d.segments.iter().any(|s| !s.skipped && !s.has_translation()));
        let status = match (&error, self.translated) {
            (Some(_), 0) => TranslationStatus::Failed,
            (Some(_), _) => TranslationStatus::Partial,
            (None, _) if self.missing > 0 || (self.whole && untranslated) => TranslationStatus::Partial,
            (None, _) => TranslationStatus::Completed,
        };
        let code =
            error.or_else(|| (status == TranslationStatus::Partial).then(|| "translation_incomplete_response".into()));
        (status, code)
    }
}

fn batches(segments: &[Segment], only: Option<&[String]>) -> Vec<Batch> {
    let mut out: Vec<Batch> = Vec::new();
    let mut characters = 0;
    for segment in segments {
        let wanted = match only {
            Some(ids) => ids.contains(&segment.id),
            None => !segment.skipped && !segment.has_translation(),
        };
        let text = segment.text.trim();
        if !wanted || text.is_empty() {
            continue;
        }
        let text: String = text.chars().take(BATCH_CHARACTERS).collect();
        let size = text.chars().count();
        let full = out.last().is_none_or(|b| b.ids.len() >= BATCH_SEGMENTS || characters + size > BATCH_CHARACTERS);
        if full {
            out.push(Batch { ids: Vec::new(), texts: Vec::new() });
            characters = 0;
        }
        let batch = out.last_mut().expect("a batch was just pushed");
        batch.ids.push(segment.id.clone());
        batch.texts.push(text);
        characters += size;
    }
    out
}

fn user_prompt(texts: &[String], name: &str) -> String {
    let lines: String =
        texts.iter().enumerate().map(|(index, text)| format!("{}. {}\n", index + 1, text.replace('\n', " "))).collect();
    format!(
        "Translate each subtitle line into {name}.\nKeep every line concise and natural. Do not merge, split, omit, censor, or explain lines.\nIf a line is already in the target language or is non-linguistic, keep it unchanged.\n\nInput:\n{lines}\nOutput exactly {} numbered lines in the form \"N. translation\".\n",
        texts.len()
    )
}

/// The translation of each of `count` numbered lines, read from `reply`. A reply whose last
/// line is not there, or that numbers a line twice, is not trusted at all: a model that merged
/// two lines numbers the rest from there, so every later translation would land on the
/// sentence before its own. Its lines stay untranslated, and translating again retries them.
fn parse_reply(reply: &str, count: usize) -> Vec<Option<String>> {
    let mut out = vec![None; count];
    let mut seen = vec![false; count];
    for line in reply.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let Some(found) = NUMBERED.captures(line) else {
            continue;
        };
        let (number, text) = (found[1].parse::<usize>().unwrap_or(0), found[2].trim());
        if !(1..=count).contains(&number) {
            continue;
        }
        if std::mem::replace(&mut seen[number - 1], true) {
            return vec![None; count];
        }
        let lower = text.to_lowercase();
        if !text.is_empty() && !REFUSALS.iter().any(|r| lower.contains(r)) {
            out[number - 1] = Some(text.to_owned());
        }
    }
    if seen.last() == Some(&false) {
        return vec![None; count];
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segment(id: &str, text: &str, translated: Option<&str>) -> Segment {
        Segment {
            id: id.into(),
            text: text.into(),
            translated_text: translated.map(str::to_owned),
            ..Default::default()
        }
    }

    #[test]
    fn batches_skip_translated_sentences_and_respect_the_limits() {
        let mut segments: Vec<Segment> = (0..45).map(|i| segment(&format!("s{i}"), "Hello.", None)).collect();
        segments[3].translated_text = Some("你好。".into());
        let all = batches(&segments, None);
        assert_eq!(all.iter().map(|b| b.ids.len()).collect::<Vec<_>>(), [20, 20, 4]);
        let one = batches(&segments, Some(&["s3".to_owned()]));
        assert_eq!(one[0].ids, ["s3"]);
    }

    #[test]
    fn replies_are_read_by_number_and_refusals_dropped() {
        let reply = "1. 你好\n3) I cannot translate this\n2. 再见\n9. extra\nnoise";
        assert_eq!(parse_reply(reply, 3), [Some("你好".into()), Some("再见".into()), None]);
    }

    #[test]
    fn a_reply_that_lost_its_place_is_not_trusted() {
        let shifted = "1. 一\n2. 二\n3. 三和四\n4. 五";
        assert_eq!(parse_reply(shifted, 5), [None, None, None, None, None], "the last line is missing");
        let twice = "1. 一\n2. 二\n2. 三\n3. 四";
        assert_eq!(parse_reply(twice, 3), [None, None, None], "a number comes twice");
        let gap = "1. 一\n3. 三";
        assert_eq!(parse_reply(gap, 3), [Some("一".into()), None, Some("三".into())], "a line left out in the middle");
    }

    #[test]
    fn the_prompt_names_the_language_and_numbers_the_lines() {
        let translation = Translation::line("Hi", "zh-Hans").unwrap();
        let prompt = user_prompt(&["Hi".into(), "Bye".into()], translation.name);
        assert!(prompt.starts_with("Translate each subtitle line into Simplified Chinese."));
        assert!(prompt.contains("Input:\n1. Hi\n2. Bye\n\nOutput exactly 2 numbered lines"));
        assert_eq!(Translation::line("Hi", "xx").unwrap_err(), "translation_invalid_language");
    }
}
