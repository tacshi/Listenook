use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use crate::models::{Job, LibraryCatalog, Named};

pub const PROTOCOL: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Device {
    pub app: String,
    pub protocol: u32,
    pub id: String,
    pub name: String,
    pub platform: String,
    pub port: u16,
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
}

pub type Removed = BTreeMap<String, String>;

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
