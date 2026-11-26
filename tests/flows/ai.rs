//! What the AI makes of a transcript: translations and briefs.

use super::*;

#[test]
fn translating_with_the_llm_fills_in_each_sentence() {
    let routes = llm_routes("1. 第一句\n2. 第二句\n3. 第三句\n4. 第四句\n5. 第五句");
    let mut it = start(
        "translate",
        |root| {
            seed_transcript(root);
            let _ = llm(root, "");
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            for segment in job["document"]["segments"].as_array_mut().unwrap() {
                segment.as_object_mut().unwrap().remove("translated_text");
            }
            std::fs::write(path, job.to_string()).unwrap();
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:More actions").unwrap();
    it.app.press("Translate…").unwrap();
    it.app.press("role:button[Translate]").unwrap();
    it.app.wait_for("第一句").unwrap();
    it.app.wait_for("第五句").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""status": "completed""#) && saved.contains("第三句"));
}

#[test]
fn an_ai_brief_is_generated_with_evidence_and_unsupported_items_dropped() {
    let brief = json!({
        "overview": "A talk about daily listening.", "overview_evidence": ["segment-2"],
        "chapters": [{"title": "Invented chapter", "summary": "No evidence.", "evidence": ["segment-99"]}],
        "insights": [{"type": "keyIdea", "text": "Consistency beats intensity.", "evidence": ["segment-3"]}],
        "language_notes": [],
    });
    let routes = llm_routes(&brief.to_string());
    let mut it = start(
        "brief",
        |root| {
            seed_transcript(root);
            let _ = llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:AI Brief").unwrap();
    it.app.wait_for("No AI Brief yet").unwrap();
    it.app.press("role:button[Create AI Brief]").unwrap();
    it.app.press("role:button[Generate]").unwrap();
    it.app.wait_for("A talk about daily listening.").unwrap();
    assert!(it.app.shows("Consistency beats intensity."));
    assert!(!it.app.shows("Invented chapter"), "a chapter citing no real sentence is dropped");
    it.app.press("label:Play from 00:03").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
}

#[test]
fn a_bolded_word_is_explained_as_the_expression_it_belongs_to() {
    let reply = json!({
        "learner_profile": "Around A2: you mark everyday phrases.",
        "highlights": [{
            "segment_id": "segment-5", "highlighted": "loud", "intent": "language", "kind": "expression",
            "term": "out loud", "explanation": "so that others can hear", "usage": "after verbs like read or say",
            "examples": ["Read it out loud."], "related": ["aloud"], "pitfalls": "", "source_excerpt": "out loud",
        }],
        "overview": "Daily listening helps.", "overview_evidence": ["segment-3"], "insights": [],
        "language_notes": [{"kind": "vocabulary", "term": "episodes", "explanation": "parts of a show",
            "source_excerpt": "episodes", "evidence": ["segment-5"]}],
    });
    let routes = llm_routes(&reply.to_string());
    let mut it = start(
        "highlight-learning",
        |root| {
            seed_transcript(root);
            seed_highlight(root, 4, "loud");
            let _ = llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    assert!(
        it.app.screen().in_selectable_view("Start with short episodes, and repeat each sentence out loud.").unwrap(),
        "a sentence can be selected"
    );
    assert!(it.app.screen().span_style("text:loud").unwrap().font_weight >= 600, "the highlight is bold");
    assert!(it.app.screen().span_style("text:Start").unwrap().font_weight < 600);
    it.app.press("label:AI Brief").unwrap();
    it.app.press("role:button[Create AI Brief]").unwrap();
    it.app.wait_for("1 highlights · the AI decides whether each is a word to learn or a key point.").unwrap();
    it.app.press("Language notes").unwrap();
    it.app.press("role:button[Generate]").unwrap();
    it.app.wait_for("From your highlights").unwrap();
    assert!(it.app.shows("out loud"));
    assert!(it.app.shows("You marked “loud”"));
    assert!(it.app.shows("Read it out loud."));
    assert!(it.app.shows("Around A2: you mark everyday phrases."));
    assert!(it.app.shows("Also worth learning") && it.app.shows("parts of a show"));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""learning_level": "auto""#), "the level follows the highlights");
}

#[test]
fn a_bolded_point_in_a_meeting_becomes_a_marked_key_idea() {
    let reply = json!({
        "learner_profile": "",
        "highlights": [{"segment_id": "segment-3", "highlighted": "Listening every day matters more than studying hard once a week.",
            "intent": "content", "point": "Daily practice beats weekly cramming."}],
        "overview": "A talk about habits.", "overview_evidence": ["segment-2"], "insights": [], "language_notes": [],
    });
    let routes = llm_routes(&reply.to_string());
    let mut it = start(
        "highlight-meeting",
        |root| {
            seed_transcript(root);
            seed_highlight(root, 2, "Listening every day matters more than studying hard once a week.");
            let _ = llm(root, "");
        },
        routes,
    );
    open_brief(&mut it);
    it.app.press("role:button[Generate]").unwrap();
    it.app.wait_for("Daily practice beats weekly cramming.").unwrap();
    assert!(it.app.screen().matches("label:You marked this").unwrap());
    assert!(!it.app.shows("From your highlights"), "a point is not a language note");
    assert!(!it.app.shows("new highlights since this brief"));
}
