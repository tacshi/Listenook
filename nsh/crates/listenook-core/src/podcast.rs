//! Podcasts: the catalog models, Apple's search results, RSS feeds and
//! publisher transcripts.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    models::{Document, PodcastTranscriptReference, Segment, now_iso},
    subtitles,
};

/// A show in search results and charts.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ShowSummary {
    pub id: String,
    pub title: String,
    pub feed_url: String,
    pub author: String,
    pub artwork_url: String,
    pub genre: String,
}

/// One episode of a feed.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Episode {
    pub id: String,
    pub feed_url: String,
    pub title: String,
    pub enclosure_url: String,
    pub media_extension: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub published_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub transcripts: Vec<PodcastTranscriptReference>,
    /// What the Flutter app wrote that this one does not read: written back as it was.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// A show with its episodes, as fetched.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Feed {
    pub feed_url: String,
    pub title: String,
    pub episodes: Vec<Episode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fetched_at: Option<String>,
    /// What the Flutter app wrote that this one does not read: written back as it was.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// A show the user follows.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Followed {
    pub feed_url: String,
    pub title: String,
    pub followed_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    pub last_seen_episode_ids: Vec<String>,
    pub unseen_episode_count: u32,
    /// What the Flutter app wrote that this one does not read: written back as it was.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `podcast_catalog.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Catalog {
    pub version: u32,
    pub followed: Vec<Followed>,
    pub feeds: Vec<Feed>,
    /// What the Flutter app wrote that this one does not read: written back as it was.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for Catalog {
    fn default() -> Self {
        Self { version: 1, followed: Vec::new(), feeds: Vec::new(), extra: serde_json::Map::new() }
    }
}

/// How far the user listened to an episode.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ListenProgress {
    pub episode_id: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    /// What the Flutter app wrote that this one does not read: written back as it was.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl ListenProgress {
    /// Started and not finished: at least 3 s in, and 5 s or more from the end.
    pub fn is_continuable(&self) -> bool {
        self.position_ms >= 3000 && (self.duration_ms <= 0 || self.position_ms <= self.duration_ms - 5000)
    }
}

/// Apple's featured shows for studying English, by collection id.
pub const FEATURED_IDS: &[&str] = &[
    "751574016",
    "160904630",
    "262026947",
    "262026989",
    "312059190",
    "201671138",
    "152249110",
    "1028908750",
    "1200361736",
    "278981407",
    "290783428",
    "1545953110",
];

/// The search request for `term`.
pub fn search_url(term: &str) -> String {
    format!(
        "https://itunes.apple.com/search?term={}&media=podcast&entity=podcast&country=us&limit=25",
        url_encode(term)
    )
}

/// The lookup request for collection ids.
pub fn lookup_url(ids: &[&str]) -> String {
    format!("https://itunes.apple.com/lookup?id={}&entity=podcast", ids.join(","))
}

/// Apple's top-shows chart, of one genre or of all.
pub fn chart_url(genre: Option<u32>, limit: u32) -> String {
    let genre = genre.map(|id| format!("/genre={id}")).unwrap_or_default();
    format!("https://itunes.apple.com/us/rss/toppodcasts/limit={limit}{genre}/explicit=true/json")
}

/// The collection ids of a chart, in its order.
pub fn parse_chart_ids(body: &str) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let entries = match value.get("feed").and_then(|feed| feed.get("entry")) {
        Some(Value::Array(entries)) => entries.clone(),
        Some(entry @ Value::Object(_)) => vec![entry.clone()],
        _ => Vec::new(),
    };
    entries
        .iter()
        .filter_map(|entry| entry.get("id")?.get("attributes")?.get("im:id")?.as_str().map(str::to_owned))
        .collect()
}

/// The purposes the directory is browsed by: a name and Apple's genre.
pub const COLLECTIONS: &[(&str, u32)] = &[
    ("News English", 1489),
    ("Explainers", 1304),
    ("Interviews", 1324),
    ("Science in English", 1533),
    ("Business English", 1321),
    ("Stories", 1487),
];

