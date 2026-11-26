//! Podcasts: shows, episodes and their downloads.

use super::*;

#[test]
fn an_episode_whose_download_broke_off_offers_to_fetch_it_again_instead_of_opening() {
    let mut it = start(
        "downloading",
        |root| {
            let job = json!({"id": "fetching", "source_path": "/nowhere/Episode.mp3", "status": "downloading"});
            std::fs::create_dir_all(root.join("jobs/fetching")).unwrap();
            std::fs::write(manifest(root, "fetching"), job.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.wait_for("Episode").unwrap();
    it.app.press("Episode").unwrap();
    it.app.wait_for("role:button[Retry] >> nth=1").unwrap();
    assert!(!it.app.screen().matches("No transcript yet").unwrap(), "with no media there is nothing to play");
}

#[test]
fn a_show_opens_from_discover_and_lists_its_episodes() {
    const FEED: &str = r#"<rss><channel><title>Daily English</title><author>BBC</author>
<item><title>Episode two</title><guid>g2</guid><pubDate>Tue, 04 Mar 2025 10:00:00 GMT</pubDate><enclosure url="https://cdn.example/b.mp3" type="audio/mpeg"/></item>
<item><title>Episode one</title><guid>g1</guid><pubDate>Mon, 03 Mar 2025 10:00:00 GMT</pubDate><enclosure url="https://cdn.example/a.mp3" type="audio/mpeg"/></item>
</channel></rss>"#;
    let lookup = r#"{"results":[{"kind":"podcast","collectionId":7,"collectionName":"Daily English","feedUrl":"https://feeds.example/daily","artistName":"BBC","artworkUrl100":""}]}"#;
    let mut it = start(
        "podcast",
        |_| {},
        vec![
            (format!("GET {}", podcast::lookup_url(podcast::FEATURED_IDS)), response(lookup)),
            ("GET https://feeds.example/daily".to_owned(), response(FEED)),
        ],
    );
    it.app.wait_for("Drop audio or video here").unwrap();
    it.app.press("role:button[Podcasts]").unwrap();
    it.app.wait_for("Daily English").unwrap();
    it.app.press("Daily English").unwrap();
    it.app.wait_for("Episode two").unwrap();
    assert!(it.app.shows("Episode one"));
    it.app.press("role:button[Follow]").unwrap();
    it.app.wait_for("role:button[Unfollow]").unwrap();
    let catalog = std::fs::read_to_string(it.root.join("podcast_catalog.json")).unwrap();
    assert!(catalog.contains("https://feeds.example/daily"), "the followed show is saved");
}

#[test]
fn home_continues_an_episode_of_a_show_not_followed() {
    let mut it = start(
        "home-episode",
        |root| {
            let catalog = json!({"version": 1, "feeds": [{"feed_url": "https://example.com/other.xml", "title": "Other Show", "episodes": [
                {"id": "left-1", "feed_url": "https://example.com/other.xml", "title": "Left halfway", "enclosure_url": "https://example.com/a.mp3", "media_extension": "mp3"},
            ]}]});
            std::fs::write(root.join("podcast_catalog.json"), catalog.to_string()).unwrap();
            let playback = json!({"version": 1, "entries": [
                {"episode_id": "left-1", "position_ms": 42000, "duration_ms": 600000, "updated_at": "2026-11-12T08:30:00.000Z"},
            ]});
            std::fs::write(root.join("podcast_playback.json"), playback.to_string()).unwrap();
        },
        Vec::new(),
    );
    it.app.press("role:button[Home]").unwrap();
    it.app.wait_for("Continue").unwrap();
    assert!(it.app.shows("Left halfway"));
    assert!(!it.app.shows("Start your library"));
}

#[test]
fn a_downloaded_episode_keeps_its_show_on_home() {
    let mut it = start(
        "home-downloaded",
        |root| {
            seed_transcript(root);
            let path = manifest(root, "sample");
            let mut job: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            job["source_origin"] = json!("podcast");
            job["podcast_provenance"] = json!({
                "feed_url": "https://example.com/aee.xml", "episode_id": "aee-2722",
                "enclosure_url": "https://example.com/aee-2722.mp3", "show_title": "All Ears English Podcast",
                "episode_title": "We Wager You'll Love This Episode",
            });
            std::fs::write(&path, job.to_string()).unwrap();
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
    assert!(it.app.shows("00:06 · All Ears English Podcast"));
    assert!(it.app.shows("2026-11-10 · All Ears English Podcast"));
}
