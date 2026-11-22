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

pub fn search_field_ref(
    value: Signal<String>,
    placeholder: impl Fn() -> SharedString + 'static,
    input_ref: &ElementRef,
) -> View {
    search_field_with(value, placeholder, false, Some(*input_ref))
}

pub fn focused_search_field(value: Signal<String>, placeholder: impl Fn() -> SharedString + 'static) -> View {
    search_field_with(value, placeholder, true, None)
}

fn search_field_with(
    value: Signal<String>,
    placeholder: impl Fn() -> SharedString + 'static,
    focused: bool,
    input_ref: Option<ElementRef>,
) -> View {
    let field = input()
        .value(move || value.get())
        .on_change(move |text: &str| value.set(text.to_owned()))
        .placeholder(move || placeholder().to_string())
        .placeholder_color(|| color(theme().muted_foreground))
        .caret_color(|| color(theme().primary))
        .auto_focus(focused)
        .flex_1()
        .text_sm()
        .text_color(|| theme().foreground);
    let target = input_ref.unwrap_or_else(element_ref);
    let field = field.element_ref(&target);
    view()
        .flex_row()
        .items_center()
        .gap_2()
        .h(px(Size::Md.height()))
        .pl_3()
        .pr_1()
        .rounded(tokens::radius)
        .border_1()
        .border_color(tokens::control_border)
        .bg(|| theme().card)
        .text_color(|| theme().muted_foreground)
        .focus_within(|s| s.border_color(|| theme().ring))
        .child(icon(Icon::Search, Size::Md.icon()))
        .child(field)
        // Room kept for the clear button, so the text does not shift as it comes.
        .child(view().size(px(Size::Sm.height())).flex_shrink_0().items_center().justify_center().child(when(
            move || value.with(|v| !v.is_empty()),
            move || {
                nsh_base::button()
                    .accessibility_label(crate::state::tr("Clear search"))
                    .on_press(move || {
                        value.set(String::new());
                        target.focus();
                    })
                    .size(px(Size::Sm.height()))
                    .items_center()
                    .justify_center()
                    .rounded(tokens::radius_sm)
                    .text_color(|| theme().muted_foreground)
                    .transition_colors()
                    .duration(motion::INSTANT)
                    .hover(|s| s.bg(|| theme().accent).text_color(|| theme().foreground))
                    .active(|s| s.bg(|| theme().input).scale(tokens::press_scale(true)))
                    .child(icon(Icon::Close, Size::Sm.icon()))
            },
        )))
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

/// A hint saying what went wrong.
pub fn error_hint(label: impl IntoReactive<SharedString>) -> Text {
    text(label).text_xs().text_color(|| theme().destructive)
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
        .disabled_style(|s| s.opacity(0.45))
        .child(text(label).text_sm().flex_1().min_w(px(0.0)).text_color(|| theme().foreground))
}

/// A checkbox's box, `side` points square: `control-border`, filled with
/// `primary` and ticked while checked.
fn ticked(
    checkbox: nsh_base::CheckboxElement,
    checked: impl Fn() -> bool + Copy + 'static,
    side: f32,
) -> nsh_base::CheckboxElement {
    checkbox
        .checked(checked)
        .indicator_style(move |s| {
            s.size(px(side))
                .items_center()
                .justify_center()
                .rounded(tokens::radius_sm)
                .border_1()
                .border_color(tokens::control_border)
                .text_color(|| theme().primary_foreground)
                .checked(|s| s.bg(|| theme().primary).border_color(|| theme().primary))
        })
        .indicator(when(checked, || icon(Icon::Check, 12.0)))
}

pub fn checkbox(
    label: impl IntoReactive<SharedString>,
    checked: impl Fn() -> bool + Copy + 'static,
    on_change: impl Fn(bool) + 'static,
) -> nsh_base::CheckboxElement {
    ticked(nsh_base::checkbox(), checked, 16.0)
        .on_change(move |next: &bool| on_change(*next))
        .flex_row()
        .items_center()
        .gap_2()
        .child(text(label).text_sm().text_color(|| theme().foreground))
}

/// A checkbox that is a whole row of a card, the page laying out what it
/// says beside the box (an icon, a title, a detail): it washes under the
/// pointer.
pub fn checkbox_row(
    name: impl Into<SharedString>,
    checked: impl Fn() -> bool + Copy + 'static,
    on_change: impl Fn(bool) + 'static,
) -> nsh_base::CheckboxElement {
    ticked(nsh_base::checkbox(), checked, 18.0)
        .on_change(move |next: &bool| on_change(*next))
        .accessibility_label(name.into())
        .flex_row()
        .items_center()
        .gap_3()
        .px_3()
        .py_2p5()
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(tokens::hover_wash))
}

