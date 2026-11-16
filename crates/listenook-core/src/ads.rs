//! Finding the ads in a transcript: the prompt for each chunk, and turning
//! the replies into runs of sentences to skip.

use serde_json::Value;

use crate::models::{AdFinding, Document};

/// A run shorter than this is not taken for an ad: a passing mention of a
/// sponsor is part of the show.
pub const MIN_AD_MS: i64 = 5_000;

pub const SYSTEM_PROMPT: &str = "You find the advertising in timestamped transcripts of podcasts and videos, so a language learner can skip it. Ads are sponsor reads, paid promotions, \"this episode is brought to you by\" segments, discount codes, and inserted ad breaks. The show's own intro, outro, theme, self-promotion of the show itself, and its real content are not ads. Use only the supplied segment IDs. When unsure, leave it out. Return JSON only, with no Markdown fences.";

const SHAPE: &str =
    r#"{"ads":[{"first":"segment-id where the ad starts","last":"segment-id where it ends","reason":"a few words"}]}"#;

/// The prompt for one chunk of [`crate::brief::chunks`].
pub fn prompt(chunk: &str, index: usize, total: usize) -> String {
    format!(
        "Find the ads in transcript chunk {} of {total}. An ad may start or end outside this chunk: then give the first or last segment of it that is here.\nReturn exactly this JSON shape, with an empty list when there are none:\n{SHAPE}\n\nTranscript:\n{chunk}",
        index + 1,
    )
}

/// The JSON object in a reply, fenced or wrapped in prose or not.
pub fn decode_reply(reply: &str) -> Option<Value> {
    let (start, end) = (reply.find('{')?, reply.rfind('}')?);
    let value: Value = serde_json::from_str(reply.get(start..=end)?).ok()?;
    value.is_object().then_some(value)
}

/// The ads the replies name, in order, as runs of sentences: unknown IDs
/// dropped, runs that touch or overlap joined, and short ones left out, as is
/// one that would take most of the recording.
pub fn findings(replies: &[Value], document: &Document) -> Vec<AdFinding> {
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
}
