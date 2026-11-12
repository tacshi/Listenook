//! AI Briefs: the prompts, cutting a transcript into chunks, and turning a
//! model's JSON into a brief in which every item cites real segments.

use std::collections::HashSet;

use serde_json::Value;

use crate::{
    format::clock,
    models::{
        AiBrief, AiBriefSection, AiChapter, AiInsight, AiInsightType, AiLanguageNote, AiLanguageNoteKind,
        AiLearningLevel, Document, now_iso,
    },
};

/// The most characters of rendered transcript in one request.
pub const CHUNK_CHARACTERS: usize = 8000;

/// The system prompt of every brief request.
pub const SYSTEM_PROMPT: &str = "You turn timestamped transcripts into concise, trustworthy work products. Use only facts explicitly supported by the supplied segments. Every chapter and insight must cite one or more exact segment IDs. Never invent decisions, owners, deadlines, or questions. Language-learning explanations may use established linguistic knowledge, but every selected term and source excerpt must come from the cited transcript segments. Omit unsupported items. Return JSON only, with no Markdown fences.";

const SHAPE: &str = r#"{"overview":"concise overview or empty string","overview_evidence":["segment-id"],"chapters":[{"title":"...","summary":"...","evidence":["segment-id"]}],"insights":[{"type":"keyIdea|notableMoment|decision|actionItem|openQuestion","text":"...","owner":null,"deadline":null,"evidence":["segment-id"]}],"language_notes":[{"kind":"vocabulary|expression|grammar","term":"...","explanation":"...","source_excerpt":"...","evidence":["segment-id"]}]}"#;

/// What the user asked a brief to contain.
#[derive(Debug, Clone, PartialEq)]
pub struct BriefRequest {
    pub sections: Vec<AiBriefSection>,
    pub output_language: String,
    pub learning_language: Option<String>,
    pub learning_level: AiLearningLevel,
    pub model: String,
}

impl BriefRequest {
    /// The sections a new brief has unless the user chooses: all but the
    /// language notes.
    pub fn default_sections() -> Vec<AiBriefSection> {
        AiBriefSection::ALL.iter().copied().filter(|s| *s != AiBriefSection::LanguageNotes).collect()
    }

    fn allowed_insights(&self) -> Vec<AiInsightType> {
        let mut out = Vec::new();
        for section in &self.sections {
            match section {
                AiBriefSection::KeyIdeas => out.extend([AiInsightType::KeyIdea, AiInsightType::NotableMoment]),
                AiBriefSection::Decisions => out.push(AiInsightType::Decision),
                AiBriefSection::ActionItems => out.push(AiInsightType::ActionItem),
                AiBriefSection::OpenQuestions => out.push(AiInsightType::OpenQuestion),
                _ => {}
            }
        }
        out
    }

    fn requested(&self) -> String {
        let names: Vec<&str> = self.sections.iter().map(|s| s.as_str()).collect();
        let insights: Vec<&str> = self.allowed_insights().iter().map(|t| t.as_str()).collect();
        let rule = if insights.is_empty() {
            "Return insights as an empty array".to_owned()
        } else {
            format!("Use only these insight types: {}", insights.join(", "))
        };
        format!("{}. {rule}", names.join(", "))
    }

    fn learning(&self, whole: bool) -> String {
        if !self.sections.contains(&AiBriefSection::LanguageNotes) {
            return "Return language_notes as an empty array.".to_owned();
        }
        let language = match &self.learning_language {
            Some(code) => format!("language code \"{code}\""),
            None => "the dominant natural language in the transcript".to_owned(),
        };
        let count = if whole {
            "Select 6–12 high-value notes overall, or fewer when the transcript does not support that many."
        } else {
            "Select only high-value candidates from this chunk; do not pad the result."
        };
        format!(
            "Language notes are requested for {language} at {} level.\n{count} Balance vocabulary, reusable expressions, and grammar or usage when the evidence supports them.\nKeep term and source_excerpt in the learned language. Write explanation in the requested output language using clear, professional, level-appropriate wording.\nsource_excerpt must be a short verbatim substring of a cited transcript segment. Do not assess pronunciation, fluency, or speaker correctness, and do not create quizzes, corrections, or invented examples.",
            self.learning_level.as_str()
        )
    }
}

/// The transcript as the lines the model reads, cut into chunks.
pub fn chunks(document: &Document) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for segment in document.segments.iter().filter(|s| !s.text.trim().is_empty()) {
        let mut line = format!("[id={}][{}]", segment.id, clock(segment.start_ms));
        let speaker = document.speaker_name(segment.speaker.as_deref());
        if !speaker.is_empty() {
            line.push_str(&format!("[speaker={speaker}]"));
        }
        if let Some(language) = &segment.language {
            line.push_str(&format!("[language={language}]"));
        }
        line.push_str(&format!(" {}", segment.text.trim()));
        match out.last_mut() {
            Some(chunk) if chunk.len() + line.len() < CHUNK_CHARACTERS => {
                chunk.push('\n');
                chunk.push_str(&line);
            }
            _ => out.push(line),
        }
    }
    out
}

