//! Listenook, written in Rust on Native Shell: `nsh.json` `"root"` names [`App`].

mod pages;
mod platform;
mod services;
mod shell;
mod state;
mod ui;
mod util;

use nsh_base::theme;
use nsh_core::prelude::*;

/// The app's UI set (`nsh.json` `"rust"`).
#[native_module("listenook/native")]
fn native(registry: &mut Registry) {
    registry.register::<App>();
}

/// The app's root: the store, the whole surface on the theme's background,
/// the shell and the toasts over it.
#[component]
pub fn App() -> impl IntoElement {
    let store = state::Store::install();
    // A video filling the screen is watched in the dark, whatever the
    // theme: its controls and their menus are the dark ones.
    effect(move || set_color_scheme(if store.immersive() { Appearance::Dark } else { store.appearance() }));
    view()
        .flex_1()
        // Clear of the status bar and the home indicator on a phone. The
        // system's tab bar reaches the bottom edge itself.
        .pt_safe_area()
        .px_safe_area()
        .style_when(|| !shell::tab_bar_shown(), |s| s.pb_safe_area())
        // Under a video filling the screen, the edges it leaves are dark too.
        .bg(move || if store.immersive() { ui::tokens::stage() } else { theme().background })
        .text_color(move || theme().foreground)
        .child(shell::shell())
        // Over the window, not in its layout: a toast must not push the
        // app up to make room for itself.
        .child(view().absolute().left(px(0.0)).right(px(0.0)).bottom(px(64.0)).items_center().child(ui::toast_host()))
}
