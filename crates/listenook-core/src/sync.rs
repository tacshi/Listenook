use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    activity::Activity,
    models::{Job, LibraryCatalog, Named},
    podcast::{Catalog, Feed, Followed, ListenProgress},
};

/// 3: sync runs over TLS between devices that know each other's certificate, and pairing
/// checks the code with SPAKE2.
pub const PROTOCOL: u32 = 3;
pub const CODE_LENGTH: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Device {
    pub app: String,
    pub protocol: u32,
    pub id: String,
    pub name: String,
    pub platform: String,
    pub port: u16,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub revision: String,
}

impl Device {
    pub fn is_compatible(&self) -> bool {
        self.app == "listenook" && self.protocol == PROTOCOL && !self.id.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Entry {
    pub id: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_name: Option<String>,
    pub media_size: u64,
    pub busy: bool,
}

impl Entry {
    pub fn of(job: &Job, media_size: Option<u64>) -> Entry {
        Entry {
            id: job.id.clone(),
            updated_at: job.updated_at.clone(),
            media_name: media_size.map(|_| job.file_name()),
            media_size: media_size.unwrap_or(0),
            busy: job.is_busy() || job.status == crate::models::JobStatus::Pending,
        }
    }

    fn has_media(&self) -> bool {
        self.media_name.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Index {
    pub entries: Vec<Entry>,
    pub catalog: LibraryCatalog,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub removed: Removed,
    pub podcasts: Podcasts,
    pub shelves: Shelves,
    /// Each device's learning time; older peers send none.
    #[serde(skip_serializing_if = "Activity::is_empty")]
    pub activity: Activity,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Mark {
    pub hidden: bool,
    pub at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Position {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position_ms: Option<i64>,
    pub at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Shelves {
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub positions: BTreeMap<String, Position>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub marks: BTreeMap<String, Mark>,
}

impl Shelves {
    pub fn of(
        positions: &BTreeMap<String, i64>,
        played: &BTreeMap<String, String>,
        marks: &BTreeMap<String, Mark>,
    ) -> Shelves {
        let mut kept: BTreeMap<String, Position> = played
            .iter()
            .map(|(id, at)| (id.clone(), Position { position_ms: positions.get(id).copied(), at: at.clone() }))
            .collect();
        for (id, position) in positions {
            kept.entry(id.clone()).or_insert_with(|| Position { position_ms: Some(*position), at: String::new() });
        }
        Shelves { positions: kept, marks: marks.clone() }
    }

    pub fn of_settings(settings: &crate::models::Settings) -> Shelves {
        let mut marks = settings.shelf_marks.clone();
        let hidden = [("continue", &settings.continue_hidden), ("recent", &settings.recent_hidden)];
        for (shelf, ids) in hidden {
            for id in ids {
                let unmarked = Mark { hidden: true, at: "1970-01-01T00:00:00.000Z".into() };
                marks.entry(format!("{shelf}:{id}")).or_insert(unmarked);
            }
        }
        Shelves::of(&settings.playback_positions_ms, &settings.playback_played_at, &marks)
    }

    pub fn positions(&self) -> (BTreeMap<String, i64>, BTreeMap<String, String>) {
        let positions =
            self.positions.iter().filter_map(|(id, position)| Some((id.clone(), position.position_ms?))).collect();
        let played = self
            .positions
            .iter()
            .filter(|(_, position)| !position.at.is_empty())
            .map(|(id, position)| (id.clone(), position.at.clone()))
            .collect();
        (positions, played)
    }
}

pub fn merge_shelves(mine: &mut Shelves, theirs: &Shelves) -> bool {
    let mut changed = false;
    for (id, other) in &theirs.positions {
        if mine.positions.get(id).is_none_or(|known| later(&other.at, &known.at)) {
            mine.positions.insert(id.clone(), other.clone());
            changed = true;
        }
    }
    for (key, other) in &theirs.marks {
        if mine.marks.get(key).is_none_or(|known| later(&other.at, &known.at)) {
            mine.marks.insert(key.clone(), other.clone());
            changed = true;
        }
    }
    changed
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Podcasts {
    pub followed: Vec<Followed>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub unfollowed: Removed,
    pub listened: Vec<ListenProgress>,
    pub played: Vec<Feed>,
}

pub const LISTENED_KEPT: usize = 200;

impl Podcasts {
    pub fn of(catalog: &Catalog, listened: &[ListenProgress]) -> Podcasts {
        let listened: Vec<ListenProgress> = listened.iter().take(LISTENED_KEPT).cloned().collect();
        let played = catalog
            .feeds
            .iter()
            .filter_map(|feed| {
                let episodes: Vec<_> = feed
                    .episodes
                    .iter()
                    .filter(|episode| listened.iter().any(|entry| entry.episode_id == episode.id))
                    .cloned()
                    .collect();
                (!episodes.is_empty()).then(|| Feed { episodes, ..feed.clone() })
            })
            .collect();
        Podcasts { followed: catalog.followed.clone(), unfollowed: catalog.unfollowed.clone(), listened, played }
    }
}

fn later(a: &str, b: &str) -> bool {
    millis(a) > millis(b)
}

pub fn merge_podcasts(catalog: &mut Catalog, listened: &mut Vec<ListenProgress>, remote: &Podcasts) -> bool {
    let before = (catalog.clone(), listened.clone());
    for (url, at) in &remote.unfollowed {
        if catalog.unfollowed.get(url).is_none_or(|mine| later(at, mine)) {
            catalog.unfollowed.insert(url.clone(), at.clone());
        }
    }
    for other in &remote.followed {
        match catalog.followed.iter_mut().find(|mine| mine.feed_url == other.feed_url) {
            Some(mine) if later(&other.followed_at, &mine.followed_at) => *mine = other.clone(),
            Some(_) => {}
            None => catalog.followed.push(other.clone()),
        }
    }
    let unfollowed = catalog.unfollowed.clone();
    catalog
        .followed
        .retain(|followed| unfollowed.get(&followed.feed_url).is_none_or(|at| later(&followed.followed_at, at)));
    catalog.followed.sort_by_key(|followed| std::cmp::Reverse(millis(&followed.followed_at)));

    let at = |entry: &ListenProgress| entry.updated_at.as_deref().map_or(i64::MIN, millis);
    for other in &remote.listened {
        match listened.iter_mut().find(|mine| mine.episode_id == other.episode_id) {
            Some(mine) if at(other) > at(mine) => *mine = other.clone(),
            Some(_) => {}
            None => listened.push(other.clone()),
        }
    }
    listened.sort_by_key(|entry| std::cmp::Reverse(at(entry)));
    listened.truncate(LISTENED_KEPT);

    for feed in &remote.played {
        match catalog.feeds.iter_mut().find(|mine| mine.feed_url == feed.feed_url) {
            Some(mine) => {
                for episode in &feed.episodes {
                    if !mine.episodes.iter().any(|known| known.id == episode.id) {
                        mine.episodes.push(episode.clone());
                    }
                }
                mine.episodes.sort_by(|a, b| b.published_at.cmp(&a.published_at));
            }
            None => catalog.feeds.push(Feed { fetched_at: None, ..feed.clone() }),
        }
    }
    (catalog.clone(), listened.clone()) != before
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Member {
    pub name: String,
    pub platform: String,
    pub joined_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub removed_at: Option<String>,
    /// The fingerprint of the device's certificate: the device is the one that holds its key.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub key: String,
}

impl Member {
    pub fn is_in(&self) -> bool {
        self.removed_at.as_deref().is_none_or(|at| later(&self.joined_at, at))
    }

    /// Takes the device out from now. The time is after the one it joined at even when that came
    /// from a device whose clock runs ahead, so the removal is never older than the joining.
    pub fn remove(&mut self) {
        let now = millis(&crate::models::now_iso());
        let at = now.max(millis(&self.joined_at).saturating_add(1));
        self.removed_at = Some(
            chrono::DateTime::from_timestamp_millis(at)
                .map(|at| at.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())
                .unwrap_or_else(crate::models::now_iso),
        );
    }

    fn changed_at(&self) -> i64 {
        millis(&self.joined_at).max(self.removed_at.as_deref().map_or(i64::MIN, millis))
    }
}

pub type Members = BTreeMap<String, Member>;

pub fn merge_members(mine: &mut Members, theirs: &Members) -> bool {
    let mut changed = false;
    for (id, other) in theirs {
        if id.is_empty() || mine.get(id).is_some_and(|known| known.changed_at() >= other.changed_at()) {
            continue;
        }
        mine.insert(id.clone(), other.clone());
        changed = true;
    }
    changed
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Circle {
    pub id: String,
    pub members: Members,
}

impl Circle {
    pub fn has(&self, id: &str) -> bool {
        self.members.get(id).is_some_and(Member::is_in)
    }

    /// The id of the device in the circle that holds the certificate with this fingerprint.
    pub fn holder(&self, key: &str) -> Option<&str> {
        self.members.iter().find(|(_, member)| !key.is_empty() && member.key == key).map(|(id, _)| id.as_str())
    }

    /// Whether every device was paired with a certificate. Circles made before sync ran over TLS
    /// were not, and have to be paired again.
    pub fn is_keyed(&self) -> bool {
        self.members.values().all(|member| !member.key.is_empty())
    }

    pub fn size(&self) -> usize {
        self.members.values().filter(|member| member.is_in()).count()
    }

    pub fn offer(&self) -> Offer {
        Offer { id: self.id.clone(), size: self.size() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Offer {
    pub id: String,
    pub size: usize,
}

pub fn joins_answerer(asker: Option<&Offer>, answerer: Option<&Offer>) -> bool {
    match (asker, answerer) {
        (Some(asker), Some(answerer)) => asker.id == answerer.id || answerer.size >= asker.size,
        (Some(_), None) => false,
        (None, _) => true,
    }
}

pub fn digest(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update((part.len() as u64).to_be_bytes());
        hasher.update(part.as_bytes());
    }
    hex(&hasher.finalize())
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len()).step_by(2).map(|at| u8::from_str_radix(text.get(at..at + 2)?, 16).ok()).collect()
}

pub fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0, |differ, (x, y)| differ | (x ^ y)) == 0
}

/// One side of checking a pairing code with SPAKE2: both devices turn the code into a shared
/// key without sending it, and someone who watches or relays the exchange learns nothing that
/// lets them try codes on their own; each try takes a round with a device, which counts it.
/// Each side names both devices by id and by the fingerprint of the certificate it saw, so a
/// relay in the middle (which shows each side its own certificate) makes the keys differ.
pub struct Pake(spake2::Spake2<spake2::Ed25519Group>);

impl Pake {
    /// Starts the asker's side (`asking`) or the answerer's: the message to send the other side.
    pub fn start(code: &str, asker: (&str, &str), answerer: (&str, &str), asking: bool) -> (Pake, String) {
        let password = spake2::Password::new(code.as_bytes());
        let name = |(id, key): (&str, &str)| spake2::Identity::new(format!("{id}|{key}").as_bytes());
        let (asker, answerer) = (name(asker), name(answerer));
        let (state, message) = if asking {
            spake2::Spake2::<spake2::Ed25519Group>::start_a(&password, &asker, &answerer)
        } else {
            spake2::Spake2::<spake2::Ed25519Group>::start_b(&password, &asker, &answerer)
        };
        (Pake(state), hex(&message))
    }

    /// The shared key, from the other side's message; `None` when it is not a message.
    pub fn finish(self, theirs: &str) -> Option<Vec<u8>> {
        self.0.finish(&unhex(theirs)?).ok()
    }
}

/// What a device sends to show it holds the pairing key: the other side checks it, and a wrong
/// one means a wrong code.
pub fn pake_proof(key: &[u8], role: &str) -> String {
    use hmac::Mac;
    let mut mac = hmac::Hmac::<Sha256>::new_from_slice(key).expect("HMAC takes a key of any length");
    mac.update(b"listenook pairing ");
    mac.update(role.as_bytes());
    hex(&mac.finalize().into_bytes())
}

pub fn is_code(text: &str) -> bool {
    text.len() == CODE_LENGTH && text.bytes().all(|byte| byte.is_ascii_digit())
}

pub type Removed = BTreeMap<String, String>;

/// Whether `here` was saved after `there`: an edit made on this device while a sync ran stays.
pub fn edited_after(here: &str, there: &str) -> bool {
    millis(here) > millis(there)
}

pub fn removal_stands(removed_at: &str, updated_at: &str) -> bool {
    millis(removed_at) >= millis(updated_at)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transfer {
    pub id: String,
    pub manifest: bool,
    pub media: bool,
    pub media_name: String,
    pub media_size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Plan {
    pub pull: Vec<Transfer>,
    pub push: Vec<Transfer>,
}

impl Plan {
    pub fn is_empty(&self) -> bool {
        self.pull.is_empty() && self.push.is_empty()
    }

    pub fn media_bytes(&self) -> u64 {
        self.pull.iter().chain(&self.push).filter(|t| t.media).map(|t| t.media_size).sum()
    }
}

fn millis(time: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(time).map_or(i64::MIN, |time| time.timestamp_millis())
}

pub fn plan(local: &[Entry], remote: &[Entry]) -> Plan {
    plan_with(local, remote, &Removed::new(), &Removed::new())
}

pub fn plan_with(local: &[Entry], remote: &[Entry], removed_here: &Removed, removed_there: &Removed) -> Plan {
    let gone = |entry: &Entry, removed: &Removed| {
        removed.get(&entry.id).is_some_and(|at| removal_stands(at, &entry.updated_at))
    };
    let theirs: BTreeMap<&str, &Entry> = remote.iter().map(|entry| (entry.id.as_str(), entry)).collect();
    let ours: BTreeMap<&str, &Entry> = local.iter().map(|entry| (entry.id.as_str(), entry)).collect();
    let transfer = |from: &Entry, manifest: bool, media: bool| Transfer {
        id: from.id.clone(),
        manifest,
        media,
        media_name: from.media_name.clone().unwrap_or_default(),
        media_size: from.media_size,
    };
    let mut plan = Plan::default();
    for mine in local {
        match theirs.get(mine.id.as_str()) {
            None if gone(mine, removed_there) => {}
            None if !mine.busy => plan.push.push(transfer(mine, true, mine.has_media())),
            None => {}
            Some(other) if mine.busy || other.busy => {}
            Some(other) => {
                let (mine_at, other_at) = (millis(&mine.updated_at), millis(&other.updated_at));
                let (send_media, take_media) =
                    (mine.has_media() && !other.has_media(), other.has_media() && !mine.has_media());
                if mine_at > other_at || send_media {
                    plan.push.push(transfer(mine, mine_at > other_at, send_media));
                }
                if other_at > mine_at || take_media {
                    plan.pull.push(transfer(other, other_at > mine_at, take_media));
                }
            }
        }
    }
    for other in remote {
        if !ours.contains_key(other.id.as_str()) && !other.busy && !gone(other, removed_here) {
            plan.pull.push(transfer(other, true, other.has_media()));
        }
    }
    plan
}

pub fn merge_catalog(local: &mut LibraryCatalog, remote: &LibraryCatalog) -> HashMap<String, String> {
    fn merge(local: &mut Vec<Named>, remote: &[Named], removed: &Removed, map: &mut HashMap<String, String>) {
        local.retain(|named| !removed.contains_key(&named.id));
        for other in remote {
            if other.id.is_empty() || removed.contains_key(&other.id) || local.iter().any(|named| named.id == other.id)
            {
                continue;
            }
            match local.iter().find(|named| named.name == other.name) {
                Some(same) => drop(map.insert(other.id.clone(), same.id.clone())),
                None => local.push(other.clone()),
            }
        }
    }
    for (id, at) in &remote.removed {
        local.removed.entry(id.clone()).or_insert_with(|| at.clone());
    }
    let removed = local.removed.clone();
    let mut map = HashMap::new();
    merge(&mut local.groups, &remote.groups, &removed, &mut map);
    merge(&mut local.tags, &remote.tags, &removed, &mut map);
    map
}

/// Moves a recording from the other device onto this device's groups and tags, and out of any
/// that were deleted.
pub fn rehome(job: &mut Job, map: &HashMap<String, String>, removed: &Removed) {
    if let Some(group) = &mut job.group_id
        && let Some(here) = map.get(group)
    {
        *group = here.clone();
    }
    if job.group_id.as_ref().is_some_and(|group| removed.contains_key(group)) {
        job.group_id = None;
    }
    for tag in &mut job.tag_ids {
        if let Some(here) = map.get(tag) {
            *tag = here.clone();
        }
    }
    job.tag_ids.retain(|tag| !removed.contains_key(tag));
    job.tag_ids.sort();
    job.tag_ids.dedup();
}

pub fn media_extension(name: &str) -> String {
    let extension: String = name
        .rsplit_once('.')
        .map(|(_, extension)| extension)
        .unwrap_or("")
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect::<String>()
        .to_ascii_lowercase();
    if extension.is_empty() { "media".into() } else { extension }
}

pub fn media_file_name(job_id: &str, name: &str) -> String {
    format!("sync-{job_id}.{}", media_extension(name))
}

pub fn is_sync_name(job_id: &str, name: &str) -> bool {
    name.strip_prefix("sync-").and_then(|rest| rest.strip_prefix(job_id)).is_some_and(|rest| rest.starts_with('.'))
}

pub fn keep_title(job: &mut Job, name: &str) -> bool {
    let lost = format!("sync-{}", job.id);
    let title = match name.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem,
        _ => name,
    }
    .trim();
    if job.title() != lost || title.is_empty() || title == lost {
        return false;
    }
    job.display_title = Some(title.to_owned());
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_edit_saved_later_is_newer_and_a_missing_time_is_oldest() {
        assert!(edited_after("2026-11-12T09:00:00.000Z", "2026-11-12T08:59:59.999Z"));
        assert!(!edited_after("2026-11-12T09:00:00.000Z", "2026-11-12T09:00:00.000Z"));
        assert!(!edited_after("", "2026-11-12T09:00:00.000Z"));
        assert!(edited_after("2026-11-12T09:00:00+08:00", "2026-11-12T00:59:00Z"));
    }

    #[test]
    fn a_synced_recording_keeps_the_name_of_its_file() {
        let mut job = Job { id: "a-1".into(), source_path: "/there/Talk about it.mp3".into(), ..Job::default() };
        let name = job.file_name();
        assert!(!keep_title(&mut job, &name));
        job.source_path = format!("/here/media/{}", media_file_name("a-1", &name));
        assert_eq!(job.title(), "sync-a-1");
        assert!(keep_title(&mut job, &name));
        assert_eq!(job.title(), "Talk about it");
        assert!(!keep_title(&mut job, "Other.mp3"));
        job.display_title = None;
        assert!(!keep_title(&mut job, "sync-a-1.mp3"));
        assert_eq!(job.title(), "sync-a-1");
        assert!(is_sync_name("a-1", "sync-a-1.mp3"));
        assert!(!is_sync_name("a-1", "sync-a-12.mp3"));
        assert!(!is_sync_name("a-1", "Talk.mp3"));
    }

    fn entry(id: &str, at: &str, media: bool) -> Entry {
        Entry {
            id: id.into(),
            updated_at: at.into(),
            media_name: media.then(|| format!("{id}.mp3")),
            media_size: if media { 10 } else { 0 },
            busy: false,
        }
    }

    const EARLY: &str = "2026-01-01T00:00:00.000Z";
    const LATE: &str = "2026-02-01T00:00:00.000Z";

    #[test]
    fn what_one_side_lacks_is_copied_whole() {
        let plan = plan(&[entry("a", EARLY, true)], &[entry("b", EARLY, false)]);
        assert_eq!(plan.push.len(), 1);
        assert!(plan.push[0].manifest && plan.push[0].media && plan.push[0].id == "a");
        assert_eq!(plan.pull.len(), 1);
        assert!(plan.pull[0].manifest && !plan.pull[0].media && plan.pull[0].id == "b");
        assert_eq!(plan.media_bytes(), 10);
    }

    #[test]
    fn the_manifest_changed_last_wins_and_media_goes_where_it_is_missing() {
        let plan = plan(&[entry("a", LATE, false)], &[entry("a", EARLY, true)]);
        assert_eq!(plan.push.len(), 1);
        assert!(plan.push[0].manifest && !plan.push[0].media);
        assert_eq!(plan.pull.len(), 1);
        assert!(!plan.pull[0].manifest && plan.pull[0].media);
    }

    #[test]
    fn equal_recordings_and_busy_ones_are_left_alone() {
        let same = plan(&[entry("a", EARLY, true)], &[entry("a", "2026-01-01T00:00:00.000000Z", true)]);
        assert!(same.is_empty());
        let mut working = entry("a", LATE, true);
        working.busy = true;
        assert!(plan(&[working.clone()], &[entry("a", EARLY, true)]).is_empty());
        assert!(plan(&[working.clone()], &[]).is_empty());
        assert!(plan(&[], &[working]).is_empty());
    }

    #[test]
    fn a_removed_recording_is_not_copied_back_unless_changed_since() {
        let removed = |at: &str| Removed::from([("a".to_owned(), at.to_owned())]);
        let none = Removed::new();
        assert!(plan_with(&[], &[entry("a", EARLY, true)], &removed(LATE), &none).is_empty());
        assert!(plan_with(&[entry("a", EARLY, true)], &[], &none, &removed(LATE)).is_empty());
        assert_eq!(plan_with(&[], &[entry("a", LATE, true)], &removed(EARLY), &none).pull.len(), 1);
        assert_eq!(plan_with(&[entry("a", LATE, true)], &[], &none, &removed(EARLY)).push.len(), 1);
    }

    #[test]
    fn groups_and_tags_merge_by_id_and_by_name() {
        let named = |id: &str, name: &str| Named { id: id.into(), name: name.into() };
        let mut local =
            LibraryCatalog { groups: vec![named("g1", "Work")], tags: vec![named("t1", "todo")], ..Default::default() };
        let remote = LibraryCatalog {
            groups: vec![named("g1", "Work"), named("g9", "Travel")],
            tags: vec![named("t7", "todo"), named("t8", "idea")],
            ..Default::default()
        };
        let map = merge_catalog(&mut local, &remote);
        assert_eq!(local.groups.len(), 2);
        assert_eq!(local.tags.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["t1", "t8"]);
        assert_eq!(map.get("t7").map(String::as_str), Some("t1"));
        let mut job = Job { tag_ids: vec!["t8".into(), "t7".into(), "t1".into()], ..Job::default() };
        rehome(&mut job, &map, &local.removed);
        assert_eq!(job.tag_ids, ["t1", "t8"]);
    }

    #[test]
    fn a_deleted_group_or_tag_stays_deleted_on_both_sides() {
        let named = |id: &str, name: &str| Named { id: id.into(), name: name.into() };
        let both = || LibraryCatalog {
            groups: vec![named("g1", "English"), named("g2", "Work")],
            tags: vec![named("t1", "todo")],
            ..Default::default()
        };
        let (mut here, mut there) = (both(), both());
        here.remove("g1");
        here.remove("t1");

        assert!(merge_catalog(&mut here, &there).is_empty());
        assert_eq!(here.groups, [named("g2", "Work")]);
        assert!(here.tags.is_empty());

        merge_catalog(&mut there, &here);
        assert_eq!(there.groups, [named("g2", "Work")]);
        assert!(there.tags.is_empty());
        assert!(there.removed.contains_key("g1") && there.removed.contains_key("t1"));

        let mut job = Job { group_id: Some("g1".into()), tag_ids: vec!["t1".into()], ..Job::default() };
        rehome(&mut job, &HashMap::new(), &there.removed);
        assert_eq!(job.group_id, None);
        assert!(job.tag_ids.is_empty());

        let mut again = here.clone();
        again.groups.push(named("g3", "English"));
        merge_catalog(&mut there, &again);
        assert!(there.groups.iter().any(|group| group.id == "g3"));
    }

    fn followed(url: &str, at: &str) -> Followed {
        Followed { feed_url: url.into(), title: url.into(), followed_at: at.into(), ..Followed::default() }
    }

    fn heard(id: &str, position_ms: i64, at: &str) -> ListenProgress {
        ListenProgress {
            episode_id: id.into(),
            position_ms,
            duration_ms: 600_000,
            updated_at: Some(at.into()),
            ..ListenProgress::default()
        }
    }

    #[test]
    fn follows_merge_and_a_later_unfollow_wins() {
        let mut catalog = Catalog {
            followed: vec![followed("a", EARLY), followed("kept", EARLY)],
            unfollowed: [("b".to_owned(), LATE.to_owned())].into(),
            ..Catalog::default()
        };
        let remote = Podcasts {
            followed: vec![followed("b", EARLY), followed("c", EARLY), followed("kept", EARLY)],
            unfollowed: [("a".to_owned(), LATE.to_owned())].into(),
            ..Podcasts::default()
        };
        let mut listened = Vec::new();
        assert!(merge_podcasts(&mut catalog, &mut listened, &remote));
        let urls: Vec<&str> = catalog.followed.iter().map(|f| f.feed_url.as_str()).collect();
        assert!(urls.contains(&"c") && urls.contains(&"kept"), "{urls:?}");
        assert!(!urls.contains(&"a") && !urls.contains(&"b"), "{urls:?}");
        let refollowed = Podcasts { followed: vec![followed("b", "2026-03-01T00:00:00.000Z")], ..Podcasts::default() };
        merge_podcasts(&mut catalog, &mut listened, &refollowed);
        assert!(catalog.followed.iter().any(|f| f.feed_url == "b"), "following again after the unfollow counts");
        assert!(!merge_podcasts(&mut catalog, &mut listened, &refollowed), "a second merge changes nothing");
    }

    #[test]
    fn the_later_place_in_an_episode_wins_and_its_episode_comes_along() {
        let episode = |id: &str| crate::podcast::Episode { id: id.into(), feed_url: "f".into(), ..Default::default() };
        let mut catalog = Catalog::default();
        let mut listened = vec![heard("e1", 60_000, LATE), heard("e2", 10_000, EARLY)];
        let remote = Podcasts {
            listened: vec![heard("e1", 5_000, EARLY), heard("e2", 90_000, LATE), heard("e3", 30_000, LATE)],
            played: vec![Feed { feed_url: "f".into(), episodes: vec![episode("e3")], ..Feed::default() }],
            ..Podcasts::default()
        };
        assert!(merge_podcasts(&mut catalog, &mut listened, &remote));
        let place = |id: &str| listened.iter().find(|e| e.episode_id == id).map(|e| e.position_ms);
        assert_eq!((place("e1"), place("e2"), place("e3")), (Some(60_000), Some(90_000), Some(30_000)));
        assert_eq!(catalog.feeds[0].episodes[0].id, "e3");
        let sent = Podcasts::of(&catalog, &listened);
        assert_eq!(sent.played.len(), 1);
        assert_eq!(sent.listened.len(), 3);
    }

    fn member(joined: &str, removed: Option<&str>) -> Member {
        Member {
            name: "Mac".into(),
            joined_at: joined.into(),
            removed_at: removed.map(str::to_owned),
            ..Member::default()
        }
    }

    #[test]
    fn the_later_of_joining_and_removal_wins_when_members_merge() {
        const LATER: &str = "2026-03-01T00:00:00.000Z";
        let mut mine = Members::from([("a".to_owned(), member(EARLY, None)), ("b".to_owned(), member(LATE, None))]);
        let theirs = Members::from([
            ("a".to_owned(), member(EARLY, Some(LATE))),
            ("b".to_owned(), member(EARLY, Some(EARLY))),
            ("c".to_owned(), member(EARLY, None)),
        ]);
        assert!(merge_members(&mut mine, &theirs));
        assert!(!mine["a"].is_in(), "removed after it joined");
        assert!(mine["b"].is_in(), "joined again after the removal");
        assert!(mine["c"].is_in());
        assert!(!merge_members(&mut mine, &theirs), "a second merge changes nothing");
        let back = Members::from([("a".to_owned(), member(LATER, Some(LATE)))]);
        assert!(merge_members(&mut mine, &back));
        assert!(mine["a"].is_in(), "paired again after the removal");
    }

    #[test]
    fn the_circle_with_more_devices_is_the_one_joined() {
        let offer = |id: &str, size| Offer { id: id.into(), size };
        assert!(joins_answerer(None, None));
        assert!(joins_answerer(None, Some(&offer("b", 2))));
        assert!(!joins_answerer(Some(&offer("a", 1)), None));
        assert!(!joins_answerer(Some(&offer("a", 3)), Some(&offer("b", 2))));
        assert!(joins_answerer(Some(&offer("a", 2)), Some(&offer("b", 2))));
        assert!(joins_answerer(Some(&offer("a", 3)), Some(&offer("a", 2))));
    }

    #[test]
    fn the_same_code_and_certificates_give_both_sides_one_key() {
        let (asker, answerer) = (("a", "key-a"), ("b", "key-b"));
        let pair = |asker_code: &str, answerer_code: &str, seen: (&str, &str)| {
            let (mine, sent) = Pake::start(asker_code, asker, seen, true);
            let (theirs, answered) = Pake::start(answerer_code, asker, answerer, false);
            (mine.finish(&answered).unwrap(), theirs.finish(&sent).unwrap())
        };
        let (here, there) = pair("123456", "123456", answerer);
        assert_eq!(here, there);
        assert_eq!(pake_proof(&here, "asker"), pake_proof(&there, "asker"));
        assert_ne!(pake_proof(&here, "asker"), pake_proof(&here, "answerer"));
        let (here, there) = pair("123457", "123456", answerer);
        assert_ne!(pake_proof(&here, "asker"), pake_proof(&there, "asker"), "another code");
        let (here, there) = pair("123456", "123456", ("b", "key-of-a-relay"));
        assert_ne!(here, there, "a certificate other than the device's");
        assert!(Pake::start("123456", asker, answerer, true).0.finish("not hex").is_none());
        let key = digest(&["key"]);
        assert!(same(&key, &key.clone()) && !same(&key, &digest(&["other"])) && !same("ab", "abc"));
        assert!(is_code("012345") && !is_code("12345") && !is_code("12345a"));
        assert_ne!(digest(&["ab", "c"]), digest(&["a", "bc"]));
    }

    #[test]
    fn a_removal_is_never_older_than_the_joining_it_ends() {
        let mut ahead = member("2999-01-01T00:00:00.000Z", None);
        ahead.remove();
        assert!(!ahead.is_in(), "a device whose clock ran ahead is still taken out");
        let mut now = member(EARLY, None);
        now.remove();
        assert!(!now.is_in());
        let circle = Circle {
            id: "c".into(),
            members: Members::from([("a".to_owned(), Member { key: "fa".into(), ..member(EARLY, None) })]),
        };
        assert_eq!(circle.holder("fa"), Some("a"));
        assert_eq!(circle.holder(""), None);
        assert!(circle.is_keyed());
        assert!(!Circle { members: Members::from([("b".to_owned(), member(EARLY, None))]), ..circle }.is_keyed());
    }

    #[test]
    fn the_later_place_in_a_recording_and_the_later_removal_from_a_shelf_win() {
        let place = |position_ms: Option<i64>, at: &str| Position { position_ms, at: at.into() };
        let mark = |hidden: bool, at: &str| Mark { hidden, at: at.into() };
        let mut mine = Shelves {
            positions: [
                ("a".to_owned(), place(Some(10_000), LATE)),
                ("b".to_owned(), place(Some(20_000), EARLY)),
                ("c".to_owned(), place(Some(30_000), EARLY)),
            ]
            .into(),
            marks: [("continue:a".to_owned(), mark(true, EARLY))].into(),
        };
        let theirs = Shelves {
            positions: [
                ("a".to_owned(), place(Some(5_000), EARLY)),
                ("b".to_owned(), place(Some(50_000), LATE)),
                ("c".to_owned(), place(None, LATE)),
                ("d".to_owned(), place(Some(1_000), EARLY)),
            ]
            .into(),
            marks: [("continue:a".to_owned(), mark(false, LATE)), ("recent:d".to_owned(), mark(true, EARLY))].into(),
        };
        assert!(merge_shelves(&mut mine, &theirs));
        let (positions, played) = mine.positions();
        assert_eq!(positions, [("a".to_owned(), 10_000), ("b".to_owned(), 50_000), ("d".to_owned(), 1_000)].into());
        assert!(played.contains_key("c"), "a finished recording stays finished");
        assert!(!mine.marks["continue:a"].hidden && mine.marks["recent:d"].hidden);
        assert!(!merge_shelves(&mut mine, &theirs), "a second merge changes nothing");
        let kept = Shelves::of(&positions, &played, &mine.marks);
        assert_eq!(kept, mine);
        let settings = crate::models::Settings {
            continue_hidden: ["old".to_owned()].into(),
            shelf_marks: [("continue:a".to_owned(), mark(false, LATE))].into(),
            ..crate::models::Settings::default()
        };
        let sent = Shelves::of_settings(&settings);
        assert!(sent.marks["continue:old"].hidden, "a card removed before marks were kept still goes");
        let mut newer =
            Shelves { marks: [("continue:old".to_owned(), mark(false, EARLY))].into(), ..Shelves::default() };
        merge_shelves(&mut newer, &sent);
        assert!(!newer.marks["continue:old"].hidden, "and any real change wins over it");
    }

    #[test]
    fn media_names_cannot_leave_the_media_folder() {
        assert_eq!(media_file_name("a-1", "Talk.MP3"), "sync-a-1.mp3");
        assert_eq!(media_file_name("a-1", "x.../../etc"), "sync-a-1.etc");
        assert_eq!(media_file_name("a-1", "noext"), "sync-a-1.media");
    }

    #[test]
    fn learning_time_travels_in_the_index_and_older_ones_still_read() {
        use crate::activity::{Kind, parse_day};
        let older: Index = serde_json::from_str(r#"{"entries": []}"#).unwrap();
        assert!(older.activity.is_empty());
        let mut index = Index::default();
        assert!(!serde_json::to_string(&index).unwrap().contains("activity"));
        index.activity.add("there", parse_day("2026-11-17").unwrap(), Kind::Listen, 600);
        let sent: Index = serde_json::from_str(&serde_json::to_string(&index).unwrap()).unwrap();
        let mut here = Activity::default();
        here.add("here", parse_day("2026-11-17").unwrap(), Kind::Practice, 300);
        assert!(here.merge(&sent.activity));
        assert_eq!(here.on(parse_day("2026-11-17").unwrap()).total_s(), 900);
    }
}
