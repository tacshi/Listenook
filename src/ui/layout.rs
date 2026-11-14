use nsh_base::theme;
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon},
    tokens::{self, motion},
};

pub const PAGE_INSET: f32 = 24.0;

pub fn card() -> View {
    view().rounded(tokens::radius_lg).border_1().border_color(|| theme().border).bg(|| theme().card)
}

pub fn section(title: impl IntoReactive<SharedString>, content: impl IntoElement) -> View {
    view()
        .gap_3()
        .child(
            text(title)
                .text_sm()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(|| theme().foreground)
                .role(AccessibilityRole::Header),
        )
        .child(content)
}

pub fn separator() -> View {
    view().h(px(1.0)).flex_shrink_0().bg(|| theme().border)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Neutral,
    Active,
    Success,
    Warning,
    Danger,
}

impl Status {
    pub fn color(self) -> AdaptiveColor {
        match self {
            Status::Neutral => theme().muted_foreground,
            Status::Active => theme().primary,
            Status::Success => tokens::success(),
            Status::Warning => tokens::warning(),
            Status::Danger => theme().destructive,
        }
    }
}

pub fn badge(label: impl IntoReactive<SharedString>, status: impl Fn() -> Status + Copy + 'static) -> View {
    view()
        .px_1p5()
        .py(px(1.0))
        .rounded(tokens::radius_sm)
        .bg(move || status().color().opacity(0.12))
        .child(text(label).text_xs().font_weight(FontWeight::MEDIUM).text_color(move || status().color()))
}

pub fn empty_state(
    glyph: Icon,
    title: impl IntoReactive<SharedString>,
    description: impl IntoReactive<SharedString>,
    action: impl IntoElement,
) -> View {
    let entrance = motion().entering(MotionPreset::FadeIn);
    view()
        .bind_motion(&entrance)
        .flex_1()
        .items_center()
        .justify_center()
        .gap_3()
        .p_8()
        .child(
            view()
                .size(px(48.0))
                .items_center()
                .justify_center()
                .rounded_full()
                .bg(|| theme().muted)
                .text_color(|| theme().muted_foreground)
                .child(icon(glyph, 22.0)),
        )
        .child(
            view()
                .items_center()
                .gap_1()
                .child(text(title).text_base().font_weight(FontWeight::SEMIBOLD).text_color(|| theme().foreground))
                .child(
                    text(description).text_sm().text_center().max_w(px(420.0)).text_color(|| theme().muted_foreground),
                ),
        )
        .child(action)
}

pub fn spinner(size: f32) -> impl IntoElement {
    let turn = motion();
    if !reduce_motion() {
        let _ = turn.play(MotionPreset::Spin);
    }
    view()
        .bind_motion(&turn)
        .size(px(size))
        .text_color(|| theme().muted_foreground)
        .label("Loading")
        .child(icon(Icon::Refresh, size))
}

pub fn list_row(selected: impl Fn() -> bool + 'static) -> nsh_base::ButtonElement {
    nsh_base::button()
        .selected(selected)
        .flex_row()
        .items_center()
        .gap_3()
        .px_3()
        .py_2()
        .rounded(tokens::radius)
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(tokens::hover_wash))
        .active(|s| s.bg(|| theme().input))
        .selected_style(|s| s.bg(|| theme().accent))
        .disabled_style(|s| s.bg(|| theme().background.opacity(0.0)))
        .focus_visible(tokens::focus_ring)
}

pub fn key_cap(keystroke: &'static str) -> View {
    view()
        .px_1p5()
        .py(px(1.0))
        .rounded(tokens::radius_sm)
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().muted)
        .child(
            text(key_label(keystroke))
                .text_xs()
                .font_family(|| theme().font_mono.clone().unwrap_or_else(|| mono_font().into()))
                .text_color(|| theme().muted_foreground),
        )
}

fn mono_font() -> &'static str {
    if cfg!(target_os = "windows") {
        "Consolas"
    } else if cfg!(any(target_os = "macos", target_os = "ios")) {
        "Menlo"
    } else {
        "monospace"
    }
}

pub fn veil<E: IntoElement>(
    hidden: impl Fn() -> bool + 'static,
    content: impl Fn() -> E + Clone + 'static,
) -> impl IntoElement {
    let veiled = content.clone();
    when(hidden, move || {
        view()
            .self_start()
            .rounded(tokens::radius_sm)
            .bg(|| theme().foreground.opacity(0.1))
            .label("Hidden sentence")
            .child(view().opacity(0.0).child(veiled()))
    })
    .otherwise(content)
}

pub fn chip(
    label: impl IntoReactive<SharedString>,
    selected: impl Fn() -> bool + Copy + 'static,
    on_press: impl Fn() + 'static,
) -> nsh_base::ButtonElement {
    nsh_base::button()
        .selected(selected)
        .on_press(on_press)
        .h(px(32.0))
        .px_3()
        .items_center()
        .justify_center()
        .rounded(tokens::radius)
        .border_1()
        .border_color(move || if selected() { theme().primary } else { theme().border })
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(tokens::hover_wash))
        .active(|s| s.bg(|| theme().accent))
        .focus_visible(tokens::focus_ring)
        .child(
            text(label)
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(move || if selected() { theme().primary } else { theme().muted_foreground }),
        )
}
