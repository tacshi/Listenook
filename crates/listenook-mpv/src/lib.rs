//! Plays recordings and videos with libmpv: the `listenook.mpv` native component, which the app
//! registers with nsh on each platform ([`register`]). Its props and events follow nsh's own
//! video element (see `player`), so pages use it the same way, and any format FFmpeg reads plays.

mod mpv;
mod player;
#[cfg(any(target_os = "macos", target_os = "linux", windows))]
mod render;

#[cfg(target_os = "android")]
mod android;
#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_os = "ios")]
mod ios;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod windows;

/// The component's name, as `native(NAME)` uses it.
pub const NAME: &str = "listenook.mpv";

/// Makes the player available as [`NAME`] in the views `components` belongs to.
#[cfg(target_os = "macos")]
pub fn register(components: &nsh_platform_macos::Components) {
    components.register(NAME, std::rc::Rc::new(macos::Video::make));
}

/// Makes the player available as [`NAME`] in the views `components` belongs to.
#[cfg(target_os = "ios")]
pub fn register(components: &nsh_platform_ios::Components) {
    components.register(NAME, std::rc::Rc::new(ios::Video::make));
}

/// Makes the player available as [`NAME`] in the views `components` belongs to.
#[cfg(target_os = "linux")]
pub fn register(components: &nsh_platform_linux::Components) {
    components.register(NAME, std::rc::Rc::new(linux::Video::make));
}

/// Makes the player available as [`NAME`] in the views `components` belongs to.
#[cfg(windows)]
pub fn register(components: &nsh_platform_windows::Components) {
    components.register(NAME, std::rc::Rc::new(windows::Video::make));
}

/// Makes the player available as [`NAME`] in the views `components` belongs to.
#[cfg(target_os = "android")]
pub fn register(components: &nsh::Components) {
    components.register(NAME, std::rc::Rc::new(android::Video::make));
}
