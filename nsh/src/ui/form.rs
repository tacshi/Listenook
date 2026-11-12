//! Fields and selection controls.

use nsh_base::{SelectEntry, SelectItem, SliderValue, input, theme};
use nsh_core::prelude::*;

use super::{
    icons::{Icon, icon},
    tokens::{self, motion},
};

fn field_look(field: Input) -> Input {
    field
        .placeholder_color(|| color(theme().muted_foreground))
        .caret_color(|| color(theme().primary))
        .px_3()
        .text_sm()
        .text_color(|| theme().foreground)
        .rounded(tokens::radius)
        .border_1()
        .border_color(|| theme().muted)
        .bg(|| theme().muted)
        .transition_colors()
        .duration(motion::INSTANT)
        .focus(|s| s.border_color(|| theme().ring))
}

/// A single-line text field bound to `value`.
pub fn text_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> Input {
    field_look(
        input()
            .value(move || value.get())
            .on_change(move |text: &str| value.set(text.to_owned()))
            .placeholder(move || placeholder().to_string()),
    )
    .h(px(40.0))
}

/// A multi-line text field bound to `value`.
pub fn text_area(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> Input {
    field_look(
        input()
            .value(move || value.get())
            .on_change(move |text: &str| value.set(text.to_owned()))
            .placeholder(move || placeholder().to_string())
            .multiline(true),
    )
    .py_2()
    .min_h(px(72.0))
}

/// A search field: a text field with a leading glass.
pub fn search_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> View {
    search_field_with(value, placeholder, false)
}

/// A [`search_field`] that takes the keyboard as it appears: for one
/// the user just asked for.
pub fn focused_search_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> View {
    search_field_with(value, placeholder, true)
}

fn search_field_with(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static, focused: bool) -> View {
    view()
        .flex_row()
        .items_center()
        .gap_2()
        .h(px(32.0))
        .px_3()
        .rounded(tokens::radius)
        .border_1()
        .border_color(|| theme().muted)
        .bg(|| theme().muted)
        .text_color(|| theme().muted_foreground)
        .focus_within(|s| s.border_color(|| theme().ring))
        .child(icon(Icon::Search, 18.0))
        .child(
            input()
                .value(move || value.get())
                .on_change(move |text: &str| value.set(text.to_owned()))
                .placeholder(move || placeholder().to_string())
                .placeholder_color(|| color(theme().muted_foreground))
                .caret_color(|| color(theme().primary))
                .auto_focus(focused)
                .flex_1()
                .text_sm()
                .text_color(|| theme().foreground),
        )
}

/// A label over a control, with an optional description under it.
pub fn field(label: impl IntoReactive<SharedString>, control: impl IntoElement) -> View {
    view()
        .gap_1p5()
        .child(text(label).text_sm().font_weight(FontWeight::MEDIUM).text_color(|| theme().foreground))
        .child(control)
}

/// Supporting text under a control or a title.
pub fn hint(label: impl IntoReactive<SharedString>) -> Text {
    text(label).text_xs().text_color(|| theme().muted_foreground)
}

/// A switch with its label: a setting that takes effect at once.
pub fn switch(
    label: impl IntoReactive<SharedString>,
    checked: impl Fn() -> bool + 'static,
    on_change: impl Fn(bool) + 'static,
) -> nsh_base::SwitchElement {
    nsh_base::switch()
        .checked(checked)
        .on_change(move |next: &bool| on_change(*next))
        .flex_row()
        .items_center()
        .gap_3()
        .track_style(|s| {
            s.w(px(36.0))
                .p(px(2.0))
                .rounded_full()
                .bg(|| theme().input)
                .transition_colors()
                .duration(motion::FAST)
                .checked(|s| s.bg(|| theme().primary))
        })
        .thumb_style(|s| {
            s.size(px(16.0))
                .rounded_full()
                .bg(|| theme().card)
                .shadow_sm()
                .transition_transform()
                .duration(motion::FAST)
                .checked(|s| s.translate_x(px(16.0)))
        })
        .focus(tokens::focus_ring)
        .disabled_style(|s| s.opacity(0.45))
        // The label takes the room left and wraps: a long setting's name
        // must not push the switch out of a narrow panel.
        .child(text(label).text_sm().flex_1().min_w(px(0.0)).text_color(|| theme().foreground))
}

/// A checkbox with its label: an independent choice.
pub fn checkbox(
    label: impl IntoReactive<SharedString>,
    checked: impl Fn() -> bool + Copy + 'static,
    on_change: impl Fn(bool) + 'static,
) -> nsh_base::CheckboxElement {
    nsh_base::checkbox()
        .checked(checked)
        .on_change(move |next: &bool| on_change(*next))
        .flex_row()
        .items_center()
        .gap_2()
        .indicator_style(|s| {
            s.size(px(16.0))
                .items_center()
                .justify_center()
                .rounded(tokens::radius_sm)
                .border_1()
                .border_color(|| theme().input)
                .text_color(|| theme().primary_foreground)
                .checked(|s| s.bg(|| theme().primary).border_color(|| theme().primary))
        })
        .indicator(when(checked, || icon(Icon::Check, 12.0)))
        .focus(tokens::focus_ring)
        .child(text(label).text_sm().text_color(|| theme().foreground))
}

/// A choice from a list: `options` are `(value, label)`.
pub fn select(
    name: impl Into<SharedString>,
    options: Vec<(SharedString, SharedString)>,
    value: impl Fn() -> SharedString + Copy + 'static,
    on_change: impl Fn(SharedString) + 'static,
) -> nsh_base::SelectElement {
    let labels = options.clone();
    let shown = move || {
        let current = value();
        labels.iter().find(|(v, _)| *v == current).map(|(_, label)| label.clone()).unwrap_or(current)
    };
    let touch = crate::platform::is_phone();
    nsh_base::select()
        .items(options.into_iter().map(|(v, label)| SelectItem::new(v, label)).collect::<Vec<_>>())
        .value(move || Some(value()))
        .on_change(move |next: &Option<SharedString>| {
            if let Some(next) = next {
                on_change(next.clone());
            }
        })
        .accessibility_label(name.into())
        .offset(px(4.0))
        // Under a finger the choices are taller, and clear of the bar at
        // the foot of the screen.
        .popup_style(move |s| {
            let s = tokens::popup_surface(s).max_h(px(320.0));
            if touch { s.pb_8() } else { s }
        })
        .item_class(if touch {
            "rounded-md px-3 py-3 focus:bg-accent hover:bg-accent selected:font-medium disabled:opacity-50"
        } else {
            "rounded-md px-2 py-1.5 focus:bg-accent hover:bg-accent selected:font-medium disabled:opacity-50"
        })
        .render_item(move |item: &SelectEntry| {
            let title = text(item.title.clone()).text_color(|| theme().popover_foreground);
            if touch { title.text_base() } else { title.text_sm() }
        })
        .trigger(
            view()
                .h(px(40.0))
                .flex_row()
                .items_center()
                .justify_between()
                .gap_2()
                .px_3()
                .rounded(tokens::radius)
                .border_1()
                .border_color(|| theme().muted)
                .bg(|| theme().muted)
                .text_color(|| theme().muted_foreground)
                .hover(|s| s.bg(|| theme().accent))
                .child(text(shown).text_sm().number_of_lines(1).text_color(|| theme().foreground))
                .child(icon(Icon::ChevronDown, 16.0)),
        )
}

/// A segmented control: a few exclusive views of one thing, one selection
/// sliding between them. The labels are given untranslated and shown in
/// the interface language, which they follow when it changes.
pub fn segmented<T: Copy + PartialEq + 'static>(
    options: Vec<(T, &'static str)>,
    value: impl Fn() -> T + Copy + 'static,
    on_change: impl Fn(T) + Copy + 'static,
) -> nsh_base::TabsElement {
    nsh_base::tabs()
        .flex_row()
        .self_start()
        .p(px(2.0))
        .rounded(tokens::radius)
        .border_1()
        .border_color(|| theme().border)
        .indicator_style(|s| s.top(px(2.0)).bottom(px(2.0)).rounded(tokens::radius_sm).bg(|| theme().accent))
        .children(options.into_iter().map(move |(option, label)| {
            let selected = move || value() == option;
            nsh_base::tab()
                .selected(selected)
                .on_press(move |_: &()| on_change(option))
                .h(px(32.0))
                .min_w(px(88.0))
                .px_4()
                .items_center()
                .justify_center()
                .rounded(tokens::radius_sm)
                .focus(tokens::focus_ring)
                .child(
                    text(crate::state::l(label))
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .transition_colors()
                        .duration(motion::FAST)
                        .text_color(move || if selected() { theme().foreground } else { theme().muted_foreground }),
                )
        }))
}

/// A slider from `min` to `max`. `on_change` hears every value of a drag,
/// `on_commit` the one it ends at.
pub fn slider(
    name: impl Into<SharedString>,
    value: impl Fn() -> f64 + 'static,
    max: impl Fn() -> f64 + 'static,
    on_change: impl Fn(f64) + 'static,
    on_commit: impl Fn(f64) + 'static,
) -> nsh_base::SliderElement {
    slider_in(false, name, value, max, on_change, on_commit)
}

/// A [`slider`] lying over a video: light on dark in either theme.
pub fn slider_on_picture(
    name: impl Into<SharedString>,
    value: impl Fn() -> f64 + 'static,
    max: impl Fn() -> f64 + 'static,
    on_change: impl Fn(f64) + 'static,
    on_commit: impl Fn(f64) + 'static,
) -> nsh_base::SliderElement {
    slider_in(true, name, value, max, on_change, on_commit)
}

fn slider_in(
    on_picture: bool,
    name: impl Into<SharedString>,
    value: impl Fn() -> f64 + 'static,
    max: impl Fn() -> f64 + 'static,
    on_change: impl Fn(f64) + 'static,
    on_commit: impl Fn(f64) + 'static,
) -> nsh_base::SliderElement {
    let single = |value: &SliderValue| match value {
        SliderValue::Single(v) => *v,
        SliderValue::Range(_, v) => *v,
    };
    // Over a picture the dark theme's light is used whatever the theme.
    let track = move || if on_picture { theme().foreground.dark.opacity(0.3) } else { color(theme().input) };
    let fill = move || if on_picture { theme().foreground.dark } else { color(theme().primary) };
    nsh_base::slider()
        .value(move || Some(SliderValue::Single(value())))
        .min(0.0)
        .max(move || max().max(1.0))
        .step(1.0)
        .on_change(move |value: &SliderValue| on_change(single(value)))
        .on_change_end(move |value: &SliderValue| on_commit(single(value)))
        .accessibility_label(name.into())
        .h(px(20.0))
        .justify_center()
        .track_style(move |s| s.h(px(4.0)).rounded_full().bg(track))
        // The rail the thumb is centered on: as tall as the track, or the
        // thumb is centered on the track's top edge instead of its middle.
        .indicator_style(|s| s.h(px(4.0)))
        .range_style(move |s| s.h(px(4.0)).rounded_full().bg(fill))
        .thumb_style(move |s| s.size(px(12.0)).rounded_full().bg(fill).shadow_sm().transition_transform())
}

/// A progress bar: `fraction` from 0 to 1, or none while the length is unknown.
pub fn progress_bar(fraction: impl Fn() -> Option<f32> + Copy + 'static) -> nsh_base::ProgressElement {
    nsh_base::progress()
        .value(move || fraction().unwrap_or(0.0) * 100.0)
        .indeterminate(move || fraction().is_none())
        .h(px(4.0))
        .rounded_full()
        .overflow_hidden()
        .track_style(|s| s.h(px(4.0)).rounded_full().bg(|| theme().input))
        .indicator_style(|s| s.h(px(4.0)).rounded_full().bg(|| theme().primary).transition_all().duration(motion::BASE))
}