/// A choice of one of `options` (value, label). The desktops and narrow touch screens use the base select (a
/// popup, or a sheet at the bottom of a phone); a wider touch screen (a tablet) anchors the list to its trigger.
pub fn select(
    name: impl Into<SharedString>,
    options: Vec<(SharedString, SharedString)>,
    value: impl Fn() -> SharedString + Copy + 'static,
    on_change: impl Fn(SharedString) + 'static,
) -> View {
    if !is_desktop() && !untracked(crate::platform::compact) {
        return view().child(anchored_select(name.into(), options, value, on_change));
    }
    let labels = options.clone();
    let shown = move || {
        let current = value();
        labels.iter().find(|(v, _)| *v == current).map(|(_, label)| label.clone()).unwrap_or(current)
    };
    let touch = crate::platform::is_phone();
    let select = nsh_base::select()
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
        .trigger(select_trigger(shown));
    view().child(select)
}

fn select_trigger(shown: impl Fn() -> SharedString + 'static) -> View {
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
        .child(text(shown).text_sm().number_of_lines(1).text_color(|| theme().foreground))
        .child(icon(Icon::ChevronDown, Size::Md.icon()))
}

/// The tablet select: its list in a popover below the trigger, as wide as it, instead of a sheet across the
/// bottom of the screen.
fn anchored_select(
    name: SharedString,
    options: Vec<(SharedString, SharedString)>,
    value: impl Fn() -> SharedString + Copy + 'static,
    on_change: impl Fn(SharedString) + 'static,
) -> AnyElement {
    let open = signal(false);
    let width = signal(None::<Points>);
    let options = std::rc::Rc::new(options);
    let on_change = std::rc::Rc::new(on_change);
    let shown = {
        let options = options.clone();
        move || {
            let current = value();
            options.iter().find(|(v, _)| *v == current).map(|(_, label)| label.clone()).unwrap_or(current)
        }
    };
    let trigger = nsh_base::button()
        .accessibility_label(name)
        .on_layout(move |frame: &Bounds<Points>| width.set(Some(frame.size.width)))
        .child(select_trigger(shown));
    nsh_base::popover()
        .open(move || Some(open.get()))
        .on_open_change(move |event: &nsh_base::PopoverEvent| {
            if let nsh_base::PopoverEvent::OpenChange(next, _) = event {
                open.set(*next);
            }
        })
        .align(Align::Start)
        .offset(px(4.0))
        .margin(px(8.0))
        .popup_style(|s| tokens::popup_surface(s).p_1())
        .popup_starting_class(tokens::POPUP_STARTING)
        .popup_ending_class(tokens::POPUP_ENDING)
        .trigger(trigger)
        .child(dynamic(move || {
            let rows = options.iter().cloned().map(|(choice, label)| {
                let on_change = on_change.clone();
                let picked = {
                    let choice = choice.clone();
                    move || value() == choice
                };
                nsh_base::button()
                    .on_press(move || {
                        open.set(false);
                        if untracked(value) != choice {
                            on_change(choice.clone());
                        }
                    })
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_3()
                    .min_h(px(44.0))
                    .rounded(tokens::radius_sm)
                    .text_color(|| theme().popover_foreground)
                    .hover(|s| s.bg(|| theme().accent))
                    .active(|s| s.bg(|| theme().input))
                    .child(text(label).text_base().flex_1().number_of_lines(1))
                    .child(view().size(px(18.0)).child(when(picked, || icon(Icon::Check, 18.0))))
                    .into_element()
            });
            scroll()
                // The popup's padding and border go around the rows: the list lines up with the trigger's edges.
                .w(move || Length::from(width.get().map_or(px(240.0), |width| width - px(10.0))))
                .max_h(px(320.0))
                .child(view().children(rows.collect::<Vec<_>>()))
                .into_element()
        }))
        .into_element()
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
        .track_style(move |s| s.h(px(4.0)).rounded_full().bg(track))
        .indicator_style(|s| s.h(px(4.0)))
        .range_style(move |s| s.h(px(4.0)).rounded_full().bg(fill))
        .thumb_style(move |s| s.size(px(12.0)).rounded_full().bg(fill).shadow_sm().transition_transform())
}

/// A range picked along a track with a handle at each end, from 0 to
/// `max`: where a recording starts and ends. Each handle moves by `step`
/// from the keyboard.
pub fn range_slider(
    name: impl Into<SharedString>,
    value: impl Fn() -> (f64, f64) + 'static,
    max: impl Fn() -> f64 + 'static,
    step: f64,
    on_change: impl Fn(f64, f64) + 'static,
) -> nsh_base::SliderElement {
    nsh_base::slider()
        .value(move || {
            let (start, end) = value();
            Some(SliderValue::Range(start, end))
        })
        .min(0.0)
        .max(move || max().max(step))
        .step(step)
        .on_change(move |value: &SliderValue| on_change(value.start(), value.end()))
        .accessibility_label(name.into())
        .h(px(24.0))
        .justify_center()
        .track_style(|s| s.h(px(4.0)).rounded_full().bg(|| color(theme().input)))
        .indicator_style(|s| s.h(px(4.0)))
        .range_style(|s| s.h(px(4.0)).rounded_full().bg(|| color(theme().primary)))
        .thumb_style(|s| s.w(px(8.0)).h(px(20.0)).rounded_full().bg(|| color(theme().primary)).shadow_sm())
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
