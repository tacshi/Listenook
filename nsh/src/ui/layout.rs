//! The pieces pages are laid out with: headers, cards, rows, badges and the
//! states of content.

use nsh_base::theme;
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon},
    tokens::{self, motion},
};

/// The inset every page region shares, so their content starts on one line.
pub const PAGE_INSET: f32 = 24.0;

/// A flat surface with a hairline: a group of settings, a panel.
pub fn card() -> View {
    view().rounded(tokens::radius_lg).border_1().border_color(|| theme().border).bg(|| theme().card)
}

/// A titled group inside a page.
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

/// A hairline between regions.
pub fn separator() -> View {
    view().h(px(1.0)).flex_shrink_0().bg(|| theme().border)
}

/// The meaning a badge or status dot carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Neutral,
    Active,
    Success,
    Warning,
    Danger,
}

impl Status {
    /// The status's color.
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

/// A short state or count.
pub fn badge(label: impl IntoReactive<SharedString>, status: impl Fn() -> Status + Copy + 'static) -> View {
    view()
        .px_1p5()
        .py(px(1.0))
        .rounded(tokens::radius_sm)
        .bg(move || status().color().opacity(0.12))
        .child(text(label).text_xs().font_weight(FontWeight::MEDIUM).text_color(move || status().color()))
}

/// What a region shows when it has nothing: what belongs here and, as
/// `action`, how to get it.
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

/// A turning ring: work of unknown length.
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

/// A pressable row of a list: a hover wash, a deeper press, a selected fill.
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
        .hover(|s| s.bg(|| theme().muted))
        .active(|s| s.bg(|| theme().accent))
        .selected_style(|s| s.bg(|| theme().accent))
        .focus(tokens::focus_ring)
}

/// A key as it is printed on the keyboard.
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
                .font_family(|| theme().font_mono.clone().unwrap_or_else(|| "Menlo".into()))
                .text_color(|| theme().muted_foreground),
        )
}

/// Content the user chose not to see yet (blind listening): while `hidden`
/// a quiet bar of the same size stands in for it, so the layout does not
/// move when it is revealed. The content is built again when it flips.
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

/// One of a few exclusive choices shown side by side: lit when chosen.
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
        .hover(|s| s.bg(|| theme().muted))
        .active(|s| s.bg(|| theme().accent))
        .focus(tokens::focus_ring)
        .child(
            text(label)
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(move || if selected() { theme().primary } else { theme().muted_foreground }),
        )
}