/// Percent-encodes a query value.
pub fn url_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The shows of an iTunes search or lookup response.
pub fn parse_itunes(body: &str) -> Vec<ShowSummary> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let text = |item: &Value, key: &str| item.get(key).and_then(Value::as_str).unwrap_or("").trim().to_owned();
    value
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|item| item.get("kind").and_then(Value::as_str) == Some("podcast"))
        .map(|item| ShowSummary {
            id: item.get("collectionId").map(|v| v.to_string()).unwrap_or_default(),
            title: text(item, "collectionName"),
            feed_url: canonical_url(&text(item, "feedUrl")),
            author: text(item, "artistName"),
            artwork_url: Some(text(item, "artworkUrl600"))
                .filter(|u| !u.is_empty())
                .unwrap_or_else(|| text(item, "artworkUrl100")),
            genre: text(item, "primaryGenreName"),
        })
        .filter(|show| !show.title.is_empty() && !show.feed_url.is_empty())
        .collect()
}

/// A URL in the one form ids are made of: lower-cased scheme and host, no
/// trailing slash. Empty when it is not http or https.
pub fn canonical_url(url: &str) -> String {
    let url = url.trim();
    let Some((scheme, rest)) = url.split_once("://") else {
        return String::new();
    };
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return String::new();
    }
    let (host, path) = match rest.find(['/', '?']) {
        Some(at) => rest.split_at(at),
        None => (rest, ""),
    };
    let mut host = host.to_ascii_lowercase();
    for default_port in [":80", ":443"] {
        if (scheme == "http") == (default_port == ":80") {
            host = host.trim_end_matches(default_port).to_owned();
        }
    }
    let (path, query) = path.split_once('?').map_or((path, None), |(p, q)| (p, Some(q)));
    let path = path.trim_end_matches('/');
    match query {
        Some(query) => format!("{scheme}://{host}{path}?{query}"),
        None => format!("{scheme}://{host}{path}"),
    }
}

static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<[^>]*>").unwrap());
static BREAKS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)<br\s*/?>|</p>").unwrap());
static RFC822: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?").unwrap()
});