/// The prompt analyzing chunk `index` of `total`.
pub fn chunk_prompt(request: &BriefRequest, chunk: &str, index: usize, total: usize) -> String {
    format!(
        "Analyze transcript chunk {} of {total}.\nWrite all user-facing text in language code \"{}\".\nRequested sections: {}.\n{}\n\nReturn exactly this JSON shape:\n{SHAPE}\n\nFor owner and deadline, use null unless the cited transcript states them explicitly. Keep overview_evidence to the smallest useful set of supporting segments.\n\nTranscript:\n{chunk}",
        index + 1,
        request.output_language,
        request.requested(),
        request.learning(total == 1),
    )
}

/// The prompt joining several chunks' analyses into one brief.
pub fn synthesis_prompt(request: &BriefRequest, candidates: &[Value]) -> String {
    format!(
        "Synthesize the candidate analyses below into one non-repetitive brief.\nWrite all user-facing text in language code \"{}\".\nRequested sections: {}.\nPreserve only supplied evidence segment IDs. Do not introduce facts.\n{}\n\nReturn exactly this JSON shape:\n{SHAPE}\n\nCandidates:\n{}",
        request.output_language,
        request.requested(),
        request.learning(true),
        Value::Array(candidates.to_vec()),
    )
}

/// The JSON object in a reply, fences or prose around it ignored: the one
/// with a brief's keys when there are several.
pub fn decode_reply(reply: &str) -> Option<Value> {
    const KEYS: &[&str] = &["overview", "overview_evidence", "chapters", "insights", "language_notes"];
    let bytes = reply.as_bytes();
    let mut last = None;
    for start in (0..bytes.len()).filter(|&i| bytes[i] == b'{') {
        let (mut depth, mut in_string, mut escaped) = (0usize, false, false);
        for (offset, &byte) in bytes[start..].iter().enumerate() {
            if in_string {
                match byte {
                    _ if escaped => escaped = false,
                    b'\\' => escaped = true,
                    b'"' => in_string = false,
                    _ => {}
                }
                continue;
            }
            match byte {
                b'"' => in_string = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        if let Ok(value @ Value::Object(_)) = serde_json::from_str(&reply[start..=start + offset]) {
                            if KEYS.iter().any(|k| value.get(k).is_some()) {
                                return Some(value);
                            }
                            last = Some(value);
                        }
                        break;
                    }
                }
                _ => {}
            }
        }
    }
    last
}

