mod pages;
mod platform;
mod services;
mod shell;
mod state;
mod ui;
mod work;

use nsh_base::theme;
use nsh_core::{
    desktop::QuitMode,
    element::desktop::{set_quit_mode, window},
    prelude::*,
};

/// What the headless flows need to play another device in a sync: its key, and TLS as sync
/// speaks it. Not part of the app.
#[doc(hidden)]
pub mod testing {
    use std::{
        io,
        net::TcpStream,
        path::Path,
        sync::{Arc, Mutex},
        time::Duration,
    };

    use crate::services::sync::secure::Identity;

    /// The fingerprint of the certificate of the device whose key is kept in `library`; the
    /// key is made there the first time.
    pub fn device_key(library: &Path) -> String {
        Identity::of(library).expect("a key can be made").fingerprint.clone()
    }

    /// An HTTP client for the device whose key is kept in `library`, going on only with the
    /// device whose fingerprint is `there` (any device when `None`); `seen` gets the one it reached.
    pub fn client(library: &Path, there: Option<&str>, seen: Option<Arc<Mutex<String>>>) -> ureq::Agent {
        Identity::of(library).expect("a key can be made").agent(there, seen, Duration::from_secs(30))
    }

    /// Answers a connection as the device whose key is kept in `library`: the stream, and the
    /// fingerprint of the device that connected.
    pub fn answer(library: &Path, tcp: TcpStream) -> io::Result<(impl io::Read + io::Write, String)> {
        Identity::of(library)?.accept(tcp)
    }
}

#[native_module("listenook/native")]
fn native(registry: &mut Registry) {
    registry.register::<App>();
}

#[component]
pub fn App() -> impl IntoElement {
    let store = state::Store::install();
    work::install(store);
    effect(move || set_color_scheme(if store.immersive() { Appearance::Dark } else { store.appearance() }));
    // The app's own window: nsh's launch window is an invisible host that never shows. Closing
    // it quits, as closing the launch window did; with the tray icon on, Close hides it instead
    // (`shell`).
    set_quit_mode(QuitMode::LastWindowClosed);
    window().id("main").title("Listenook").default_size(size(px(1180.0), px(760.0))).content(move || content(store))
}

fn content(store: state::Store) -> impl IntoElement {
    view()
        .flex_1()
        // Full screen, the picture reaches every edge: the pages keep their own controls clear of them.
        .style_when(move || !shell::stack_reaches_top() && !store.immersive(), |s| s.pt_safe_area())
        .style_when(move || !store.immersive(), |s| s.px_safe_area())
        .style_when(move || !shell::tab_bar_shown() && !store.immersive(), |s| s.pb_safe_area())
        .bg(move || if store.immersive() { ui::tokens::ink(ui::tokens::Ink::Stage) } else { theme().background })
        .text_color(move || theme().foreground)
        .child(shell::shell())
        .child(
            view()
                .absolute()
                .left(px(0.0))
                .right(px(0.0))
                .bottom(px(64.0))
                .items_center()
                .pointer_events(nsh_core::PointerEvents::BoxNone)
                .child(ui::ToastHost),
        )
}
