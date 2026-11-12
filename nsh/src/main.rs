//! Runs the app directly on this machine's native backend (`cargo run`).
//! `nsh run` and `nsh package` mount the root `nsh.json` names instead.

#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[cfg(target_os = "linux")]
use nsh_platform_linux as platform;
#[cfg(target_os = "macos")]
use nsh_platform_macos as platform;
#[cfg(target_os = "windows")]
use nsh_platform_windows as platform;

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
fn main() -> impl std::process::Termination {
    env_logger::init();
    #[cfg(target_os = "macos")]
    dock_icon::set(concat!(env!("CARGO_MANIFEST_DIR"), "/icon.png"));
    platform::set_ui_sets(vec![nsh_base::registry(), nsh_app_listenook::registry()]);
    let theme = nsh_base::Theme::from_json(include_str!("../theme.json")).expect("theme.json is a valid theme");
    // nsh.json's id: the window's and where NSH keeps the app's storage.
    let app_id = "app.capyvibe.listenook";
    platform::run_app(
        platform::AppSource::Rust(
            platform::Root::of::<nsh_app_listenook::App>().tokens(theme.into_tokens()).app_id(app_id),
        ),
        platform::AppOptions {
            title: "Listenook".to_owned(),
            app_id: app_id.to_owned(),
            size: (1180, 760),
            ..Default::default()
        },
    )
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
compile_error!("Run this binary on macOS, Windows or Linux; use nsh run for other targets.");

/// The Dock icon of a development run. A packaged app has its icon in its
/// bundle; this binary has no bundle, and the Dock would show a blank one.
#[cfg(target_os = "macos")]
mod dock_icon {
    use std::ffi::{CString, c_char, c_void};

    type Id = *mut c_void;

    #[link(name = "AppKit", kind = "framework")]
    unsafe extern "C" {
        fn objc_getClass(name: *const c_char) -> Id;
        fn sel_registerName(name: *const c_char) -> Id;
        fn objc_msgSend();
    }

    /// Sets the Dock icon to the image at `path`, if there is one.
    pub(super) fn set(path: &str) {
        let Ok(path) = CString::new(path) else {
            return;
        };
        // SAFETY: plain Objective-C messages with the argument and return
        // types their methods declare, sent on the main thread before the
        // app runs; a nil image is checked before it is used.
        unsafe {
            let send: unsafe extern "C" fn(Id, Id) -> Id = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let send_pointer: unsafe extern "C" fn(Id, Id, *const c_void) -> Id =
                std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let class = |name: &std::ffi::CStr| objc_getClass(name.as_ptr());
            let selector = |name: &std::ffi::CStr| sel_registerName(name.as_ptr());
            let text = send_pointer(class(c"NSString"), selector(c"stringWithUTF8String:"), path.as_ptr().cast());
            let image =
                send_pointer(send(class(c"NSImage"), selector(c"alloc")), selector(c"initWithContentsOfFile:"), text);
            if image.is_null() {
                return;
            }
            let app = send(class(c"NSApplication"), selector(c"sharedApplication"));
            send_pointer(app, selector(c"setApplicationIconImage:"), image);
        }
    }
}
