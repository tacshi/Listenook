use nsh_base::{ButtonElement, theme, tooltip};
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon, icon_of},
    tokens::{self, motion},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Variant {
    Primary,
    Default,
    Outline,
    Ghost,
    Danger,
    Picture,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Size {
    Sm,
    Md,
}

impl Size {
    pub(crate) fn height(self) -> f32 {
        match (self, crate::platform::is_phone()) {
            (Size::Sm, false) => 28.0,
            (Size::Md, false) => 32.0,
            (Size::Sm, true) => 32.0,
            (Size::Md, true) => 40.0,
        }
    }

    pub(crate) fn icon(self) -> f32 {
        match (self, crate::platform::is_phone()) {
            (Size::Sm, false) => 14.0,
            (Size::Md, false) => 16.0,
            (Size::Sm, true) => 18.0,
            (Size::Md, true) => 20.0,
        }
    }
}

fn dressed(element: ButtonElement, variant: Variant, size: Size, square: bool) -> ButtonElement {
    let scale = tokens::press_scale(square);
    let element = element
        .h(px(size.height()))
        .flex_row()
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .rounded(tokens::radius)
        .transition_all()
        .duration(motion::INSTANT)
        .ease_out()
        .focus_visible(tokens::focus_ring)
        .disabled_style(|s| s.opacity(0.45));
    let element = if square {
        element.w(px(size.height()))
    } else {
        match size {
            Size::Sm => element.px_3().gap_1p5(),
            Size::Md => element.px_4().gap_2(),
        }
    };
    match variant {
        Variant::Primary => element
            .bg(|| theme().primary)
            .text_color(|| theme().primary_foreground)
            .hover(|s| s.bg(tokens::primary_hover))
            .active(move |s| s.bg(tokens::primary_active).scale(scale)),
        Variant::Default => element
            .bg(|| theme().secondary)
            .text_color(|| theme().secondary_foreground)
            .hover(|s| s.bg(|| theme().accent))
            .active(move |s| s.bg(|| theme().input).scale(scale)),
        Variant::Outline => element
            .border_1()
            .border_color(|| theme().input)
            .text_color(|| theme().primary)
            .hover(|s| s.bg(|| theme().muted))
            .active(move |s| s.bg(|| theme().accent).scale(scale)),
        Variant::Ghost => element
            .text_color(|| theme().foreground)
            .hover(|s| s.bg(|| theme().accent))
            .active(move |s| s.bg(|| theme().input).scale(scale)),
        Variant::Danger => element
            .text_color(|| theme().destructive)
            .hover(|s| s.bg(|| theme().destructive.opacity(0.1)))
            .active(move |s| s.bg(|| theme().destructive.opacity(0.18)).scale(scale)),
        Variant::Picture => element
            .text_color(|| theme().foreground.dark)
            .hover(|s| s.bg(|| theme().foreground.dark.opacity(0.14)))
            .active(move |s| s.bg(|| theme().foreground.dark.opacity(0.24)).scale(scale)),
    }
}

fn label_text(label: impl IntoReactive<SharedString>, size: Size) -> Text {
    let label = text(label).font_weight(FontWeight::MEDIUM).number_of_lines(1);
    match size {
        Size::Sm => label.text_sm(),
        Size::Md => label.text_sm(),
    }
}

pub fn button(variant: Variant, size: Size, label: impl IntoReactive<SharedString>) -> ButtonElement {
    dressed(nsh_base::button(), variant, size, false).child(label_text(label, size))
}

pub fn icon_text_button(
    variant: Variant,
    size: Size,
    glyph: Icon,
    label: impl IntoReactive<SharedString>,
) -> ButtonElement {
    dressed(nsh_base::button(), variant, size, false).child(icon(glyph, size.icon())).child(label_text(label, size))
}

pub fn icon_button(glyph: Icon, name: impl Into<SharedString>, size: Size, on_press: impl Fn() + 'static) -> View {
    icon_button_as(Variant::Ghost, glyph, name, size, on_press)
}

pub fn icon_button_as(
    variant: Variant,
    glyph: Icon,
    name: impl Into<SharedString>,
    size: Size,
    on_press: impl Fn() + 'static,
) -> View {
    let name: SharedString = name.into();
    view().flex_shrink_0().tooltip(tip(name.clone())).child(
        dressed(nsh_base::button(), variant, size, true)
            .accessibility_label(name)
            .on_press(on_press)
            .child(icon(glyph, size.icon())),
    )
}

pub fn header_button(glyph: Icon, name: impl Into<SharedString>, on_press: impl Fn() + 'static) -> ButtonElement {
    dressed(nsh_base::button(), Variant::Ghost, Size::Md, true)
        .accessibility_label(name.into())
        .on_press(on_press)
        .child(icon(glyph, Size::Md.icon()))
}

pub fn bar_button(glyph: Icon, name: impl Into<SharedString>, on_press: impl Fn() + 'static) -> ButtonElement {
    nsh_base::button()
        .accessibility_label(name.into())
        .on_press(on_press)
        .size(px(44.0))
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .rounded_full()
        .style_with(tokens::bar_glass)
        .text_color(|| theme().foreground)
        .transition_all()
        .duration(motion::INSTANT)
        .active(|s| s.scale(tokens::press_scale(true)).opacity(0.7))
        .focus_visible(tokens::focus_ring)
        .child(icon(glyph, 24.0))
}

pub fn toggle_button(
    variant: Variant,
    glyph: Icon,
    name: impl Into<SharedString>,
    size: Size,
    on: impl Fn() -> bool + Copy + 'static,
    on_press: impl Fn() + 'static,
) -> View {
    let name: SharedString = name.into();
    let lit = move || if variant == Variant::Picture { theme().primary.dark } else { color(theme().primary) };
    view().flex_shrink_0().tooltip(tip(name.clone())).child(
        dressed(nsh_base::button(), variant, size, true)
            .selected(on)
            .selected_style(move |s| s.bg(move || lit().opacity(0.16)).text_color(lit))
            .accessibility_label(name)
            .on_press(on_press)
            .child(icon(glyph, size.icon())),
    )
}

pub fn menu_trigger(glyph: Icon, name: impl Into<SharedString>, size: Size, open: Signal<bool>) -> View {
    let scale = tokens::press_scale(true);
    let side = size.height();
    let name: SharedString = name.into();
    view()
        .size(px(side))
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .rounded(tokens::radius)
        .label(name.clone())
        .tooltip(tip(name))
        .text_color(|| theme().foreground)
        .transition_all()
        .duration(motion::INSTANT)
        .ease_out()
        .bg(move || if open.get() { theme().accent } else { theme().accent.opacity(0.0) })
        .hover(|s| s.bg(|| theme().accent))
        .active(move |s| s.bg(|| theme().input).scale(scale))
        .focus_visible(tokens::focus_ring)
        .child(icon(glyph, size.icon()))
}

pub fn toggle_icon_button(
    glyph: impl Fn() -> Icon + 'static,
    name: impl Fn() -> SharedString + Clone + 'static,
    variant: Variant,
    size: Size,
) -> ButtonElement {
    dressed(nsh_base::button(), variant, size, true)
        .accessibility_label(move || Some(name()))
        .child(icon_of(glyph, size.icon()))
}

pub fn tip(label: SharedString) -> nsh_base::TooltipElement {
    tooltip()
        .starting_class("opacity-0 transition-opacity duration-150")
        .ending_class("opacity-0 transition-opacity duration-100")
        .child(
            view()
                .px_2()
                .py_1()
                .rounded(tokens::radius_sm)
                .bg(|| theme().foreground)
                .child(text(label).text_xs().text_color(|| theme().background)),
        )
}