/// HTML as plain text: breaks and paragraph ends become new lines.
pub fn strip_html(html: &str) -> String {
    let broken = BREAKS.replace_all(html, "\n");
    let text = TAGS
        .replace_all(&broken, "")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");
    text.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

fn published(text: &str) -> Option<String> {
    let text = text.trim();
    if text.len() >= 10 && text.as_bytes()[4] == b'-' {
        return Some(text.to_owned());
    }
    let found = RFC822.captures(text)?;
    let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        .iter()
        .position(|m| found[2].eq_ignore_ascii_case(m))?
        + 1;
    Some(format!(
        "{}-{month:02}-{:02}T{:02}:{}:{}.000Z",
        &found[3],
        found[1].parse::<u32>().ok()?,
        found[4].parse::<u32>().ok()?,
        &found[5],
        found.get(6).map_or("00", |m| m.as_str()),
    ))
}

fn duration(text: &str) -> Option<i64> {
    let parts: Vec<f64> = text.trim().split(':').map(|p| p.parse::<f64>()).collect::<Result<_, _>>().ok()?;
    let seconds = parts.iter().fold(0.0, |total, part| total * 60.0 + part);
    (seconds > 0.0).then_some((seconds * 1000.0) as i64)
}

fn extension_of(url: &str, mime: Option<&str>) -> Option<String> {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    let from_path = path.rsplit('/').next().and_then(|name| name.rsplit_once('.')).map(|(_, e)| e.to_ascii_lowercase());
    if let Some(extension) = from_path.filter(|e| subtitles::MEDIA_EXTENSIONS.contains(&e.as_str())) {
        return Some(extension);
    }
    Some(
        match mime?.to_ascii_lowercase().as_str() {
            "audio/mpeg" | "audio/mp3" => "mp3",
            "audio/mp4" | "audio/x-m4a" | "audio/aac" => "m4a",
            "audio/wav" | "audio/x-wav" | "audio/wave" => "wav",
            "audio/ogg" | "application/ogg" => "ogg",
            "video/mp4" => "mp4",
            "video/x-matroska" => "mkv",
            "video/x-msvideo" | "video/avi" => "avi",
            _ => return None,
        }
        .to_owned(),
    )
}

/// An RSS document as a feed; `requested_url` is where it came from. The
/// error is the app's code: `podcast_invalid_feed` or `podcast_feed_empty`.
pub fn parse_feed(xml: &str, requested_url: &str) -> Result<Feed, &'static str> {
    let document = roxmltree::Document::parse(xml).map_err(|_| "podcast_invalid_feed")?;
    let channel = document.descendants().find(|n| n.has_tag_name("channel")).ok_or("podcast_invalid_feed")?;
    let child = |node: roxmltree::Node, name: &str| -> Option<String> {
        node.children()
            .find(|n| n.is_element() && n.tag_name().name() == name)
            .and_then(|n| n.text())
            .map(|t| t.trim().to_owned())
            .filter(|t| !t.is_empty())
    };
    let image = |node: roxmltree::Node| -> Option<String> {
        node.children()
            .filter(|n| n.is_element() && n.tag_name().name() == "image")
            .find_map(|n| n.attribute("href").map(str::to_owned).or_else(|| child(n, "url")))
    };
    let feed_url = canonical_url(requested_url);
    let title = child(channel, "title").ok_or("podcast_invalid_feed")?;
    let artwork = image(channel);
    let mut episodes: Vec<Episode> = Vec::new();
    for item in channel.children().filter(|n| n.has_tag_name("item")) {
        let enclosure = item
            .children()
            .filter(|n| n.is_element() && matches!(n.tag_name().name(), "enclosure" | "content"))
            .find_map(|n| {
                let url = n.attribute("url")?;
                Some((canonical_url(url), extension_of(url, n.attribute("type"))?))
            });
        let (Some((enclosure_url, media_extension)), Some(title)) = (enclosure, child(item, "title")) else {
            continue;
        };
        let guid = child(item, "guid");
        let key = guid.clone().map(|g| g.replace('\n', " ")).unwrap_or_else(|| enclosure_url.clone());
        let id = format!("{feed_url}\n{key}");
        if episodes.iter().any(|e| e.id == id) {
            continue;
        }
        let transcripts = item
            .children()
            .filter(|n| n.is_element() && n.tag_name().name() == "transcript")
            .filter_map(|n| {
                Some(PodcastTranscriptReference {
                    url: n.attribute("url").map(str::to_owned).or_else(|| n.text().map(|t| t.trim().to_owned()))?,
                    mime_type: n.attribute("type").map(str::to_owned),
                    language: n.attribute("language").map(str::to_owned),
                    rel: n.attribute("rel").map(str::to_owned),
                })
            })
            .filter(|t| !t.url.is_empty())
            .collect();
        episodes.push(Episode {
            extra: serde_json::Map::new(),
            id,
            feed_url: feed_url.clone(),
            title,
            enclosure_url,
            media_extension,
            guid,
            published_at: child(item, "pubDate").and_then(|d| published(&d)),
            duration_ms: child(item, "duration").and_then(|d| duration(&d)),
            description: child(item, "encoded")
                .or_else(|| child(item, "description"))
                .or_else(|| child(item, "summary")),
            artwork_url: image(item).or_else(|| artwork.clone()),
            transcripts,
        });
    }
    if episodes.is_empty() {
        return Err("podcast_feed_empty");
    }
    episodes.sort_by(|a, b| b.published_at.cmp(&a.published_at));
    Ok(Feed {
        extra: serde_json::Map::new(),
        feed_url,
        title,
        episodes,
        author: child(channel, "author").or_else(|| child(channel, "managingEditor")),
        description: child(channel, "description").or_else(|| child(channel, "summary")).map(|d| strip_html(&d)),
        artwork_url: artwork,
        language: child(channel, "language"),
        fetched_at: Some(now_iso()),
    })
}

