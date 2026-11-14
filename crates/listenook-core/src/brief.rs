use std::collections::HashSet;

use serde_json::Value;

use crate::{
    format::clock,
    highlights::HighlightContext,
    models::{
        AiBrief, AiBriefSection, AiChapter, AiInsight, AiInsightType, AiLanguageNote, AiLanguageNoteKind,
        AiLearningLevel, Document, now_iso,
    },
};

pub const CHUNK_CHARACTERS: usize = 8000;

pub const SYSTEM_PROMPT: &str = "You turn timestamped transcripts into concise, trustworthy work products. Use only facts explicitly supported by the supplied segments. Every chapter and insight must cite one or more exact segment IDs. Never invent decisions, owners, deadlines, or questions. Language-learning explanations may use established linguistic knowledge, but every selected term and source excerpt must come from the cited transcript segments. Omit unsupported items. Return JSON only, with no Markdown fences.";

const SHAPE: &str = r#"{"overview":"concise overview or empty string","overview_evidence":["segment-id"],"chapters":[{"title":"...","summary":"...","evidence":["segment-id"]}],"insights":[{"type":"keyIdea|notableMoment|decision|actionItem|openQuestion","text":"...","owner":null,"deadline":null,"evidence":["segment-id"]}],"language_notes":[{"kind":"vocabulary|expression|grammar","term":"...","explanation":"...","source_excerpt":"...","evidence":["segment-id"]}]}"#;

pub const STUDY_SYSTEM_PROMPT: &str = "You help a person who bolded words or passages in a timestamped transcript. Some bold marks a word or expression the person wants to learn; some marks a point that matters to them, as in meeting notes. Decide which for each highlight, then explain the language highlights as a careful teacher would. Meanings must fit the cited context. Examples are your own: short, natural and correct. Return JSON only, with no Markdown fences.";

const STUDY_SHAPE: &str = r#"{"learner_profile":"... or empty string","highlights":[{"segment_id":"segment-id","highlighted":"the highlighted text","intent":"language|content","point":"...","kind":"vocabulary|expression|grammar","term":"...","explanation":"...","usage":"...","examples":["..."],"related":["..."],"pitfalls":"...","source_excerpt":"..."}]}"#;

pub const STUDY_BATCH: usize = 20;