fn normalized(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

fn stable_id(prefix: &str, text: &str, index: usize) -> String {
    // FNV-1a: stable across runs and platforms.
    let hash = normalized(text).bytes().fold(0x811c_9dc5_u32, |h, b| (h ^ u32::from(b)).wrapping_mul(0x0100_0193));
    format!("{prefix}-{hash:x}-{index}")
}

fn text_of(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or("").trim().to_owned()
}

/// A model's JSON as a brief: evidence limited to real segment ids, items
/// without evidence dropped, owners and deadlines kept only when the cited
/// text states them. `ai_brief_no_supported_content` when nothing is left.
pub fn brief_from_json(value: &Value, request: &BriefRequest, document: &Document) -> Result<AiBrief, &'static str> {
    let known: HashSet<&str> = document.segments.iter().map(|s| s.id.as_str()).collect();
    let evidence = |value: &Value, key: &str| -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for id in value.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
            if known.contains(id) && !out.iter().any(|e| e == id) {
                out.push(id.to_owned());
            }
        }
        out
    };
    let cited_text = |ids: &[String]| -> String {
        document
            .segments
            .iter()
            .filter(|s| ids.contains(&s.id))
            .map(|s| format!("{} {}", s.text, document.speaker_name(s.speaker.as_deref())))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let has = |section| request.sections.contains(&section);

    let overview_evidence = evidence(value, "overview_evidence");
    let overview = if has(AiBriefSection::Overview) && !overview_evidence.is_empty() {
        text_of(value, "overview")
    } else {
        String::new()
    };

    let mut chapters = Vec::new();
    if has(AiBriefSection::Chapters) {
        for item in value.get("chapters").and_then(Value::as_array).into_iter().flatten() {
            let (title, ids) = (text_of(item, "title"), evidence(item, "evidence"));
            if title.is_empty() || ids.is_empty() {
                continue;
            }
            chapters.push(AiChapter {
                id: stable_id("chapter", &title, chapters.len()),
                title,
                summary: text_of(item, "summary"),
                evidence_segment_ids: ids,
                edited: false,
            });
        }
    }

    let allowed = request.allowed_insights();
    let mut insights: Vec<AiInsight> = Vec::new();
    for item in value.get("insights").and_then(Value::as_array).into_iter().flatten() {
        let kind_name = text_of(item, "type");
        let kind = AiInsightType::parse(&kind_name);
        let (text, ids) = (text_of(item, "text"), evidence(item, "evidence"));
        if kind.as_str() != kind_name || !allowed.contains(&kind) || text.is_empty() || ids.is_empty() {
            continue;
        }
        if insights.iter().any(|i| i.kind == kind && normalized(&i.text) == normalized(&text)) {
            continue;
        }
        let cited = normalized(&cited_text(&ids));
        let stated = |key: &str| {
            Some(text_of(item, key)).filter(|v| !v.is_empty() && v != "null" && cited.contains(&normalized(v)))
        };
        insights.push(AiInsight {
            id: stable_id(kind.as_str(), &text, insights.len()),
            kind,
            owner: stated("owner"),
            deadline: stated("deadline"),
            text,
            evidence_segment_ids: ids,
            edited: false,
        });
    }

    let mut language_notes: Vec<AiLanguageNote> = Vec::new();
    if has(AiBriefSection::LanguageNotes) {
        for item in value.get("language_notes").and_then(Value::as_array).into_iter().flatten() {
            let kind_name = text_of(item, "kind");
            let kind = AiLanguageNoteKind::parse(&kind_name);
            let (term, explanation, excerpt) =
                (text_of(item, "term"), text_of(item, "explanation"), text_of(item, "source_excerpt"));
            let ids = evidence(item, "evidence");
            if kind.as_str() != kind_name
                || term.is_empty()
                || explanation.is_empty()
                || excerpt.is_empty()
                || !cited_text(&ids).contains(&excerpt)
                || language_notes.iter().any(|n| n.kind == kind && normalized(&n.term) == normalized(&term))
                || language_notes.len() >= 12
            {
                continue;
            }
            language_notes.push(AiLanguageNote {
                id: stable_id(&format!("language-{}", kind.as_str()), &term, language_notes.len()),
                kind,
                term,
                explanation,
                source_excerpt: excerpt,
                evidence_segment_ids: ids,
                edited: false,
            });
        }
    }

    let brief = AiBrief {
        overview,
        overview_evidence_segment_ids: overview_evidence,
        chapters,
        insights,
        language_notes,
        learning_language: request.learning_language.clone(),
        learning_level: request.learning_level,
        output_language: request.output_language.clone(),
        model: request.model.clone(),
        selected_sections: request.sections.clone(),
        generated_at: now_iso(),
        source_transcript_updated_at: document.updated_at.clone(),
        edited: false,
    };
    if brief.is_empty() { Err("ai_brief_no_supported_content") } else { Ok(brief) }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::models::Segment;

    fn document() -> Document {
        let segment = |id: &str, text: &str| Segment { id: id.into(), text: text.into(), ..Default::default() };
        Document {
            segments: vec![
                segment("segment-1", "We ship on Friday."),
                segment("segment-2", "Ann will write the notes."),
            ],
            ..Default::default()
        }
    }

    fn request() -> BriefRequest {
        BriefRequest {
            sections: BriefRequest::default_sections(),
            output_language: "en".into(),
            learning_language: None,
            learning_level: AiLearningLevel::Intermediate,
            model: "m".into(),
        }
    }

    #[test]
    fn unsupported_items_and_unstated_owners_are_dropped() {
        let value = json!({
            "overview": "A release plan.", "overview_evidence": ["segment-1", "ghost"],
            "chapters": [{"title": "Plan", "summary": "s", "evidence": ["ghost"]}],
            "insights": [
                {"type": "decision", "text": "Ship Friday", "evidence": ["segment-1"], "deadline": "Friday", "owner": "Bob"},
                {"type": "actionItem", "text": "Write notes", "evidence": ["segment-2"], "owner": "Ann"},
                {"type": "rumor", "text": "x", "evidence": ["segment-1"]},
            ],
            "language_notes": [{"kind": "vocabulary", "term": "ship", "explanation": "e", "source_excerpt": "ship", "evidence": ["segment-1"]}],
        });
        let brief = brief_from_json(&value, &request(), &document()).unwrap();
        assert_eq!(brief.overview_evidence_segment_ids, ["segment-1"]);
        assert!(brief.chapters.is_empty());
        assert_eq!(brief.insights.len(), 2);
        assert_eq!(brief.insights[0].deadline.as_deref(), Some("Friday"));
        assert_eq!(brief.insights[0].owner, None);
        assert_eq!(brief.insights[1].owner.as_deref(), Some("Ann"));
        assert!(brief.language_notes.is_empty(), "language notes were not requested");
        assert_eq!(brief_from_json(&json!({}), &request(), &document()), Err("ai_brief_no_supported_content"));
    }

    #[test]
    fn a_reply_with_fences_and_prose_still_decodes() {
        let reply = "Sure {not json}. ```json\n{\"overview\": \"a } brace\", \"chapters\": []}\n```";
        assert_eq!(decode_reply(reply).unwrap()["overview"], "a } brace");
        assert!(decode_reply("no json").is_none());
    }

    #[test]
    fn prompts_name_sections_and_render_segments() {
        let chunks = chunks(&document());
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].starts_with("[id=segment-1][00:00] We ship on Friday."));
        let prompt = chunk_prompt(&request(), &chunks[0], 0, 1);
        assert!(prompt.contains("Requested sections: overview, chapters, keyIdeas, decisions, actionItems, openQuestions. Use only these insight types: keyIdea, notableMoment, decision, actionItem, openQuestion."));
        assert!(prompt.contains("Return language_notes as an empty array."));
    }
}
