//! Finding the ads in a transcript: the prompt for each chunk, and turning
//! the replies into runs of sentences to skip.

use serde_json::Value;

use super::{Ask, JsonQuestion, Task};
use crate::{
    Change,
    models::{AdFinding, Document},
};

/// How much transcript goes in one request. Whether a stretch is an ad
/// depends on the whole episode, so a recording is sent whole up to this
/// (some 3 hours of speech, about 60 000 tokens); only a longer one is split.
const WHOLE_CHARACTERS: usize = 240_000;

/// A run shorter than this is not taken for an ad: a passing mention of a
/// sponsor is part of the show.
const MIN_AD_MS: i64 = 5_000;

const SYSTEM_PROMPT: &str = "You find the advertising in timestamped transcripts of podcasts and videos, so a language learner can skip it and keep only the episode itself. Ads are sponsor reads, paid promotions, \"this episode is brought to you by\" segments, discount codes, inserted ad breaks, and trailers or promos for other shows, podcasts or programmes, even from the same publisher or network. A trailer can sound like real storytelling, with quotes and voices: judge each stretch by whether it belongs to this episode's own topic, from its title. A trailer often ends with a call to action such as \"listen on … wherever you get your podcasts\" or \"search for … \"; the ad runs to there. Ads often come before the episode's own greeting, or interrupt it. Give each ad as one stretch from its first to its last segment, including a short station or show ident that sits between the ad and the episode's own greeting. The episode's own greeting, presenters' introductions, its topic and its real content are not ads. Use only the supplied segment IDs. Return JSON only, with no Markdown fences.";

const SHAPE: &str =
    r#"{"ads":[{"first":"segment-id where the ad starts","last":"segment-id where it ends","reason":"a few words"}]}"#;

/// The transcript to look through, whole unless it is very long.
fn chunks(document: &Document) -> Vec<String> {
    crate::ai::brief::chunks_of(document, WHOLE_CHARACTERS)
}

/// The prompt for the episode called `title`: all of it, or chunk `index`
/// of `total` when it is too long to send at once.
fn prompt(title: &str, chunk: &str, index: usize, total: usize) -> String {
    let part = if total > 1 {
        format!(
            "This is part {} of {total} of the transcript. An ad may start or end outside this part: then give the first or last segment of it that is here.\n",
            index + 1
        )
    } else {
        "This is the whole transcript: read all of it before deciding what is an ad.\n".to_owned()
    };
    format!(
        "Episode title: {title}\n{part}Return exactly this JSON shape, with an empty list when there are no ads:\n{SHAPE}\n\nTranscript:\n{chunk}"
    )
}

/// The JSON object in a reply, fenced or wrapped in prose or not.
fn decode_reply(reply: &str) -> Option<Value> {
    let (start, end) = (reply.find('{')?, reply.rfind('}')?);
    let value: Value = serde_json::from_str(reply.get(start..=end)?).ok()?;
    value.is_object().then_some(value)
}

/// The ads the replies name, in order, as runs of sentences: unknown IDs
/// dropped, runs that touch or overlap joined, and short ones left out, as is
/// one that would take most of the recording.
fn findings(replies: &[Value], document: &Document) -> Vec<AdFinding> {
    let index_of = |value: Option<&Value>| {
        let id = value.and_then(Value::as_str)?.trim();
        document.segments.iter().position(|segment| segment.id == id)
    };
    let mut runs: Vec<(usize, usize, String)> = replies
        .iter()
        .filter_map(|reply| reply.get("ads").and_then(Value::as_array))
        .flatten()
        .filter_map(|ad| {
            let first = index_of(ad.get("first"))?;
            let last = index_of(ad.get("last")).unwrap_or(first);
            let reason = ad.get("reason").and_then(Value::as_str).unwrap_or("").trim().to_owned();
            Some((first.min(last), first.max(last), reason))
        })
        .collect();
    runs.sort_by_key(|run| (run.0, run.1));
    let mut joined: Vec<(usize, usize, String)> = Vec::new();
    for (first, last, reason) in runs {
        match joined.last_mut() {
            Some(run) if first <= run.1 + 1 => {
                run.1 = run.1.max(last);
                if run.2.is_empty() {
                    run.2 = reason;
                }
            }
            _ => joined.push((first, last, reason)),
        }
    }
    let whole = document.segments.first().zip(document.segments.last()).map_or(0, |(a, b)| b.end_ms - a.start_ms);
    joined
        .into_iter()
        .filter(|(first, last, _)| {
            let span = document.span_ms(*first, *last);
            span >= MIN_AD_MS && span * 2 <= whole
        })
        .map(|(first, last, reason)| AdFinding {
            first_id: document.segments[first].id.clone(),
            last_id: document.segments[last].id.clone(),
            reason,
        })
        .collect()
}

