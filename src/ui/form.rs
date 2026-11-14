use nsh_base::{SelectEntry, SelectItem, SliderValue, input, theme};
use nsh_core::prelude::*;

use super::{
    button::Size,
    icons::{Icon, icon},
    tokens::{self, motion},
};

fn field_look(field: Input) -> Input {
    field_text(field)
        .px_3()
        .rounded(tokens::radius)
        .border_1()
        .border_color(tokens::control_border)
        .bg(|| theme().card)
        .transition_colors()
        .duration(motion::INSTANT)
        .focus(|s| s.border_color(|| theme().ring))
}

fn field_text(field: Input) -> Input {
    field
        .placeholder_color(|| color(theme().muted_foreground))
        .caret_color(|| color(theme().primary))
        .text_sm()
        .text_color(|| theme().foreground)
}

fn line_field(input: Input) -> View {
    if cfg!(target_os = "ios") {
        view()
            .flex_row()
            .items_center()
            .h(px(Size::Md.height()))
            .px_3()
            .rounded(tokens::radius)
            .border_1()
            .border_color(tokens::control_border)
            .bg(|| theme().card)
            .focus_within(|s| s.border_color(|| theme().ring))
            .child(field_text(input).flex_1().h_full())
    } else {
        view().child(field_look(input).h(px(Size::Md.height())))
    }
}

pub fn bound_field(
    value: impl Fn() -> String + 'static,
    set: impl Fn(String) + 'static,
    placeholder: impl Fn() -> SharedString + 'static,
) -> View {
    bound_field_with(value, set, placeholder, |input| input)
}

pub fn bound_field_with(
    value: impl Fn() -> String + 'static,
    set: impl Fn(String) + 'static,
    placeholder: impl Fn() -> SharedString + 'static,
    more: impl FnOnce(Input) -> Input,
) -> View {
    line_field(more(
        input()
            .value(value)
            .on_change(move |text: &str| set(text.to_owned()))
            .placeholder(move || placeholder().to_string()),
    ))
}

pub fn text_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> View {
    text_field_with(value, placeholder, |input| input)
}

pub fn text_field_with(
    value: Signal<String>,
    placeholder: impl Fn() -> SharedString + 'static,
    more: impl FnOnce(Input) -> Input,
) -> View {
    line_field(more(
        input()
            .value(move || value.get())
            .on_change(move |text: &str| value.set(text.to_owned()))
            .placeholder(move || placeholder().to_string()),
    ))
}

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

pub fn search_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> View {
    search_field_with(value, placeholder, false)
}

pub fn focused_search_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> View {
    search_field_with(value, placeholder, true)
}

fn search_field_with(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static, focused: bool) -> View {
    view()
        .flex_row()
        .items_center()
        .gap_2()
        .h(px(Size::Md.height()))
        .px_3()
        .rounded(tokens::radius)
        .border_1()
        .border_color(tokens::control_border)
        .bg(|| theme().card)
        .text_color(|| theme().muted_foreground)
        .focus_within(|s| s.border_color(|| theme().ring))
        .child(icon(Icon::Search, Size::Md.icon()))
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

pub fn field(label: impl IntoReactive<SharedString>, control: impl IntoElement) -> View {
    view()
        .gap_1p5()
        .child(text(label).text_sm().font_weight(FontWeight::MEDIUM).text_color(|| theme().foreground))
        .child(control)
}

pub fn hint(label: impl IntoReactive<SharedString>) -> Text {
    text(label).text_xs().text_color(|| theme().muted_foreground)
}

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
        .focus_visible(tokens::focus_ring)
        .disabled_style(|s| s.opacity(0.45))
        .child(text(label).text_sm().flex_1().min_w(px(0.0)).text_color(|| theme().foreground))
}

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
                .border_color(tokens::control_border)
                .text_color(|| theme().primary_foreground)
                .checked(|s| s.bg(|| theme().primary).border_color(|| theme().primary))
        })
        .indicator(when(checked, || icon(Icon::Check, 12.0)))
        .focus_visible(tokens::focus_ring)
        .child(text(label).text_sm().text_color(|| theme().foreground))
}

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
                .h(px(Size::Md.height()))
                .flex_row()
                .items_center()
                .justify_between()
                .gap_2()
                .px_3()
                .rounded(tokens::radius)
                .border_1()
                .border_color(tokens::control_border)
                .bg(|| theme().card)
                .text_color(|| theme().muted_foreground)
                .transition_colors()
                .duration(motion::INSTANT)
                .hover(|s| s.bg(|| theme().muted))
                .focus_visible(tokens::focus_ring)
                .child(text(shown).text_sm().number_of_lines(1).text_color(|| theme().foreground))
                .child(icon(Icon::ChevronDown, Size::Md.icon())),
        )
}

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
                .focus_visible(tokens::focus_ring)
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

pub fn slider(
    name: impl Into<SharedString>,
    value: impl Fn() -> f64 + 'static,
    max: impl Fn() -> f64 + 'static,
    on_change: impl Fn(f64) + 'static,
    on_commit: impl Fn(f64) + 'static,
) -> nsh_base::SliderElement {
    slider_in(false, name, value, max, on_change, on_commit)
}

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
        .rounded_full()
        .focus_visible(tokens::focus_ring)
        .track_style(move |s| s.h(px(4.0)).rounded_full().bg(track))
        .indicator_style(|s| s.h(px(4.0)))
        .range_style(move |s| s.h(px(4.0)).rounded_full().bg(fill))
        .thumb_style(move |s| s.size(px(12.0)).rounded_full().bg(fill).shadow_sm().transition_transform())
}

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
