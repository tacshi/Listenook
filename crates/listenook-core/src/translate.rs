use std::sync::LazyLock;

use regex::Regex;

use crate::models::{Segment, language_name};

pub const BATCH_SEGMENTS: usize = 20;
pub const BATCH_CHARACTERS: usize = 8000;

pub const SYSTEM_PROMPT: &str = "You are a professional subtitle translator. Translate faithfully and naturally. Preserve meaning, tone, names, and speaker intent. Return only the requested numbered lines without explanations.";

static NUMBERED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d+)[.)]\s*(.*)$").unwrap());
static LINGUISTIC: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{L}\p{N}]").unwrap());
const REFUSALS: &[&str] =
    &["i can't translate", "i cannot translate", "unable to translate", "抱歉，我无法", "对不起，我不能"];

#[derive(Debug, Clone, PartialEq)]
pub struct Batch {
    pub ids: Vec<String>,
    pub texts: Vec<String>,
}

pub fn batches(segments: &[Segment], only: Option<&[String]>) -> Vec<Batch> {
    let mut out: Vec<Batch> = Vec::new();
    let mut characters = 0;
    for segment in segments {
        let wanted = match only {
            Some(ids) => ids.contains(&segment.id),
            None => !segment.has_translation(),
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

pub fn user_prompt(texts: &[String], target_language: &str) -> Result<String, &'static str> {
    let name = language_name(target_language).ok_or("translation_invalid_language")?;
    let lines: String =
        texts.iter().enumerate().map(|(index, text)| format!("{}. {}\n", index + 1, text.replace('\n', " "))).collect();
    Ok(format!(
        "Translate each subtitle line into {name}.\nKeep every line concise and natural. Do not merge, split, omit, censor, or explain lines.\nIf a line is already in the target language or is non-linguistic, keep it unchanged.\n\nInput:\n{lines}\nOutput exactly {} numbered lines in the form \"N. translation\".\n",
        texts.len()
    ))
}

pub fn parse_reply(reply: &str, count: usize) -> Vec<Option<String>> {
    let mut out = vec![None; count];
    for line in reply.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let Some(found) = NUMBERED.captures(line) else {
            continue;
        };
        let (number, text) = (found[1].parse::<usize>().unwrap_or(0), found[2].trim());
        let lower = text.to_lowercase();
        if (1..=count).contains(&number) && !text.is_empty() && !REFUSALS.iter().any(|r| lower.contains(r)) {
            out[number - 1] = Some(text.to_owned());
        }
    }
    out
}

pub fn is_linguistic(text: &str) -> bool {
    LINGUISTIC.is_match(text)
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
    fn the_prompt_names_the_language_and_numbers_the_lines() {
        let prompt = user_prompt(&["Hi".into(), "Bye".into()], "zh-Hans").unwrap();
        assert!(prompt.starts_with("Translate each subtitle line into Simplified Chinese."));
        assert!(prompt.contains("Input:\n1. Hi\n2. Bye\n\nOutput exactly 2 numbered lines"));
        assert_eq!(user_prompt(&[], "xx"), Err("translation_invalid_language"));
    }
}
