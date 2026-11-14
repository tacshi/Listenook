mod pages;
mod platform;
mod services;
mod shell;
mod state;
mod ui;
mod util;

use nsh_base::theme;
use nsh_core::prelude::*;

#[native_module("listenook/native")]
fn native(registry: &mut Registry) {
    registry.register::<App>();
}

#[component]
pub fn App() -> impl IntoElement {
    let store = state::Store::install();
    effect(move || set_color_scheme(if store.immersive() { Appearance::Dark } else { store.appearance() }));
    view()
        .flex_1()
        .style_when(|| !shell::stack_reaches_top(), |s| s.pt_safe_area())
        .px_safe_area()
        .style_when(|| !shell::tab_bar_shown(), |s| s.pb_safe_area())
        .bg(move || if store.immersive() { ui::tokens::stage() } else { theme().background })
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
                .child(ui::toast_host()),
        )
}
