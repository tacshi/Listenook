use nsh_base::theme;
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon},
    tokens::{self, motion},
};

pub const PAGE_INSET: f32 = 24.0;

pub fn card() -> View {
    view()
        .rounded(|| tokens::corner(tokens::Corner::Large))
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().card)
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

pub(super) fn separator() -> View {
    view().h(px(1.0)).flex_shrink_0().bg(|| theme().border)
}

pub struct Separator;

impl IntoElement for Separator {
    fn into_element(self) -> AnyElement {
        separator().into_element()
    }
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
            Status::Success => tokens::ink(tokens::Ink::Success),
            Status::Warning => tokens::ink(tokens::Ink::Warning),
            Status::Danger => theme().destructive,
        }
    }
}

pub(super) fn badge(label: impl IntoReactive<SharedString>, status: impl Fn() -> Status + Copy + 'static) -> View {
    view()
        .px_1p5()
        .py(px(1.0))
        .rounded(|| tokens::corner(tokens::Corner::Small))
        .bg(move || status().color().opacity(0.12))
        .child(text(label).text_xs().font_weight(FontWeight::MEDIUM).text_color(move || status().color()))
}

pub struct Badge<P0, P1> {
    pub label: P0,
    pub status: P1,
}

impl<P0: IntoReactive<SharedString>, P1: Fn() -> Status + Copy + 'static> IntoElement for Badge<P0, P1> {
    fn into_element(self) -> AnyElement {
        badge(self.label, self.status).into_element()
    }
}

pub(super) fn empty_state(
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
                    text(description)
                        .text_sm()
                        .text_center()
                        .text_pretty()
                        .max_w(px(420.0))
                        .text_color(|| theme().muted_foreground),
                ),
        )
        .child(action)
}

pub struct EmptyState<P1, P2, P3> {
    pub glyph: Icon,
    pub title: P1,
    pub description: P2,
    pub action: P3,
}

impl<P1: IntoReactive<SharedString>, P2: IntoReactive<SharedString>, P3: IntoElement> IntoElement
    for EmptyState<P1, P2, P3>
{
    fn into_element(self) -> AnyElement {
        empty_state(self.glyph, self.title, self.description, self.action).into_element()
    }
}

pub(super) fn spinner(size: f32) -> impl IntoElement {
    let turn = motion();
    if !reduce_motion() {
        let _ = turn.play(MotionPreset::Spin);
    }
    view()
        .bind_motion(&turn)
        .size(px(size))
        .text_color(|| theme().muted_foreground)
        .label(super::tr("Loading"))
        .child(icon(Icon::Refresh, size))
}

pub struct Spinner {
    pub size: f32,
}

impl IntoElement for Spinner {
    fn into_element(self) -> AnyElement {
        spinner(self.size).into_element()
    }
}

pub fn list_row(selected: impl Fn() -> bool + 'static) -> nsh_base::ButtonElement {
    nsh_base::button()
        .selected(selected)
        .flex_row()
        .items_center()
        .gap_3()
        .px_3()
        .py_2()
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(|| tokens::ink(tokens::Ink::HoverWash)))
        .active(|s| s.bg(|| theme().input))
        .selected_style(|s| s.bg(|| theme().accent))
        .disabled_style(|s| s.bg(|| theme().background.opacity(0.0)))
}

/// A card-sized surface pressed as a whole (a Continue or Recently added
/// card): it washes under the pointer, deeper while pressed.
pub fn pressable_card() -> nsh_base::ButtonElement {
    nsh_base::button()
        .rounded(|| tokens::corner(tokens::Corner::Large))
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(|| tokens::ink(tokens::Ink::HoverWash)))
        .active(|s| s.bg(|| theme().accent))
}

/// A small chip for a moment in the recording (an AI Brief's evidence): a
/// play glyph and its time, on `muted`.
pub fn moment_chip(time: impl IntoReactive<SharedString>) -> nsh_base::ButtonElement {
    nsh_base::button()
        .flex_row()
        .items_center()
        .gap_1()
        .h(px(24.0))
        .px_2()
        .rounded(|| tokens::corner(tokens::Corner::Small))
        .bg(|| theme().muted)
        .text_color(|| theme().muted_foreground)
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(|| theme().accent))
        .active(|s| s.bg(|| theme().input))
        .child(icon(Icon::Play, 12.0))
        .child(text(time).text_xs().tabular_nums())
}

pub(super) fn key_cap(keystroke: &'static str) -> View {
    view()
        .px_1p5()
        .py(px(1.0))
        .rounded(|| tokens::corner(tokens::Corner::Small))
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

pub struct KeyCap {
    pub keystroke: &'static str,
}

impl IntoElement for KeyCap {
    fn into_element(self) -> AnyElement {
        key_cap(self.keystroke).into_element()
    }
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
            .rounded(|| tokens::corner(tokens::Corner::Small))
            .bg(|| theme().foreground.opacity(0.1))
            .label(super::tr("Hidden sentence"))
            .child(view().opacity(0.0).child(veiled()))
    })
    .otherwise(content)
}

pub(super) fn chip(
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
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .border_1()
        .border_color(move || if selected() { theme().primary } else { theme().border })
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(|| tokens::ink(tokens::Ink::HoverWash)))
        .active(|s| s.bg(|| theme().accent))
        .child(
            text(label)
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(move || if selected() { theme().primary } else { theme().muted_foreground }),
        )
}

pub struct Chip<P0, P1, P2> {
    pub label: P0,
    pub selected: P1,
    pub on_press: P2,
}

impl<P0: IntoReactive<SharedString>, P1: Fn() -> bool + Copy + 'static, P2: Fn() + 'static> IntoElement
    for Chip<P0, P1, P2>
{
    fn into_element(self) -> AnyElement {
        chip(self.label, self.selected, self.on_press).into_element()
    }
}

/// How wide a composer card grows on a desktop: a comfortable measure for
/// the large answer text.
const COMPOSER_WIDTH: f32 = 720.0;

/// A typing surface docked at the bottom of a page, like a chat's composer:
/// a card filling the height it is given, centred and at most
/// [`COMPOSER_WIDTH`] wide on a desktop, the whole width on a phone or
/// tablet (where it sits on the keyboard) or in a compact window.
pub fn composer_dock(content: impl IntoElement) -> View {
    let roomy = || !crate::platform::is_phone() && !crate::platform::compact();
    view()
        .flex_1()
        .w_full()
        .min_h(px(0.0))
        .items_center()
        .style_with(move |s| if roomy() { s.px(px(PAGE_INSET)).pb_3() } else { s.px_2().pb_2() })
        .child(
            card()
                .flex_1()
                .w_full()
                .min_h(px(0.0))
                .p_3()
                .gap_2()
                .style_when(roomy, |s| s.max_w(px(COMPOSER_WIDTH)))
                .bind_motion(&motion().entering(MotionPreset::FadeInUp))
                .child(content),
        )
}