/// A search of one recording for its ads: a question for each chunk of the transcript.
#[derive(Debug, Clone)]
pub struct Scan {
    title: String,
    chunks: Vec<String>,
    question: Option<JsonQuestion>,
    replies: Vec<Value>,
}

impl Scan {
    /// A search of `document`, the episode called `title`; `Err` with the code to show when
    /// it has nothing to search.
    pub fn new(document: &Document, title: &str) -> Result<Scan, &'static str> {
        let chunks = chunks(document);
        if chunks.is_empty() {
            return Err("ad_scan_empty_transcript");
        }
        let mut scan = Scan { title: title.to_owned(), chunks, question: None, replies: Vec::new() };
        scan.question = scan.question_for(0);
        Ok(scan)
    }

    fn question_for(&self, index: usize) -> Option<JsonQuestion> {
        let chunk = self.chunks.get(index)?;
        Some(JsonQuestion::new(SYSTEM_PROMPT, prompt(&self.title, chunk, index, self.chunks.len())))
    }

    /// The chunks answered, and how many there are.
    fn progress(&self) -> (u32, u32) {
        (self.replies.len() as u32, self.chunks.len() as u32)
    }
}

impl Task for Scan {
    const ERRORS: &'static str = "ad_scan_";

    /// A question for each chunk, noting the chunks answered and how many there are.
    fn ask(&self) -> Option<(Ask, Option<Change<'static>>)> {
        let (done, total) = self.progress();
        self.question.as_ref().map(|question| (question.ask(), Some(Change::AdScanAt(done, total))))
    }

    /// `Err` when it answered twice with no JSON.
    fn answer(&mut self, reply: &str) -> Result<Option<Change<'static>>, &'static str> {
        let Some(question) = &mut self.question else {
            return Ok(None);
        };
        if let Some(value) = question.read(reply, decode_reply).map_err(|()| "ad_scan_invalid_response")? {
            self.replies.push(value);
            self.question = self.question_for(self.replies.len());
        }
        Ok(None)
    }

    /// The ads the replies name in `document`, read again once they are all in, as its
    /// sentences may have changed while the model thought.
    fn end(self, error: Option<String>, document: &Document) -> Change<'static> {
        match error {
            Some(code) => Change::AdScanFailed(code),
            None => Change::AdsFound(findings(&self.replies, document), self.progress().1),
        }
    }
}

/// Where a finding is in `document` now, first and last index, if its
/// sentences are still there.
pub fn locate(finding: &AdFinding, document: &Document) -> Option<(usize, usize)> {
    let first = document.segments.iter().position(|segment| segment.id == finding.first_id)?;
    let last = document.segments.iter().position(|segment| segment.id == finding.last_id)?;
    Some((first.min(last), first.max(last)))
}

/// Marks each finding's sentences skipped. Whether any changed.
pub fn skip_found(document: &mut Document, found: &[AdFinding]) -> bool {
    let runs: Vec<_> = found.iter().filter_map(|finding| locate(finding, document)).collect();
    set_skipped(document, &runs, true)
}

