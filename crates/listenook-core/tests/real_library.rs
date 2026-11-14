use std::path::Path;

use listenook_core::{Job, LibraryCatalog, Settings, podcast::Catalog};
use serde_json::Value;

fn differences(path: &str, before: &Value, after: &Value, out: &mut Vec<String>) {
    match (before, after) {
        (Value::Object(a), Value::Object(b)) => {
            for (key, value) in a {
                match b.get(key) {
                    Some(other) => differences(&format!("{path}.{key}"), value, other, out),
                    None if value.is_null() => {}
                    None => out.push(format!("{path}.{key} lost")),
                }
            }
        }
        (Value::Array(a), Value::Array(b)) if a.len() == b.len() => {
            for (index, (x, y)) in a.iter().zip(b).enumerate() {
                differences(&format!("{path}[{index}]"), x, y, out);
            }
        }
        (Value::Number(a), Value::Number(b)) if a.as_f64() == b.as_f64() => {}
        (a, b) if a == b => {}
        (a, b) => out.push(format!("{path}: {} -> {}", short(a), short(b))),
    }
}

fn short(value: &Value) -> String {
    let text = value.to_string();
    if text.len() > 60 { format!("{}…", text.chars().take(60).collect::<String>()) } else { text }
}

fn round_trip<T: serde::de::DeserializeOwned + serde::Serialize>(file: &Path, out: &mut Vec<String>) -> bool {
    let Ok(bytes) = std::fs::read(file) else {
        return false;
    };
    let before: Value = serde_json::from_slice(&bytes).expect("the file is JSON");
    match serde_json::from_value::<T>(before.clone()) {
        Ok(parsed) => {
            let mut found = Vec::new();
            differences("", &before, &serde_json::to_value(&parsed).unwrap(), &mut found);
            out.extend(found.into_iter().take(8).map(|d| format!("{}: {d}", file.display())));
        }
        Err(error) => out.push(format!("{}: NOT READ: {error}", file.display())),
    }
    true
}

#[test]
#[ignore = "needs LISTENOOK_LIBRARY"]
fn a_real_library_is_written_back_as_it_was_read() {
    let root = std::path::PathBuf::from(std::env::var("LISTENOOK_LIBRARY").expect("LISTENOOK_LIBRARY"));
    let mut problems = Vec::new();
    let mut jobs = 0;
    for entry in std::fs::read_dir(root.join("jobs")).expect("a jobs folder").flatten() {
        jobs += usize::from(round_trip::<Job>(&entry.path().join("manifest.json"), &mut problems));
    }
    round_trip::<Settings>(&root.join("settings.json"), &mut problems);
    round_trip::<LibraryCatalog>(&root.join("library_catalog.json"), &mut problems);
    round_trip::<Catalog>(&root.join("podcast_catalog.json"), &mut problems);
    println!("{jobs} recordings read");
    for problem in &problems {
        println!("{problem}");
    }
    assert!(problems.is_empty(), "{} differences", problems.len());
}
