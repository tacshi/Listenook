//! Opening the app when the user logs in: a launch agent on macOS, a `Run`
//! entry in the registry on Windows. Nothing else has such a place here.

use std::path::PathBuf;

/// Whether this build can be opened at login: a packaged desktop app.
pub(crate) fn supported() -> bool {
    cfg!(any(target_os = "macos", target_os = "windows")) && target().is_some()
}

/// What is opened: the app's bundle on macOS, its executable on Windows.
/// None for a development run, which is not somewhere to come back to.
fn target() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    if cfg!(target_os = "macos") {
        // `<Name>.app/Contents/MacOS/<Name>`
        let bundle = executable.parent()?.parent()?.parent()?;
        return bundle.extension().is_some_and(|extension| extension == "app").then(|| bundle.to_owned());
    }
    (!executable.components().any(|part| part.as_os_str() == "target")).then_some(executable)
}

#[cfg(target_os = "macos")]
fn agent() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Library/LaunchAgents/app.capyvibe.listenook.plist"))
}

/// The launch agent that opens `bundle` at login.
#[cfg(any(target_os = "macos", test))]
fn agent_plist(bundle: &str) -> String {
    let escaped = bundle.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>app.capyvibe.listenook</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>{escaped}</string>
		<string>--args</string>
		<string>--background</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
"#
    )
}

/// Turns opening at login on or off. Returns whether it is as asked.
pub(crate) fn set(enabled: bool) -> bool {
    let Some(target) = target() else {
        return false;
    };
    #[cfg(target_os = "macos")]
    {
        let Some(agent) = agent() else {
            return false;
        };
        if !enabled {
            return std::fs::remove_file(&agent).is_ok() || !agent.exists();
        }
        let made = agent.parent().is_some_and(|folder| std::fs::create_dir_all(folder).is_ok());
        made && std::fs::write(&agent, agent_plist(&target.to_string_lossy())).is_ok()
    }
    #[cfg(target_os = "windows")]
    {
        const KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
        let mut command = std::process::Command::new("reg");
        if enabled {
            command.args(["add", KEY, "/v", "Listenook", "/t", "REG_SZ", "/d"]);
            command.arg(format!("\"{}\" --background", target.display())).arg("/f");
        } else {
            command.args(["delete", KEY, "/v", "Listenook", "/f"]);
        }
        command.output().is_ok_and(|out| out.status.success() || !enabled)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = (target, enabled);
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_launch_agent_opens_the_bundle_at_login() {
        let plist = agent_plist("/Applications/A & B.app");
        assert!(plist.contains("<string>/Applications/A &amp; B.app</string>"));
        assert!(plist.contains("<key>RunAtLoad</key>\n\t<true/>"));
        assert!(plist.contains("<string>--args</string>\n\t\t<string>--background</string>"), "starts in the tray");
    }
}