/// Marks sentences `first` through `last` of each run skipped, or not.
/// Whether any changed.
pub fn set_skipped(document: &mut Document, runs: &[(usize, usize)], skipped: bool) -> bool {
    let mut changed = false;
    for &(first, last) in runs {
        for segment in document.segments.iter_mut().take(last + 1).skip(first) {
            changed |= segment.skipped != skipped;
            segment.skipped = skipped;
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::models::Segment;

    fn document() -> Document {
        let segments = (0..10)
            .map(|i| Segment {
                id: format!("s{i}"),
                start_ms: i * 10_000,
                end_ms: i * 10_000 + 9_000,
                text: format!("sentence {i}"),
                ..Default::default()
            })
            .collect();
        Document { segments, ..Default::default() }
    }

    #[test]
    fn replies_become_runs_of_known_sentences() {
        let replies = [json!({"ads": [
            {"first": "s2", "last": "s3", "reason": "sponsor"},
            {"first": "nope", "last": "s4"},
            {"first": "s8", "last": "s7"},
        ]})];
        let found = findings(&replies, &document());
        assert_eq!(found.len(), 2);
        assert_eq!((found[0].first_id.as_str(), found[0].last_id.as_str()), ("s2", "s3"));
        assert_eq!(found[0].reason, "sponsor");
        assert_eq!((found[1].first_id.as_str(), found[1].last_id.as_str()), ("s7", "s8"));
    }

    #[test]
    fn runs_split_across_chunks_are_joined() {
        let replies =
            [json!({"ads": [{"first": "s2", "last": "s3"}]}), json!({"ads": [{"first": "s4", "last": "s4"}]})];
        let found = findings(&replies, &document());
        assert_eq!(found.len(), 1);
        assert_eq!((found[0].first_id.as_str(), found[0].last_id.as_str()), ("s2", "s4"));
    }

    #[test]
    fn short_runs_and_most_of_the_recording_are_not_ads() {
        let mut document = document();
        document.segments[5].end_ms = document.segments[5].start_ms + 2_000;
        let replies = [json!({"ads": [{"first": "s5", "last": "s5"}, {"first": "s0", "last": "s8"}]})];
        assert!(findings(&replies, &document).is_empty());
    }

    #[test]
    fn an_episode_is_sent_whole_with_its_title() {
        let mut document = document();
        document.segments[3].skipped = true;
        let chunks = chunks(&document);
        assert_eq!(chunks.len(), 1);
        assert!(!chunks[0].contains("[id=s3]"), "what is skipped already is not sent");
        let prompt = prompt("Why do we itch?", &chunks[0], 0, 1);
        assert!(prompt.contains("Episode title: Why do we itch?") && prompt.contains("whole transcript"));
    }

    #[test]
    fn replies_are_read_through_fences_and_prose() {
        let reply = "Here you go:\n```json\n{\"ads\": [{\"first\": \"s1\", \"last\": \"s2\"}]}\n```";
        assert_eq!(decode_reply(reply), Some(json!({"ads": [{"first": "s1", "last": "s2"}]})));
        assert_eq!(decode_reply("no ads"), None);
    }

    #[test]
    fn found_ads_are_skipped_and_brought_back() {
        let mut document = document();
        let found = [AdFinding { first_id: "s2".into(), last_id: "s4".into(), reason: String::new() }];
        assert!(skip_found(&mut document, &found));
        assert_eq!(document.skipped_runs(), vec![(2, 4)]);
        assert!(!skip_found(&mut document, &found));
        assert!(set_skipped(&mut document, &[(2, 4)], false));
        assert!(document.skipped_runs().is_empty());
    }

    #[test]
    fn a_scan_asks_again_once_for_a_reply_that_is_not_json() {
        let mut scan = Scan::new(&document(), "Why do we itch?").unwrap();
        let (first, at) = scan.ask().unwrap();
        assert!(first.json && !first.prompt.contains("not valid JSON"));
        assert!(matches!(at, Some(Change::AdScanAt(0, 1))));
        scan.answer("Sorry, no.").unwrap();
        assert!(scan.ask().unwrap().0.prompt.contains("not valid JSON"));
        scan.answer(r#"{"ads": [{"first": "s2", "last": "s3"}]}"#).unwrap();
        assert!(scan.ask().is_none());
        assert!(matches!(scan.end(None, &document()), Change::AdsFound(found, 1) if found.len() == 1));
        let mut stubborn = Scan::new(&document(), "t").unwrap();
        stubborn.answer("no").unwrap();
        assert_eq!(stubborn.answer("still no").unwrap_err(), "ad_scan_invalid_response");
        assert_eq!(Scan::new(&Document::default(), "t").unwrap_err(), "ad_scan_empty_transcript");
    }
}
