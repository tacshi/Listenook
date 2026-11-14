use std::{cell::RefCell, collections::HashMap};

use super::persist;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Secret {
    Soniox,
    Moss,
    Llm,
}

impl Secret {
    fn account(self) -> &'static str {
        match self {
            Secret::Soniox => "soniox_api_key",
            Secret::Moss => "moss_api_key",
            Secret::Llm => "openai_compatible_translation_api_key",
        }
    }

    fn environment(self) -> Option<&'static str> {
        match self {
            Secret::Soniox => Some("SONIOX_API_KEY"),
            Secret::Moss => Some("MOSS_API_KEY"),
            Secret::Llm => None,
        }
    }
}

const SERVICE: &str = "app.capyvibe.listenook";

fn entry(secret: Secret) -> keyring::Result<keyring::Entry> {
    keyring::Entry::new(SERVICE, &format!("{SERVICE}.{}", secret.account()))
}

thread_local! {
    static MEMORY: RefCell<HashMap<Secret, String>> = RefCell::new(HashMap::new());
}

fn in_memory() -> bool {
    persist::data_root().is_none() || std::env::var_os("LISTENOOK_MEMORY_SECRETS").is_some()
}

pub(crate) fn uses_system_store() -> bool {
    cfg!(all(any(target_os = "macos", target_os = "ios", target_os = "windows"), not(target_abi = "sim")))
        && !in_memory()
}

fn file() -> Option<std::path::PathBuf> {
    (!in_memory()).then(|| persist::data_root().map(|root| root.join("keys.json"))).flatten()
}

fn read_file() -> HashMap<String, String> {
    file()
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn write_file(secret: Secret, value: &str) -> Result<(), String> {
    let path = file().ok_or("no data folder")?;
    let mut keys = read_file();
    if value.is_empty() {
        keys.remove(secret.account());
    } else {
        keys.insert(secret.account().to_owned(), value.to_owned());
    }
    let bytes = serde_json::to_vec(&keys).map_err(|e| e.to_string())?;
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

pub(crate) fn read(secret: Secret) -> Option<String> {
    let stored = if uses_system_store() {
        entry(secret).and_then(|entry| entry.get_password()).ok()
    } else if in_memory() {
        MEMORY.with(|memory| memory.borrow().get(&secret).cloned())
    } else {
        read_file().remove(secret.account())
    };
    stored
        .or_else(|| secret.environment().and_then(|name| std::env::var(name).ok()))
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

pub(crate) fn write(secret: Secret, value: &str) -> Result<(), String> {
    let value = value.trim();
    if !uses_system_store() && !in_memory() {
        return write_file(secret, value);
    }
    if !uses_system_store() {
        MEMORY.with(|memory| {
            if value.is_empty() {
                memory.borrow_mut().remove(&secret);
            } else {
                memory.borrow_mut().insert(secret, value.to_owned());
            }
        });
        return Ok(());
    }
    let entry = entry(secret).map_err(|e| e.to_string())?;
    if value.is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.to_string()),
        }
    } else {
        entry.set_password(value).map_err(|e| e.to_string())
    }
}
