//! Home: what was played last, what was added, and the time spent learning.

use super::*;

#[test]
fn the_sleep_timer_shows_what_is_left_until_it_is_turned_off() {
    let mut it = open_sample("sleep");
    it.app.press("label:Sleep timer").unwrap();
    it.app.press("15 minutes").unwrap();
    it.app.wait_for("15:00").unwrap();
    it.app.press("label:Sleep timer").unwrap();
    it.app.press("When this recording ends").unwrap();
    it.app.wait_for_gone("15:00", GONE).unwrap();
    it.app.press("label:Sleep timer").unwrap();
    it.app.press("Off").unwrap();
    assert!(!it.app.shows("15:00"));
}

#[test]
fn search_finds_a_recording_by_a_sentence_of_its_transcript() {
    let mut it = start("found", seed_transcript, Vec::new());
    it.app.press("role:button[Home]").unwrap();
    it.app.press("label:Search").unwrap();
    it.app.type_text("text:Search your library", "Beginner").unwrap();
    it.app.wait_for("“So, what should a beginner do first?”").unwrap();
    assert!(it.app.shows("Learning languages"), "the sentence is shown under its recording");
    it.app.press("“So, what should a beginner do first?”").unwrap();
    it.app.wait_for("Start with short episodes, and repeat each sentence out loud.").unwrap();
}

#[test]
fn home_resumes_what_was_played_last_and_lists_what_was_added() {
    let mut it = start(
        "home",
        |root| {
            seed_transcript(root);
            let settings = json!({
                "playback_positions_ms": {"sample": 6000},
                "playback_played_at": {"sample": "2026-11-15T10:00:00.000Z"},
            });
            std::fs::write(root.join("settings.json"), settings.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Continue").unwrap();
    assert!(it.app.shows("Recently added"));
    it.app.press("label:Search").unwrap();
    it.app.type_text("text:Search your library", "nothing like this").unwrap();
    it.app.wait_for("No recordings match your search.").unwrap();
    it.app.press_key("escape").unwrap();
    it.app.wait_for("Recently added").unwrap();
    it.app.press("label:Resume Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
}

#[test]
fn home_shows_today_against_the_goal_and_the_days_before() {
    let mut it = start(
        "home-activity",
        |root| {
            seed_transcript(root);
            seed_activity(root);
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Today").unwrap();
    assert!(it.app.shows("of 20 min"));
    assert!(it.app.shows("12 min"));
    assert!(it.app.shows("6 min"));
    assert!(it.app.shows("4-day streak"));
    assert!(it.app.shows("2 min to go"));
    assert!(it.app.shows("Activity"));
    it.app.wait_for("label:Learning time, last 7 days").unwrap();
    it.app.press("Month").unwrap();
    it.app.wait_for("label:Learning time, last 30 days").unwrap();
    it.app.press("label:Daily goal").unwrap();
    it.app.press("10 min a day").unwrap();
    it.app.wait_for("Goal met").unwrap();
    it.app.wait_for("5-day streak").unwrap();
    let settings = std::fs::read_to_string(it.root.join("settings.json")).unwrap();
    assert!(settings.contains("\"daily_goal_minutes\": 10"), "{settings}");
}

#[test]
fn home_starts_today_at_nothing_without_history() {
    let mut it = start("home-no-activity", seed_transcript, Vec::new());
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Play something to start today's minutes.").unwrap();
    assert!(it.app.shows("of 20 min"));
    assert!(!it.app.shows("Activity"));
}

#[test]
fn a_card_comes_off_continue_and_recently_added_until_it_is_opened_again() {
    let mut it = start(
        "home-remove",
        |root| {
            seed_transcript(root);
            let settings = json!({
                "playback_positions_ms": {"sample": 6000},
                "playback_played_at": {"sample": "2026-11-15T10:00:00.000Z"},
            });
            std::fs::write(root.join("settings.json"), settings.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("label:Resume Learning languages").unwrap();

    it.app.long_press("label:Resume Learning languages").unwrap();
    it.app.press("Remove from Continue").unwrap();
    it.app.wait_for_gone("label:Resume Learning languages", GONE).unwrap();
    it.app.press("role:button[Undo]").unwrap();
    it.app.wait_for("label:Resume Learning languages").unwrap();

    it.app.long_press("label:Resume Learning languages").unwrap();
    it.app.press("Remove from Continue").unwrap();
    it.app.wait_for_gone("label:Resume Learning languages", GONE).unwrap();
    assert!(it.app.shows("Recently added"), "the recording itself stays");
    let settings = std::fs::read_to_string(it.root.join("settings.json")).unwrap();
    assert!(settings.contains("continue_hidden"), "the removal is kept");

    it.app.long_press("Learning languages").unwrap();
    it.app.press("Remove from Recently added").unwrap();
    it.app.wait_for_gone("Recently added", GONE).unwrap();
    assert!(manifest(&it.root, "sample").exists(), "nothing is deleted");

    it.app.press("Library").unwrap();
    it.app.press("Learning languages").unwrap();
    it.app.wait_for("Welcome back to the show.").unwrap();
    it.app.press("label:Back").unwrap();
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("label:Resume Learning languages").unwrap();
    assert!(!it.app.shows("Recently added"), "only Continue comes back");
}

#[test]
fn an_empty_library_invites_media_and_the_language_changes_at_once() {
    let mut it = start("empty", |_| {}, Vec::new());
    it.app.wait_for("Drop audio or video here").unwrap();
    it.app.press("role:button[Settings]").unwrap();
    it.app.wait_for("Appearance").unwrap();
    it.app.press("简体中文").unwrap();
    it.app.wait_for("资料库").unwrap();
    let settings = std::fs::read_to_string(it.root.join("settings.json")).unwrap();
    assert!(settings.contains("simplifiedChinese"), "the choice is saved");
}
