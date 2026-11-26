//! The reader: playing, repeating, editing, skipping and dictating sentences.

use super::*;

#[test]
fn a_transcript_opens_from_the_library_and_search_filters_it() {
    let mut it = open_sample("search");
    assert!(it.app.shows("欢迎回到节目。"), "a translated transcript opens bilingual");
    it.app.press("label:Search transcript").unwrap();
    it.app.type_text("text:Search transcript", "beginner").unwrap();
    it.app.wait_for_gone("Welcome back to the show.", GONE).unwrap();
    it.app.press("label:Clear search").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.wait_for_gone("label:Clear search", GONE).unwrap();
}

#[test]
fn scrolling_away_from_the_sentence_playing_offers_a_way_back_to_it() {
    let mut it = start("follow", seed_long_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Sentence 1 says something about learning.").unwrap();
    it.app.press("Sentence 2 says something about learning.").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
    assert!(!it.app.shows("Jump to playing"), "nothing to jump to while the list follows");
    it.app.scroll("Sentence 3 says something about learning.", px(1500.0)).unwrap();
    it.app.wait_for("Jump to playing").unwrap();
    it.app.press("Jump to playing").unwrap();
    it.app.wait_for("Sentence 2 says something about learning.").unwrap();
    it.app.wait_for_gone("Jump to playing", GONE).unwrap();
}

#[test]
fn command_b_in_the_reader_hides_the_sidebar_unless_words_are_selected() {
    let mut it = open_sample("command-b");
    assert!(it.app.shows("Podcasts"), "the sidebar shows beside the reader");
    it.app.press_key("mod+b").unwrap();
    it.app.wait_for_gone("Podcasts", GONE).unwrap();
    it.app.press_key("mod+b").unwrap();
    it.app.wait_for("Podcasts").unwrap();
}

#[test]
fn view_modes_show_the_original_the_translation_or_both() {
    let mut it = open_sample("modes");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Translated").unwrap();
    it.app.wait_for_gone("Welcome back to the show.", GONE).unwrap();
    assert!(it.app.shows("欢迎回到节目。"));
    it.app.press("role:button[Translated]").unwrap();
    it.app.press("Original").unwrap();
    it.app.wait_for_gone("欢迎回到节目。", GONE).unwrap();
    assert!(it.app.shows("Welcome back to the show."));
}

#[test]
fn a_long_translation_wraps_within_its_sentence_shown_or_hidden() {
    // Chinese has no spaces to break at, so only the sentence's width can make it wrap.
    const LONG: &str = concat!(
        "这些措施是为了阻止船只出海。可一旦到了海上，就是另一回事了。总有人提议把船拖回法国，",
        "但法国的政策是，移民一旦出海，就不再干预。海事数据也印证了这一点。",
        "这些措施是为了阻止船只出海。可一旦到了海上，就是另一回事了。总有人提议把船拖回法国，",
        "但法国的政策是，移民一旦出海，就不再干预。",
    );
    let mut it = start(
        "long-translation",
        |root| {
            seed_transcript(root);
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            job["document"]["segments"][0]["translated_text"] = json!(LONG);
            std::fs::write(path, job.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for(LONG).unwrap();
    let right_of = |it: &App, selector: &str| {
        let screen = it.app.screen();
        let id = screen.id(selector).unwrap();
        let bounds = screen.layout_nodes().into_iter().find(|node| node.id == id).unwrap().bounds;
        bounds.origin.x + bounds.size.width
    };
    let edit = {
        let screen = it.app.screen();
        let id = screen.press_target("label:Edit >> nth=0").unwrap().unwrap();
        screen.layout_nodes().into_iter().find(|node| node.id == id).unwrap().bounds.origin.x
    };
    let shown = right_of(&it, LONG);
    assert!(shown <= edit, "the translation ends at {shown:?}, past its sentence's Edit button at {edit:?}");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("label:Hidden sentence").unwrap();
    let hidden = right_of(&it, "label:Hidden sentence >> nth=0");
    assert!(hidden <= edit, "the hidden sentence ends at {hidden:?}, past its Edit button at {edit:?}");
}

#[test]
fn an_edited_sentence_is_saved_to_the_manifest() {
    let mut it = open_sample("edit");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("Welcome to the programme.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("Welcome to the programme."));
}

#[test]
fn one_edit_changes_the_sentence_and_its_translation() {
    let mut it = open_sample("edit-both");
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.clear("id:translation-editor").unwrap();
    it.app.type_text("id:translation-editor", "欢迎收听节目。").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("欢迎收听节目。").unwrap();
    assert!(it.app.shows("Welcome to the programme."));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("Welcome to the programme."));
    assert!(saved.contains("欢迎收听节目。"));
}

#[test]
fn a_tap_on_the_repeat_button_loops_the_sentence_and_a_tap_on_any_looping_one_ends_it() {
    let mut it = open_sample("repeat-tap");
    let rails = |it: &App| it.app.screen().count("id:repeat-rail").unwrap();
    it.app.press("label:Repeat sentence >> nth=1").unwrap();
    it.app.wait_for("id:repeat-rail").unwrap();
    assert_eq!(rails(&it), 1);
    it.app.press("Today we are talking about how people learn languages.").unwrap();
    assert_eq!(rails(&it), 1, "a tap on the sentence itself plays it and keeps the repeat");
    it.app.press("label:Repeat sentence >> nth=1").unwrap();
    it.app.wait_for_gone("id:repeat-rail", GONE).unwrap();
}

#[test]
fn dragging_the_repeat_button_loops_every_sentence_the_finger_passes() {
    let mut it = open_sample("repeat-drag");
    let rails = |it: &App| it.app.screen().count("id:repeat-rail").unwrap();
    it.app.drag_and_hold("label:Repeat sentence >> nth=0", point(px(0.0), px(160.0)), DragOptions::default()).unwrap();
    let held = rails(&it);
    assert!(held > 1, "the repeat grows while the finger is still down: {held}");
    it.app.drop_held().unwrap();
    assert_eq!(rails(&it), held, "lifting the finger keeps the repeat");
    it.app.drag("label:Repeat sentence >> nth=3", point(px(0.0), px(-1000.0)), DragOptions::default()).unwrap();
    assert_eq!(rails(&it), 4, "dragged up, the repeat runs from the top sentence to the one the drag started on");
    it.app.press("label:Repeat sentence >> nth=1").unwrap();
    it.app.wait_for_gone("id:repeat-rail", GONE).unwrap();
}

#[test]
fn a_short_repeat_drag_after_scrolling_takes_in_a_sentence_or_two() {
    let mut it = start("repeat-scrolled", seed_long_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Sentence 1 says something about learning.").unwrap();
    it.app
        .drag("Sentence 3 says something about learning.", point(px(0.0), px(-700.0)), DragOptions::default())
        .unwrap();
    it.app
        .drag("Sentence 12 says something about learning.", point(px(0.0), px(300.0)), DragOptions::default())
        .unwrap();
    it.app.drag("label:Repeat sentence >> nth=8", point(px(0.0), px(90.0)), DragOptions::default()).unwrap();
    let rails = it.app.screen().count("id:repeat-rail").unwrap();
    assert!((2..=3).contains(&rails), "a short drag takes in a sentence or two: {rails}");
}

#[test]
fn holding_a_repeat_drag_near_the_bottom_edge_scrolls_and_keeps_stretching_the_repeat() {
    let mut it = start("repeat-autoscroll", seed_long_transcript, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Sentence 1 says something about learning.").unwrap();
    it.app.drag_and_hold("label:Repeat sentence >> nth=0", point(px(0.0), px(680.0)), DragOptions::default()).unwrap();
    it.app.wait(Duration::from_millis(1500)).unwrap();
    it.app.drop_held().unwrap();
    assert!(!it.app.shows("Sentence 1 says something about learning."), "the list scrolled");
    let rails = it.app.screen().count("id:repeat-rail").unwrap();
    assert!(rails > 5, "the repeat reached sentences that were below the fold: {rails}");
}

#[test]
fn saving_an_emptied_sentence_deletes_it() {
    let mut it = open_sample("delete");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for_gone("role:button[Save]", GONE).unwrap();
    assert!(!it.app.shows("Welcome back to the show."));
    assert!(it.app.shows("Today we are talking about how people learn languages."));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("segment-1\""));
    assert!(saved.contains("segment-2"));

    it.app.press("role:button[Undo]").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("segment-1\""), "Undo puts the sentence back");
}

#[test]
fn deleting_a_sentence_from_the_editor_can_be_undone() {
    let mut it = open_sample("delete-button");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=1").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.press("label:More sentence actions").unwrap();
    it.app.press("Delete sentence").unwrap();
    it.app.wait_for_gone("Today we are talking about how people learn languages.", GONE).unwrap();
    it.app.wait_for("Sentence deleted").unwrap();
    it.app.press_key("mod+z").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
    it.app.press_key("mod+z").unwrap();
    assert!(it.app.shows("Today we are talking about how people learn languages."), "one step back only");
}

#[test]
fn a_skipped_sentence_folds_away_and_comes_back() {
    let mut it = open_sample("skip");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=1").unwrap();
    it.app.wait_for("role:button[Save]").unwrap();
    it.app.press("label:More sentence actions").unwrap();
    it.app.press("Skip this sentence").unwrap();
    it.app.wait_for_gone("Today we are talking about how people learn languages.", GONE).unwrap();
    it.app.wait_for("Skipped · 00:02").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains(r#""skipped": true"#), "the skip is saved");
    it.app.press("role:button[Bring back]").unwrap();
    it.app.wait_for("Today we are talking about how people learn languages.").unwrap();
    assert!(!it.app.shows("Skipped · 00:02"));
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains(r#""skipped""#), "bringing it back leaves no trace");
}

#[test]
fn the_arrow_keys_step_over_a_skipped_sentence() {
    let mut it = start("arrows-skip", seed_with_skipped, Vec::new());
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press_key("right").unwrap();
    it.app.wait_for("00:05").unwrap();
    assert!(!it.app.shows("00:02"), "the skipped sentence is not a stop");
    it.app.press_key("left").unwrap();
    it.app.wait_for_gone("00:05", GONE).unwrap();
    assert!(!it.app.shows("00:02"));
}

#[test]
fn a_stretch_of_sentences_is_skipped_by_picking_its_first_and_last() {
    let mut it = open_sample("skip-range");
    it.app.long_press("Welcome back to the show.").unwrap();
    it.app.press("Skip from here…").unwrap();
    it.app.wait_for("Now tap the last sentence to skip.").unwrap();
    // The menu takes Escape until it has faded out; the key is for the reader once it is gone.
    it.app.wait_for_gone("role:menu", GONE).unwrap();
    it.app.press_key("escape").unwrap();
    it.app.wait_for_gone("Now tap the last sentence to skip.", GONE).unwrap();
    it.app.press("Start with short episodes, and repeat each sentence out loud.").unwrap();
    assert!(it.app.shows("Welcome back to the show."), "Escape leaves nothing half picked");

    it.app.long_press("So, what should a beginner do first?").unwrap();
    it.app.press("Skip from here…").unwrap();
    it.app.wait_for("Now tap the last sentence to skip.").unwrap();
    it.app.press("Today we are talking about how people learn languages.").unwrap();
    it.app.wait_for("Skipped · 00:08").unwrap();
    assert!(!it.app.shows("Now tap the last sentence to skip."));
    assert!(!it.app.shows("Listening every day matters more than studying hard once a week."));
    assert!(!it.app.shows("So, what should a beginner do first?"));
    assert!(it.app.shows("Welcome back to the show."));
    assert!(it.app.shows("Start with short episodes, and repeat each sentence out loud."));
}

#[test]
fn the_ai_finds_ads_and_they_are_skipped_on_one_tap() {
    let reply = json!({"ads": [{"first": "segment-2", "last": "segment-3", "reason": "sponsor read"}]});
    let routes = llm_routes(&reply.to_string());
    let mut it = start(
        "find-ads",
        |root| {
            seed_transcript(root);
            let _ = llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:More actions").unwrap();
    it.app.press("Find ads").unwrap();
    it.app.wait_for("Ads found: 1 · 00:05").unwrap();
    assert!(it.app.shows("Today we are talking about how people learn languages."), "nothing is skipped yet");
    it.app.press("role:button[Skip them]").unwrap();
    it.app.wait_for_gone("Today we are talking about how people learn languages.", GONE).unwrap();
    assert!(!it.app.shows("Listening every day matters more than studying hard once a week."));
    it.app.wait_for("Skipped · 00:05").unwrap();
    assert!(!it.app.shows("Ads found: 1 · 00:05"), "the findings are done with");
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert_eq!(saved.matches(r#""skipped": true"#).count(), 2);
    assert!(!saved.contains("ad_scan"), "nothing is left waiting");
}

#[test]
fn the_arrow_keys_move_between_sentences() {
    let mut it = open_sample("arrows");
    it.app.press_key("right").unwrap();
    it.app.wait_for("00:02").unwrap();
    it.app.press_key("right").unwrap();
    it.app.wait_for("00:05").unwrap();
    it.app.press_key("left").unwrap();
    it.app.wait_for("00:02").unwrap();
    assert!(!it.app.shows("00:05"));
}

#[test]
fn tapping_a_sentence_plays_from_there() {
    let mut it = open_sample("tap-plays");
    it.app.press("Listening every day matters more than studying hard once a week.").unwrap();
    it.app.wait_for("00:05").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
    it.app.press("So, what should a beginner do first?").unwrap();
    it.app.wait_for("00:08").unwrap();
    it.app.wait_for("role:button[Pause playback]").unwrap();
}

#[test]
fn dictation_checks_the_answer_without_showing_the_sentence() {
    let mut it = open_sample("dictation");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:Type what you hear").unwrap();
    it.app.wait_for("label:Hidden sentence").unwrap();
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Listen again and retry.").unwrap();
    it.app.wait_for("label:Checked answer").unwrap();
    assert!(it.app.shows("…"), "the missing word is marked without showing it");
    it.app.wait_for("Type the missing word where the caret is.").unwrap();
    // The missing word gets a space of its own to be typed into.
    it.app.clear("text:welcome  to the show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    // A word typed wrong comes selected, to type over.
    it.app.type_text("text:Type what you hear", "welcome back to a show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Type to replace the first mistake.").unwrap();
    // Missed twice: a hint, first letters then the word, and slower.
    it.app.wait_for("Playing slower: 0.75×").unwrap();
    it.app.press("role:button[Hint]").unwrap();
    it.app.wait_for("Hint: t••").unwrap();
    it.app.press("role:button[Show word]").unwrap();
    it.app.wait_for("Hint: the").unwrap();
    it.app.clear("text:welcome back to a show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    // A letter off is close, not wrong.
    it.app.type_text("text:Type what you hear", "welcome bak to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Close: check the spelling, and type to replace it.").unwrap();
    it.app.clear("text:welcome bak to the show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.press("role:button[Check]").unwrap();
    it.app.wait_for("Matches transcript").unwrap();
    // Mimic shares the card, and Practice opens in the mode used last.
    it.app.press("Mimic").unwrap();
    it.app.wait_for("Reps").unwrap();
    // The card steps between sentences itself, without the transport.
    it.app.press("label:Next sentence >> nth=0").unwrap();
    it.app.wait_for("text:/^Sentence 2 ·/").unwrap();
    it.app.wait_for_gone("text:Type what you hear", GONE).unwrap();
    it.app.press("label:Practice").unwrap();
    it.app.wait_for_gone("Reps", GONE).unwrap();
    it.app.press("label:Practice").unwrap();
    it.app.wait_for("Reps").unwrap();
}

#[test]
fn type_answer_remembers_the_sentences_missed_and_goes_back_over_them() {
    let mut it = open_sample("dictation-review");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:/^Sentence 1 ·/").unwrap();
    let saved = || std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    // Wrong at the first check: to review, kept with the recording.
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.submit("text:welcome to the show").unwrap();
    it.app.wait_for("Missed 1").unwrap();
    it.app.wait_for("Sentence 1 · 0/1 first try").unwrap();
    assert!(saved().contains("\"to_review\": true"), "the miss is saved");
    // Right after a miss, it stays to review; the next one comes.
    it.app.clear("text:welcome  to the show").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    it.app.wait_for("text:/^Sentence 2 ·/").unwrap();
    assert!(it.app.shows("Missed 1"));
    // Missed only: back to it; right at the first try now, it is done with.
    it.app.press("Missed 1").unwrap();
    it.app.wait_for("text:/^Sentence 1 ·/").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    it.app.wait_for("That's all to review.").unwrap();
    it.app.wait_for("Right at the first try: 1/2").unwrap();
    it.app.wait_for_gone("Missed 1", GONE).unwrap();
    // The sentence's own controls leave with it: the summary has its own.
    it.app.wait_for_gone("role:button[Check]", GONE).unwrap();
    assert!(!it.app.shows("label:Replay"));
    assert!(!it.app.shows("text:/^Sentence 1 ·/"));
    assert!(!saved().contains("to_review"), "done with, it is no longer saved as missed");
}

#[test]
fn dictation_checks_on_return_and_moves_on_by_itself() {
    let mut it = open_sample("dictation-return");
    it.app.press("label:Practice").unwrap();
    it.app.press("Type answer").unwrap();
    it.app.wait_for("text:/^Sentence 1 ·/").unwrap();
    it.app.wait_for("label:Hidden sentence >> nth=4").unwrap();
    it.app.type_text("text:Type what you hear", "welcome to the show").unwrap();
    it.app.submit("text:welcome to the show").unwrap();
    it.app.wait_for("Listen again and retry.").unwrap();
    it.app.wait_for("label:Checked answer").unwrap();
    it.app.submit("text:welcome  to the show").unwrap();
    it.app.wait_for_gone("label:Checked answer", GONE).unwrap();
    it.app.clear("text:welcome  to the show").unwrap();
    it.app.type_text("text:Type what you hear", "welcome back to the show").unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    it.app.wait_for("Matches transcript").unwrap();
    // The return repeated a moment later (iPadOS does, 0.6 s on) leaves the
    // marks up: the next sentence comes by itself.
    it.app.wait(Duration::from_millis(700)).unwrap();
    it.app.submit("text:welcome back to the show").unwrap();
    assert!(it.app.shows("Matches transcript"), "a repeated return does not skip the marks");
    it.app.wait_for("text:/^Sentence 2 ·/").unwrap();
    it.app.wait_for("text:Type what you hear").unwrap();
    // The sentence typed right stays shown: four of the five are hidden.
    it.app.wait_for_gone("label:Hidden sentence >> nth=4", GONE).unwrap();
    it.app.wait_for("label:Hidden sentence >> nth=3").unwrap();
}

#[test]
fn a_highlight_follows_its_words_when_sentences_merge() {
    let mut it = start(
        "highlight-merge",
        |root| {
            seed_transcript(root);
            seed_highlight(root, 1, "learn languages");
        },
        Vec::new(),
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.press("role:button[Merge with next]").unwrap();
    it.app.wait_for("Welcome back to the show. Today we are talking about how people learn languages.").unwrap();
    assert!(it.app.screen().span_style("text:learn languages").unwrap().font_weight >= 600);
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    let merged = &saved["document"]["segments"][0];
    let text = merged["text"].as_str().unwrap();
    let (start, end) =
        (merged["highlights"][0]["start"].as_u64().unwrap(), merged["highlights"][0]["end"].as_u64().unwrap());
    assert_eq!(&text[start as usize..end as usize], "learn languages");
}

#[test]
fn two_sentences_are_merged_from_the_editor() {
    let mut it = open_sample("merge");
    it.app.press("role:button[Bilingual]").unwrap();
    it.app.press("Original").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the show.").unwrap();
    it.app.press("role:button[Merge with next]").unwrap();
    it.app.wait_for("Welcome to the show. Today we are talking about how people learn languages.").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("\"segment-2\""), "the second sentence is gone from the manifest");
}

#[test]
fn translate_again_fills_the_box_from_the_edited_sentence_and_waits_for_save() {
    let routes = llm_routes("1. 欢迎收听节目。");
    let mut it = start(
        "translate-draft",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("label:Translate again").unwrap();
    translation_box(&mut it, "欢迎收听节目。");
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(!saved.contains("欢迎收听节目。"), "nothing is saved before Save");
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("欢迎收听节目。").unwrap();
    let saved = std::fs::read_to_string(manifest(&it.root, "sample")).unwrap();
    assert!(saved.contains("Welcome to the programme.") && saved.contains("欢迎收听节目。"));
}

#[test]
fn a_sentence_waits_in_place_for_its_translation_and_an_undo_drops_a_late_one() {
    let mut routes = llm_routes("1. 欢迎收听节目。");
    routes[0].1.delay = Duration::from_millis(1000);
    let mut it = start(
        "translate-late",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("欢迎回到节目。").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("label:Translating").unwrap();
    assert!(it.app.shows("欢迎回到节目。"), "the old translation stays while it waits");
    it.app.press("role:button[Undo]").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.wait_for_gone("label:Translating", GONE).unwrap();
    it.app.wait(Duration::from_millis(300)).unwrap();
    assert!(!it.app.shows("欢迎收听节目。"), "the reply was for the undone text");
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    assert_eq!(saved["document"]["segments"][0]["translated_text"], "欢迎回到节目。");
}

#[test]
fn a_corrected_sentence_with_its_translation_untouched_is_translated_again_on_save() {
    let routes = llm_routes("1. 欢迎收听节目。");
    let mut it = start(
        "translate-on-save",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("欢迎回到节目。").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome to the programme.").unwrap();
    it.app.press("role:button[Save]").unwrap();
    it.app.wait_for("欢迎收听节目。").unwrap();
    assert!(!it.app.shows("欢迎回到节目。"), "the old translation is replaced");
    assert!(!it.app.shows("label:Translating"), "the sentence is done waiting");
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    assert_eq!(saved["document"]["segments"][0]["text"], "Welcome to the programme.");
    assert_eq!(saved["document"]["segments"][0]["translated_text"], "欢迎收听节目。");
    assert_ne!(
        saved["translation_state"]["status"], "translating",
        "one sentence leaves the recording's translation alone"
    );
    assert_ne!(saved["translation_state"]["total_segments"], 1);
}

#[test]
fn both_halves_of_a_split_sentence_are_translated_again() {
    let routes = llm_routes("1. 欢迎收听节目。");
    let mut it = start(
        "translate-on-split",
        |root| {
            seed_transcript(root);
            llm(root, "");
        },
        routes,
    );
    it.app.wait_for("Learning languages").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("欢迎回到节目。").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    // Headless typing keeps the caret at the end of the text: 13 characters put it there, and
    // the sentence opened again reads "Welcome back to the show." around it.
    it.app.clear("id:segment-editor").unwrap();
    it.app.type_text("id:segment-editor", "Welcome back ").unwrap();
    it.app.press("role:button[Cancel]").unwrap();
    it.app.press("label:Edit >> nth=0").unwrap();
    it.app.wait_for("id:translation-editor").unwrap();
    it.app.press("role:button[Split at cursor]").unwrap();
    it.app.wait_for("to the show.").unwrap();
    it.app.wait_for_gone("欢迎回到节目。", GONE).unwrap();
    it.app.wait_for_gone("label:Translating", GONE).unwrap();
    let saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(manifest(&it.root, "sample")).unwrap()).unwrap();
    let segments = &saved["document"]["segments"];
    assert_eq!(segments[0]["text"], "Welcome back");
    assert_eq!(segments[1]["text"], "to the show.");
    assert_eq!(segments[0]["translated_text"], "欢迎收听节目。", "the first half loses the whole sentence's");
    assert_eq!(segments[1]["translated_text"], "欢迎收听节目。", "the second half gets one");
}