/// A publisher's VTT or SRT transcript as a document, short cues joined
/// into sentences. JSON and untimed text are not read.
pub fn publisher_transcript(body: &str, reference: &PodcastTranscriptReference) -> Result<Document, &'static str> {
    let hint = format!("{} {}", reference.mime_type.as_deref().unwrap_or(""), reference.url).to_lowercase();
    let head = body.trim_start_matches('\u{feff}').trim_start();
    let extension = if hint.contains("vtt") || head.starts_with("WEBVTT") {
        "vtt"
    } else if hint.contains("srt") || hint.contains("subrip") || head.contains("-->") {
        "srt"
    } else {
        return Err("podcast_transcript_untimed");
    };
    let imported = subtitles::import_subtitles(body, extension, None).map_err(|_| "podcast_transcript_failed")?;
    let mut segments: Vec<Segment> = Vec::new();
    for cue in imported.document.segments {
        let text = cue.text.replace('\n', " ");
        match segments.last_mut() {
            Some(last)
                if last.speaker == cue.speaker
                    && !last.text.trim_end().ends_with(['.', '!', '?', '"', '\''])
                    && (0..=800).contains(&(cue.start_ms - last.end_ms))
                    && cue.end_ms - last.start_ms <= 24_000
                    && last.text.len() + text.len() < 280 =>
            {
                last.text = format!("{} {text}", last.text);
                last.end_ms = cue.end_ms;
            }
            _ => segments.push(Segment {
                id: cue.id,
                start_ms: cue.start_ms,
                end_ms: cue.end_ms,
                text,
                speaker: cue.speaker,
                preserve_boundary_before: true,
                ..Segment::default()
            }),
        }
    }
    Ok(Document { tokens: Vec::new(), segments, speakers: imported.document.speakers, updated_at: now_iso() })
}