#[derive(Debug, Clone, PartialEq)]
pub struct BriefRequest {
    pub sections: Vec<AiBriefSection>,
    pub output_language: String,
    pub learning_language: Option<String>,
    pub learning_level: AiLearningLevel,
    pub model: String,
    pub highlights: Vec<HighlightContext>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Moment {
    pub segment_id: String,
    pub highlighted: String,
    pub point: String,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Study {
    pub profile: String,
    pub notes: Vec<AiLanguageNote>,
    pub moments: Vec<Moment>,
}

impl BriefRequest {
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

    fn learns(&self) -> bool {
        self.sections.contains(&AiBriefSection::LanguageNotes)
    }

    fn level(&self, study: &Study) -> String {
        match self.learning_level {
            AiLearningLevel::Auto if !study.profile.is_empty() => {
                "the level the learner profile below estimates".to_owned()
            }
            AiLearningLevel::Auto => "intermediate level".to_owned(),
            level => format!("{} level", level.as_str()),
        }
    }

    fn learning(&self, whole: bool, study: &Study) -> String {
        if !self.learns() {
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
        let mut guide = String::new();
        if !study.profile.is_empty() {
            guide.push_str(&format!(
                "\nLearner profile inferred from what the learner highlighted: {}\nChoose items this learner most likely does not know yet, and follow the patterns the profile names.",
                study.profile
            ));
        }
        if !study.notes.is_empty() {
            let terms: Vec<&str> = study.notes.iter().map(|n| n.term.as_str()).collect();
            guide.push_str(&format!(
                "\nThe learner's own highlights are already explained; do not repeat these terms: {}.",
                terms.join("; ")
            ));
        }
        format!(
            "Language notes are requested for {language} at {}.{guide}\n{count} Balance vocabulary, reusable expressions, and grammar or usage when the evidence supports them.\nKeep term and source_excerpt in the learned language. Write explanation in the requested output language using clear, professional, level-appropriate wording.\nsource_excerpt must be a short verbatim substring of a cited transcript segment. Do not assess pronunciation, fluency, or speaker correctness, and do not create quizzes, corrections, or invented examples.",
            self.level(study)
        )
    }

    fn marked(&self, study: &Study, chunk: Option<&str>) -> String {
        let shown: Vec<String> = study
            .moments
            .iter()
            .filter(|m| chunk.is_none_or(|chunk| chunk.contains(&format!("[id={}]", m.segment_id))))
            .map(|m| format!("- [id={}] \"{}\": {}", m.segment_id, m.highlighted, m.point))
            .collect();
        if shown.is_empty()
            || (self.allowed_insights().is_empty() && !self.sections.contains(&AiBriefSection::Overview))
        {
            return String::new();
        }
        format!(
            "\nThe user marked these moments as important. Reflect them in the overview when relevant, and cover each with at least one insight of a fitting requested type that cites its segment ID:\n{}\n",
            shown.join("\n")
        )
    }
}

pub fn study_prompt(request: &BriefRequest, batch: &[HighlightContext], title: &str) -> String {
    let level = match request.learning_level {
        AiLearningLevel::Auto => "infer it from what they highlighted".to_owned(),
        level => format!("{} (as the learner set it)", level.as_str()),
    };
    let language_rule = if request.learns() {
        "For a language highlight: term is the whole expression the highlighted text belongs to in its context (if they bolded \"take\" inside \"take it for granted\", term is \"take it for granted\"); kind is vocabulary, expression (idioms, phrasal verbs, collocations) or grammar; explanation is its meaning in this context; usage says how and when to use it (register, common patterns); examples are 2–3 short natural sentences of your own; related lists synonyms, collocations or word-family members; pitfalls names a common mistake or confusion, or is empty; source_excerpt is a short verbatim substring of the highlighted sentence that contains the term. Keep term, examples, related and source_excerpt in the transcript's language; write explanation, usage and pitfalls in the output language.\nlearner_profile: when there are language highlights, 1–3 sentences estimating the learner's CEFR level from what they marked and naming patterns across their highlights; otherwise an empty string."
    } else {
        "Language notes were not requested: still classify every highlight, but leave the language fields and learner_profile empty."
    };
    let mut listed = String::new();
    for (index, highlight) in batch.iter().enumerate() {
        listed.push_str(&format!(
            "{}. segment_id={} highlighted=\"{}\"\n",
            index + 1,
            highlight.segment_id,
            highlight.selected
        ));
        for (id, line) in &highlight.lines {
            let marker = if *id == highlight.segment_id { " (the highlighted sentence)" } else { "" };
            listed.push_str(&format!("   [id={id}]{marker} {line}\n"));
        }
    }
    format!(
        "Recording title: \"{title}\".\nWrite all user-facing text in language code \"{}\".\nLearner level: {level}.\n\nFor each highlight decide its intent:\n- \"language\": marked to learn a word, phrase, idiom, collocation or structure. Typical: a short unit, an uncommon or idiomatic expression, especially when the transcript's language differs from the output language.\n- \"content\": marked because it matters, as in meeting notes. Typical: a claim, decision, task, number, date or name, or a whole clause in a meeting, interview or talk.\nFor a content highlight, point is one sentence in the output language saying what was marked and why it matters; leave the language fields empty.\n{language_rule}\n\nReturn exactly this JSON shape, with one item per highlight in order:\n{STUDY_SHAPE}\n\nHighlights:\n{listed}",
        request.output_language
    )
}

fn strings_of(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .take(6)
        .collect()
}

pub fn study_from_json(replies: &[Value], request: &BriefRequest, document: &Document) -> Study {
    let mut study = Study::default();
    for reply in replies {
        if study.profile.is_empty() && request.learns() {
            study.profile = text_of(reply, "learner_profile");
        }
        for item in reply.get("highlights").and_then(Value::as_array).into_iter().flatten() {
            let (segment_id, picked) = (text_of(item, "segment_id"), text_of(item, "highlighted"));
            let Some(asked) = request
                .highlights
                .iter()
                .filter(|h| h.segment_id == segment_id)
                .find(|h| normalized(&h.selected) == normalized(&picked))
                .or_else(|| request.highlights.iter().find(|h| h.segment_id == segment_id))
            else {
                continue;
            };
            let Some(segment) = document.segments.iter().find(|s| s.id == segment_id) else {
                continue;
            };
            if text_of(item, "intent") != "language" {
                if study.moments.iter().any(|m| m.segment_id == segment_id && m.highlighted == asked.selected) {
                    continue;
                }
                let point = Some(text_of(item, "point")).filter(|p| !p.is_empty()).unwrap_or(asked.selected.clone());
                study.moments.push(Moment { segment_id, highlighted: asked.selected.clone(), point });
                continue;
            }
            if !request.learns() {
                continue;
            }
            let explanation = text_of(item, "explanation");
            if explanation.is_empty() {
                continue;
            }
            let context = normalized(&asked.lines.iter().map(|(_, line)| line.as_str()).collect::<Vec<_>>().join(" "));
            let term = Some(text_of(item, "term"))
                .filter(|t| {
                    !t.is_empty()
                        && normalized(t).contains(&normalized(&asked.selected))
                        && context.contains(&normalized(t))
                })
                .unwrap_or_else(|| asked.selected.clone());
            if study.notes.iter().any(|n| normalized(&n.term) == normalized(&term)) {
                continue;
            }
            let excerpt = Some(text_of(item, "source_excerpt"))
                .filter(|e| !e.is_empty() && segment.text.contains(e.as_str()))
                .or_else(|| segment.text.contains(term.as_str()).then(|| term.clone()))
                .unwrap_or_else(|| asked.selected.clone());
            let kind_name = text_of(item, "kind");
            let kind = AiLanguageNoteKind::parse(&kind_name);
            study.notes.push(AiLanguageNote {
                id: stable_id("highlight", &term, study.notes.len()),
                kind,
                explanation,
                source_excerpt: excerpt,
                evidence_segment_ids: vec![segment_id],
                highlight: Some(asked.selected.clone()),
                usage: text_of(item, "usage"),
                examples: strings_of(item, "examples"),
                related: strings_of(item, "related"),
                pitfalls: text_of(item, "pitfalls"),
                term,
                edited: false,
            });
        }
    }
    study
}

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

pub fn chunk_prompt(request: &BriefRequest, study: &Study, chunk: &str, index: usize, total: usize) -> String {
    format!(
        "Analyze transcript chunk {} of {total}.\nWrite all user-facing text in language code \"{}\".\nRequested sections: {}.\n{}\n{}\nReturn exactly this JSON shape:\n{SHAPE}\n\nFor owner and deadline, use null unless the cited transcript states them explicitly. Keep overview_evidence to the smallest useful set of supporting segments.\n\nTranscript:\n{chunk}",
        index + 1,
        request.output_language,
        request.requested(),
        request.learning(total == 1, study),
        request.marked(study, Some(chunk)),
    )
}

pub fn synthesis_prompt(request: &BriefRequest, study: &Study, candidates: &[Value]) -> String {
    format!(
        "Synthesize the candidate analyses below into one non-repetitive brief.\nWrite all user-facing text in language code \"{}\".\nRequested sections: {}.\nPreserve only supplied evidence segment IDs. Do not introduce facts.\n{}\n{}\nReturn exactly this JSON shape:\n{SHAPE}\n\nCandidates:\n{}",
        request.output_language,
        request.requested(),
        request.learning(true, study),
        request.marked(study, None),
        Value::Array(candidates.to_vec()),
    )
}

pub fn decode_reply(reply: &str) -> Option<Value> {
    const KEYS: &[&str] =
        &["overview", "overview_evidence", "chapters", "insights", "language_notes", "highlights", "learner_profile"];
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
    let hash = normalized(text).bytes().fold(0x811c_9dc5_u32, |h, b| (h ^ u32::from(b)).wrapping_mul(0x0100_0193));
    format!("{prefix}-{hash:x}-{index}")
}

fn text_of(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or("").trim().to_owned()
}

pub fn brief_from_json(
    value: &Value,
    request: &BriefRequest,
    study: &Study,
    document: &Document,
) -> Result<AiBrief, &'static str> {
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
        let highlighted = study.moments.iter().any(|m| ids.contains(&m.segment_id));
        insights.push(AiInsight {
            id: stable_id(kind.as_str(), &text, insights.len()),
            kind,
            owner: stated("owner"),
            deadline: stated("deadline"),
            text,
            evidence_segment_ids: ids,
            highlighted,
            edited: false,
        });
    }
    if allowed.contains(&AiInsightType::KeyIdea) {
        for moment in &study.moments {
            if insights.iter().any(|i| i.evidence_segment_ids.contains(&moment.segment_id))
                || !known.contains(moment.segment_id.as_str())
            {
                continue;
            }
            insights.push(AiInsight {
                id: stable_id("keyIdea", &moment.point, insights.len()),
                kind: AiInsightType::KeyIdea,
                text: moment.point.clone(),
                evidence_segment_ids: vec![moment.segment_id.clone()],
                highlighted: true,
                ..AiInsight::default()
            });
        }
    }

    let mut language_notes: Vec<AiLanguageNote> = Vec::new();
    let mine = if has(AiBriefSection::LanguageNotes) { study.notes.clone() } else { Vec::new() };
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
                || mine.iter().any(|n| normalized(&n.term) == normalized(&term))
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
                ..AiLanguageNote::default()
            });
        }
    }
    let learner_profile = if mine.is_empty() { String::new() } else { study.profile.clone() };
    language_notes.splice(0..0, mine);

    let brief = AiBrief {
        overview,
        overview_evidence_segment_ids: overview_evidence,
        chapters,
        insights,
        language_notes,
        learner_profile,
        highlights_seen: request.highlights.iter().map(HighlightContext::key).collect(),
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
            highlights: Vec::new(),
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
        let brief = brief_from_json(&value, &request(), &Study::default(), &document()).unwrap();
        assert_eq!(brief.overview_evidence_segment_ids, ["segment-1"]);
        assert!(brief.chapters.is_empty());
        assert_eq!(brief.insights.len(), 2);
        assert_eq!(brief.insights[0].deadline.as_deref(), Some("Friday"));
        assert_eq!(brief.insights[0].owner, None);
        assert_eq!(brief.insights[1].owner.as_deref(), Some("Ann"));
        assert!(brief.language_notes.is_empty(), "language notes were not requested");
        assert_eq!(
            brief_from_json(&json!({}), &request(), &Study::default(), &document()),
            Err("ai_brief_no_supported_content")
        );
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
        let prompt = chunk_prompt(&request(), &Study::default(), &chunks[0], 0, 1);
        assert!(prompt.contains("Requested sections: overview, chapters, keyIdeas, decisions, actionItems, openQuestions. Use only these insight types: keyIdea, notableMoment, decision, actionItem, openQuestion."));
        assert!(prompt.contains("Return language_notes as an empty array."));
    }

    fn marked() -> (Document, BriefRequest) {
        use crate::{highlights, models::Highlight};
        let mut document = document();
        document.segments[0].text = "We ship on Friday, take it for granted.".into();
        document.segments[0].highlights = vec![Highlight { start: 19, end: 23 }];
        document.segments[1].highlights = vec![Highlight { start: 0, end: 25 }];
        let mut request = request();
        request.sections.push(AiBriefSection::LanguageNotes);
        request.learning_level = AiLearningLevel::Auto;
        request.highlights = highlights::contexts(&document);
        (document, request)
    }

    fn study_reply() -> Value {
        json!({
            "learner_profile": "Around B1; marks idioms.",
            "highlights": [
                {"segment_id": "segment-1", "highlighted": "take", "intent": "language", "kind": "expression",
                 "term": "take it for granted", "explanation": "assume", "usage": "informal",
                 "examples": ["Don't take me for granted."], "related": ["assume"], "pitfalls": "",
                 "source_excerpt": "take it for granted"},
                {"segment_id": "segment-2", "highlighted": "Ann will write the notes.", "intent": "content",
                 "point": "Ann owns the notes."},
            ]
        })
    }

    #[test]
    fn the_study_prompt_lists_each_highlight_with_its_context() {
        let (_, request) = marked();
        let prompt = study_prompt(&request, &request.highlights, "Standup");
        assert!(prompt.contains("segment_id=segment-1 highlighted=\"take\""));
        assert!(prompt.contains("[id=segment-1] (the highlighted sentence) We ship on Friday, take it for granted."));
        assert!(prompt.contains("[id=segment-2] Ann will write the notes."));
        assert!(prompt.contains("infer it from what they highlighted"));
    }

    #[test]
    fn highlights_split_into_language_notes_and_marked_moments() {
        let (document, request) = marked();
        let study = study_from_json(&[study_reply()], &request, &document);
        assert_eq!(study.profile, "Around B1; marks idioms.");
        assert_eq!(study.notes.len(), 1);
        assert_eq!(study.notes[0].term, "take it for granted");
        assert_eq!(study.notes[0].highlight.as_deref(), Some("take"));
        assert_eq!(
            study.moments,
            [Moment {
                segment_id: "segment-2".into(),
                highlighted: "Ann will write the notes.".into(),
                point: "Ann owns the notes.".into(),
            }]
        );
        let chunk = &chunks(&document)[0];
        let prompt = chunk_prompt(&request, &study, chunk, 0, 1);
        assert!(prompt.contains("- [id=segment-2] \"Ann will write the notes.\": Ann owns the notes."));
        assert!(prompt.contains("do not repeat these terms: take it for granted."));
        assert!(prompt.contains("at the level the learner profile below estimates"));
    }

    #[test]
    fn a_term_that_drops_the_highlight_falls_back_and_unrequested_notes_are_ignored() {
        let (document, mut request) = marked();
        let mut reply = study_reply();
        reply["highlights"][0]["term"] = json!("granted forever");
        let study = study_from_json(std::slice::from_ref(&reply), &request, &document);
        assert_eq!(study.notes[0].term, "take");
        request.sections.retain(|s| *s != AiBriefSection::LanguageNotes);
        let study = study_from_json(&[reply], &request, &document);
        assert!(study.notes.is_empty() && study.profile.is_empty());
        assert_eq!(study.moments.len(), 1);
    }

    #[test]
    fn a_marked_moment_the_model_left_out_comes_back_as_a_key_idea() {
        let (document, request) = marked();
        let study = study_from_json(&[study_reply()], &request, &document);
        let value = json!({
            "insights": [{"type": "decision", "text": "Ship Friday", "evidence": ["segment-1"]}],
            "language_notes": [
                {"kind": "expression", "term": "take it for granted", "explanation": "dup", "source_excerpt": "take it", "evidence": ["segment-1"]},
                {"kind": "vocabulary", "term": "ship", "explanation": "send out", "source_excerpt": "ship", "evidence": ["segment-1"]},
            ],
        });
        let brief = brief_from_json(&value, &request, &study, &document).unwrap();
        let restored = brief.insights.iter().find(|i| i.kind == AiInsightType::KeyIdea).unwrap();
        assert_eq!((restored.text.as_str(), restored.highlighted), ("Ann owns the notes.", true));
        assert!(!brief.insights[0].highlighted);
        let terms: Vec<&str> = brief.language_notes.iter().map(|n| n.term.as_str()).collect();
        assert_eq!(terms, ["take it for granted", "ship"]);
        assert_eq!(brief.learner_profile, "Around B1; marks idioms.");
    }

    #[test]
    fn a_brief_saved_before_highlights_still_loads() {
        let old = json!({"overview": "o", "language_notes": [{"id": "n", "kind": "grammar", "term": "t", "explanation": "e"}]});
        let brief: AiBrief = serde_json::from_value(old).unwrap();
        assert_eq!(brief.language_notes[0].highlight, None);
        assert!(brief.learner_profile.is_empty());
    }
}
