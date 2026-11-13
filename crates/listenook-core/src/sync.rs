//! Syncing two Libraries over the local network: what each device tells
//! the other about itself and its recordings, and what is then copied
//! which way. The transport is the app's; nothing here touches the network.
//!
//! Both Libraries end as their union. A recording only one has is copied
//! to the other, media and all. One both have keeps the manifest changed
//! last, and its media goes to the side that lacks the file. A recording
//! being worked on (transcribed, translated) on either side is left for
//! the next sync. Nothing is deleted: a recording removed on one device
//! comes back from the other.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use crate::models::{Job, LibraryCatalog, Named};

/// The version of the conversation; devices that differ do not sync.
pub const PROTOCOL: u32 = 1;

/// A device, as it names itself to others.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Device {
    /// `"listenook"`: what tells the app's answer from another program's.
    pub app: String,
    pub protocol: u32,
    /// Made once per installation.
    pub id: String,
    pub name: String,
    /// `macos`, `ios`, `android`, `windows` or `linux`.
    pub platform: String,
    /// The port it answers on.
    pub port: u16,
}

impl Device {
    /// Whether this is the app, speaking the protocol this build speaks.
    pub fn is_compatible(&self) -> bool {
        self.app == "listenook" && self.protocol == PROTOCOL && !self.id.is_empty()
    }
}

/// One recording of a Library, as the other device needs to know it.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Entry {
    pub id: String,
    pub updated_at: String,
    /// The media file's name, when the device has the file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_name: Option<String>,
    pub media_size: u64,
    /// Work is running for it: it is left alone this time.
    pub busy: bool,
}

impl Entry {
    /// What a job is to the other device. `media_size` is its file's size,
    /// or none when the file is not there.
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

/// A Library, as one device tells it to the other.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Index {
    pub entries: Vec<Entry>,
    pub catalog: LibraryCatalog,
}

/// What to copy for one recording.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transfer {
    pub id: String,
    pub manifest: bool,
    pub media: bool,
    /// The media file's name and size, when it is copied.
    pub media_name: String,
    pub media_size: u64,
}

/// What a sync copies: `pull` from the other device, `push` to it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Plan {
    pub pull: Vec<Transfer>,
    pub push: Vec<Transfer>,
}

impl Plan {
    /// Nothing differs.
    pub fn is_empty(&self) -> bool {
        self.pull.is_empty() && self.push.is_empty()
    }

    /// The bytes of media it copies, both ways.
    pub fn media_bytes(&self) -> u64 {
        self.pull.iter().chain(&self.push).filter(|t| t.media).map(|t| t.media_size).sum()
    }
}

/// A manifest's time as milliseconds, for comparing times written with
/// different precision. Text that is no time sorts before every time.
fn millis(time: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(time).map_or(i64::MIN, |time| time.timestamp_millis())
}

/// What to copy so that both Libraries hold the union of `local` and `remote`.
pub fn plan(local: &[Entry], remote: &[Entry]) -> Plan {
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
        if !ours.contains_key(other.id.as_str()) && !other.busy {
            plan.pull.push(transfer(other, true, other.has_media()));
        }
    }
    plan
}

/// Takes the other device's groups and tags into `local`. One whose name
/// is already here under another id is not added twice: the returned map
/// leads from the other device's id to the one used here, for the
/// recordings that come with it (see [`rehome`]).
pub fn merge_catalog(local: &mut LibraryCatalog, remote: &LibraryCatalog) -> HashMap<String, String> {
    fn merge(local: &mut Vec<Named>, remote: &[Named], map: &mut HashMap<String, String>) {
        for other in remote {
            if other.id.is_empty() || local.iter().any(|named| named.id == other.id) {
                continue;
            }
            match local.iter().find(|named| named.name == other.name) {
                Some(same) => drop(map.insert(other.id.clone(), same.id.clone())),
                None => local.push(other.clone()),
            }
        }
    }
    let mut map = HashMap::new();
    merge(&mut local.groups, &remote.groups, &mut map);
    merge(&mut local.tags, &remote.tags, &mut map);
    map
}

/// Files a recording that came from the other device under this device's
/// groups and tags (`map` is [`merge_catalog`]'s).
pub fn rehome(job: &mut Job, map: &HashMap<String, String>) {
    if map.is_empty() {
        return;
    }
    if let Some(group) = &mut job.group_id
        && let Some(here) = map.get(group)
    {
        *group = here.clone();
    }
    for tag in &mut job.tag_ids {
        if let Some(here) = map.get(tag) {
            *tag = here.clone();
        }
    }
    job.tag_ids.sort();
    job.tag_ids.dedup();
}

/// The extension a media file named `name` is kept under: lowercase
/// letters and digits only, `media` when it has none.
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

/// The name, in the app's `media` folder, of the file a synced recording's
/// media is kept in.
pub fn media_file_name(job_id: &str, name: &str) -> String {
    format!("sync-{job_id}.{}", media_extension(name))
}

/// Whether `name` is one [`media_file_name`] gives the recording's media.
pub fn is_sync_name(job_id: &str, name: &str) -> bool {
    name.strip_prefix("sync-").and_then(|rest| rest.strip_prefix(job_id)).is_some_and(|rest| rest.starts_with('.'))
}

/// Titles a recording after `name`, its media file's name on the device
/// it came from, when the file a sync brought is all that names it here:
/// a recording with no title of its own is called by its file. Whether
/// that changed it.
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
    fn a_synced_recording_keeps_the_name_of_its_file() {
        let mut job = Job { id: "a-1".into(), source_path: "/there/Talk about it.mp3".into(), ..Job::default() };
        let name = job.file_name();
        // Its own file names it still.
        assert!(!keep_title(&mut job, &name));
        job.source_path = format!("/here/media/{}", media_file_name("a-1", &name));
        assert_eq!(job.title(), "sync-a-1");
        assert!(keep_title(&mut job, &name));
        assert_eq!(job.title(), "Talk about it");
        // A title of its own stays, and a sync's name is no title.
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
        // Ours is newer; theirs has the file we lost.
        let plan = plan(&[entry("a", LATE, false)], &[entry("a", EARLY, true)]);
        assert_eq!(plan.push.len(), 1);
        assert!(plan.push[0].manifest && !plan.push[0].media);
        assert_eq!(plan.pull.len(), 1);
        assert!(!plan.pull[0].manifest && plan.pull[0].media);
    }

    #[test]
    fn equal_recordings_and_busy_ones_are_left_alone() {
        // The same instant, written with different precision.
        let same = plan(&[entry("a", EARLY, true)], &[entry("a", "2026-01-01T00:00:00.000000Z", true)]);
        assert!(same.is_empty());
        let mut working = entry("a", LATE, true);
        working.busy = true;
        assert!(plan(&[working.clone()], &[entry("a", EARLY, true)]).is_empty());
        assert!(plan(&[working.clone()], &[]).is_empty());
        assert!(plan(&[], &[working]).is_empty());
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
        rehome(&mut job, &map);
        assert_eq!(job.tag_ids, ["t1", "t8"]);
    }

    #[test]
    fn media_names_cannot_leave_the_media_folder() {
        assert_eq!(media_file_name("a-1", "Talk.MP3"), "sync-a-1.mp3");
        assert_eq!(media_file_name("a-1", "x.../../etc"), "sync-a-1.etc");
        assert_eq!(media_file_name("a-1", "noext"), "sync-a-1.media");
    }
}