/// The file name an episode is downloaded to.
pub fn download_file_name(episode: &Episode) -> String {
    let title: String = episode
        .title
        .chars()
        .map(|c| if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') { ' ' } else { c })
        .collect();
    let title: String = title.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(80).collect();
    let title = if title.trim().is_empty() { "episode" } else { title.trim() };
    let key = episode.id.split('\n').nth(1).unwrap_or("");
    let short: String = key.chars().filter(char::is_ascii_alphanumeric).take(10).collect();
    let short = if short.is_empty() { "episode".to_owned() } else { short };
    format!("{title} [{short}].{}", episode.media_extension)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FEED: &str = r#"<?xml version="1.0"?>
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
<channel><title>Daily English</title><itunes:author>BBC</itunes:author><language>en-gb</language>
<itunes:image href="https://img.example/show.jpg"/><description>&lt;p&gt;Learn &amp;amp; listen&lt;/p&gt;</description>
<item><title>Older</title><guid>g1</guid><pubDate>Mon, 03 Mar 2025 10:00:00 GMT</pubDate>
<enclosure url="https://CDN.example/a.mp3?x=1" type="audio/mpeg"/><itunes:duration>1:02:03</itunes:duration></item>
<item><title>Newer</title><guid>g2</guid><pubDate>Tue, 04 Mar 2025 10:00:00 GMT</pubDate>
<enclosure url="https://cdn.example/stream" type="audio/x-m4a"/><itunes:duration>90</itunes:duration>
<podcast:transcript url="https://cdn.example/b.vtt" type="text/vtt" language="en"/></item>
<item><title>No media</title></item>
</channel></rss>"#;

    #[test]
    fn a_feed_parses_newest_first_with_transcripts() {
        let feed = parse_feed(FEED, "https://Feeds.example/daily/").unwrap();
        assert_eq!(feed.feed_url, "https://feeds.example/daily");
        assert_eq!(feed.author.as_deref(), Some("BBC"));
        assert_eq!(feed.description.as_deref(), Some("Learn & listen"));
        assert_eq!(feed.episodes.len(), 2);
        let newer = &feed.episodes[0];
        assert_eq!(newer.title, "Newer");
        assert_eq!(newer.media_extension, "m4a");
        assert_eq!(newer.duration_ms, Some(90_000));
        assert_eq!(newer.transcripts[0].url, "https://cdn.example/b.vtt");
        assert_eq!(newer.id, "https://feeds.example/daily\ng2");
        assert_eq!(feed.episodes[1].enclosure_url, "https://cdn.example/a.mp3?x=1");
        assert_eq!(feed.episodes[1].duration_ms, Some(3_723_000));
        assert_eq!(feed.episodes[1].published_at.as_deref(), Some("2025-03-03T10:00:00.000Z"));
        assert_eq!(download_file_name(newer), "Newer [g2].m4a");
    }

    #[test]
    fn a_chart_gives_ids_in_order_whether_one_entry_or_many() {
        let many = r#"{"feed":{"entry":[{"id":{"attributes":{"im:id":"7"}}},{"id":{"attributes":{"im:id":"9"}}}]}}"#;
        assert_eq!(parse_chart_ids(many), ["7", "9"]);
        let one = r#"{"feed":{"entry":{"id":{"attributes":{"im:id":"3"}}}}}"#;
        assert_eq!(parse_chart_ids(one), ["3"]);
        assert!(parse_chart_ids("{}").is_empty());
        assert_eq!(
            chart_url(Some(1489), 9),
            "https://itunes.apple.com/us/rss/toppodcasts/limit=9/genre=1489/explicit=true/json"
        );
    }

    #[test]
    fn bad_feeds_have_codes() {
        assert_eq!(parse_feed("<html>", "https://x.example"), Err("podcast_invalid_feed"));
        assert_eq!(
            parse_feed("<rss><channel><title>T</title></channel></rss>", "https://x.example"),
            Err("podcast_feed_empty")
        );
    }

    #[test]
    fn itunes_results_keep_podcasts_with_feeds() {
        let body = r#"{"results":[{"kind":"podcast","collectionId":7,"collectionName":"Show","feedUrl":"HTTPS://A.example/f/","artistName":"Ann","artworkUrl100":"u"},{"kind":"song","collectionName":"x"}]}"#;
        let shows = parse_itunes(body);
        assert_eq!(shows.len(), 1);
        assert_eq!((shows[0].id.as_str(), shows[0].feed_url.as_str()), ("7", "https://a.example/f"));
        assert_eq!(
            search_url("a b&c"),
            "https://itunes.apple.com/search?term=a%20b%26c&media=podcast&entity=podcast&country=us&limit=25"
        );
    }

    #[test]
    fn publisher_cues_join_into_sentences() {
        let vtt = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello and\n\n00:01.200 --> 00:02.000\nwelcome.\n\n00:02.100 --> 00:03.000\nNext.";
        let reference = PodcastTranscriptReference { url: "https://x.example/t.vtt".into(), ..Default::default() };
        let document = publisher_transcript(vtt, &reference).unwrap();
        let texts: Vec<&str> = document.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["Hello and welcome.", "Next."]);
        assert!(publisher_transcript("plain words", &reference).is_err());
    }

    #[test]
    fn listening_continues_between_the_start_and_the_end() {
        let at = |position_ms| ListenProgress { position_ms, duration_ms: 60_000, ..Default::default() };
        assert!(!at(1000).is_continuable());
        assert!(at(30_000).is_continuable());
        assert!(!at(58_000).is_continuable());
    }
}
