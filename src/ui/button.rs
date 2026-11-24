use nsh_base::{ButtonElement, theme, tooltip};
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon, icon_of},
    layout::key_cap,
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

/// A button's look, on a button or on the view a menu opens from (whose
/// styling methods come from other traits, so this is a macro).
macro_rules! dress {
    ($element:expr, $variant:expr, $size:expr, $square:expr) => {{
        let (variant, size, square) = ($variant, $size, $square);
        let scale = tokens::press_scale(square);
        let element = $element
            .h(px(size.height()))
            .flex_row()
            .flex_shrink_0()
            .items_center()
            .justify_center()
            .rounded(tokens::radius)
            .transition_all()
            .duration(motion::INSTANT)
            .ease_out()
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
    }};
}

fn dressed(element: ButtonElement, variant: Variant, size: Size, square: bool) -> ButtonElement {
    dress!(element, variant, size, square)
}

/// A menu's trigger dressed as a button: a view the menu itself presses
/// ([`super::menu`]), named `name` for screen readers.
fn dressed_trigger(name: SharedString, variant: Variant, size: Size, square: bool) -> View {
    dress!(view(), variant, size, square).role(AccessibilityRole::Button).label(name)
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

/// [`button`] opening a menu: `label` shows, `name` is what screen readers
/// say (Playback speed for "1×").
pub fn menu_button(
    variant: Variant,
    size: Size,
    name: impl Into<SharedString>,
    label: impl IntoReactive<SharedString>,
) -> View {
    dressed_trigger(name.into(), variant, size, false).child(label_text(label, size))
}

/// [`icon_text_button`] opening a menu, named by what it shows.
pub fn menu_icon_text_button(
    variant: Variant,
    size: Size,
    glyph: Icon,
    label: impl IntoReactive<SharedString>,
) -> View {
    dress!(view(), variant, size, false)
        .role(AccessibilityRole::Button)
        .child(icon(glyph, size.icon()))
        .child(label_text(label, size))
}

/// The recording light: a dot in `recording` that breathes while `live`
/// (it rests while paused, and with reduced motion).
pub fn recording_dot(live: impl Fn() -> bool + 'static, side: f32) -> View {
    let live = std::rc::Rc::new(live);
    let calm = live.clone();
    view().size(px(side)).items_center().justify_center().child(
        when(
            move || live() && !reduce_motion(),
            move || {
                let breath = motion();
                let _ = breath.play(MotionPreset::Breathe);
                view().bind_motion(&breath).size(px(side)).rounded_full().bg(tokens::recording)
            },
        )
        .otherwise(move || {
            let calm = calm.clone();
            view()
                .size(px(side))
                .rounded_full()
                .bg(move || if calm() { tokens::recording() } else { theme().muted_foreground })
        }),
    )
}

/// A small outline button standing for a recording under way: its light
/// and how long it has run, in tabular figures. Pressed, it shows it.
pub fn recording_button(
    name: impl Into<SharedString>,
    live: impl Fn() -> bool + 'static,
    elapsed: impl IntoReactive<SharedString>,
) -> ButtonElement {
    dressed(nsh_base::button(), Variant::Outline, Size::Sm, false)
        .accessibility_label(name.into())
        .text_color(|| theme().foreground)
        .child(recording_dot(live, 8.0))
        .child(label_text(elapsed, Size::Sm).tabular_nums())
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

/// A button floating over what it acts on (Jump to playing): on the popup
/// surface, with the shadow of what floats.
pub fn floating_button(glyph: impl Fn() -> Icon + 'static, label: impl IntoReactive<SharedString>) -> ButtonElement {
    let scale = tokens::press_scale(false);
    nsh_base::button()
        .h(px(Size::Sm.height()))
        .flex_row()
        .flex_shrink_0()
        .items_center()
        .gap_1p5()
        .px_3()
        .rounded(tokens::radius)
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().popover)
        .text_color(|| theme().foreground)
        .shadow_lg()
        .bind_motion(&motion().entering(MotionPreset::FadeInUp))
        .transition_colors()
        .duration(motion::INSTANT)
        .ease_out()
        .hover(|s| s.bg(|| theme().accent))
        .active(move |s| s.bg(|| theme().input).scale(scale))
        .child(icon_of(glyph, Size::Sm.icon()))
        .child(label_text(label, Size::Sm))
}

/// A small icon button that also shows its shortcut's key cap (Replay ⌘R):
/// the glyph says it can be pressed, the key how to without the pointer.
pub fn shortcut_button(
    glyph: Icon,
    name: impl Into<SharedString>,
    keystroke: &'static str,
    on_press: impl Fn() + 'static,
) -> View {
    let name: SharedString = name.into();
    view().flex_shrink_0().tooltip(tip(name.clone())).child(
        dressed(nsh_base::button(), Variant::Ghost, Size::Sm, false)
            .px_2()
            .accessibility_label(name)
            .on_press(on_press)
            .child(icon(glyph, Size::Sm.icon()))
            .child(key_cap(keystroke)),
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

/// A button opening a menu, showing `glyph`, with `label` beside it while
/// there is one, lit while `on`: a timer's button showing what is left.
/// While `crowded`, the label shows in place of the glyph.
pub fn menu_glyph_label_button(
    variant: Variant,
    size: Size,
    name: impl Into<SharedString>,
    glyph: Icon,
    label: impl Fn() -> Option<SharedString> + Copy + 'static,
    on: impl Fn() -> bool + Copy + 'static,
    crowded: impl Fn() -> bool + Copy + 'static,
) -> View {
    let lit = move || if variant == Variant::Picture { theme().primary.dark } else { color(theme().primary) };
    dressed_trigger(name.into(), variant, size, false)
        .px(px((size.height() - size.icon()) / 2.0))
        .min_w(px(size.height()))
        .style_when(on, move |s| s.bg(move || lit().opacity(0.16)).text_color(lit))
        .child(when(move || label().is_none() || !crowded(), move || icon(glyph, size.icon())))
        .child(when(
            move || label().is_some(),
            move || {
                label_text(move || label().unwrap_or_default(), size)
                    .tabular_nums()
                    .style_when(move || !crowded(), |s| s.pr(px(2.0)))
            },
        ))
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
