//! Buttons: one press feedback, one focus ring and one disabled look for
//! the whole app. A caller gives meaning (variant, size, label, icon) and
//! layout; the look is here.

use nsh_base::{ButtonElement, theme, tooltip};
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon, icon_of},
    tokens::{self, motion},
};

/// What a button means where it stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Variant {
    /// The default commit of a decision area.
    Primary,
    /// An ordinary visible action.
    Default,
    /// An action with a boundary and less weight.
    Outline,
    /// A quiet toolbar or inline action.
    Ghost,
}

/// A control's size: height, padding, text and icon together.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Size {
    Sm,
    Md,
}

impl Size {
    fn height(self) -> f32 {
        match self {
            Size::Sm => 32.0,
            Size::Md => 40.0,
        }
    }

    fn icon(self) -> f32 {
        match self {
            Size::Sm => 18.0,
            Size::Md => 20.0,
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
        .focus(tokens::focus_ring)
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
    }
}

fn label_text(label: impl IntoReactive<SharedString>, size: Size) -> Text {
    let label = text(label).font_weight(FontWeight::MEDIUM).number_of_lines(1);
    match size {
        Size::Sm => label.text_sm(),
        Size::Md => label.text_sm(),
    }
}

/// A button with a label. Chain `.on_press(..)`, `.disabled(..)` and layout.
pub fn button(variant: Variant, size: Size, label: impl IntoReactive<SharedString>) -> ButtonElement {
    dressed(nsh_base::button(), variant, size, false).child(label_text(label, size))
}

/// A button with a leading icon and a label.
pub fn icon_text_button(
    variant: Variant,
    size: Size,
    glyph: Icon,
    label: impl IntoReactive<SharedString>,
) -> ButtonElement {
    dressed(nsh_base::button(), variant, size, false).child(icon(glyph, size.icon())).child(label_text(label, size))
}

/// A square button showing only an icon. `name` is what screen readers say
/// and what the tooltip shows.
pub fn icon_button(glyph: Icon, name: impl Into<SharedString>, size: Size, on_press: impl Fn() + 'static) -> View {
    let name: SharedString = name.into();
    view().flex_shrink_0().tooltip(tip(name.clone())).child(
        dressed(nsh_base::button(), Variant::Ghost, size, true)
            .accessibility_label(name)
            .on_press(on_press)
            .child(icon(glyph, size.icon())),
    )
}

/// An icon button for the system's header on a phone or a tablet, where
/// the system draws its own button and presses this one for it: the
/// button alone, with no tooltip around it to take that press.
pub fn header_button(glyph: Icon, name: impl Into<SharedString>, on_press: impl Fn() + 'static) -> ButtonElement {
    dressed(nsh_base::button(), Variant::Ghost, Size::Md, true)
        .accessibility_label(name.into())
        .on_press(on_press)
        .child(icon(glyph, Size::Md.icon()))
}

/// A round button of a bar the app draws where the system's header would
/// be, on a phone or a tablet: the size and the look of the system's own.
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
        .focus(tokens::focus_ring)
        .child(icon(glyph, 24.0))
}

/// An icon button whose glyph and name follow state (play / pause).
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

/// The app's tooltip: a small inverted label.
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
