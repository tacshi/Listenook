//! What every page has around its content: the bar along its top, how wide it is and when it
//! stacks, and the controls the players share.

use listenook_core::{format, sleep::Sleep};
use nsh_base::theme;
use nsh_core::{element::desktop::title_bar, prelude::*};

use crate::{
    platform,
    state::{
        podcast::{RATES, rate_label},
        store,
    },
    ui::{self, Icon, IconButton, Size, Variant, l, menu, tr},
};

/// The height of the bar along the top of the window and of each page.
pub(crate) const BAR: f32 = 44.0;
pub(crate) const CONTROLS_GAP: f32 = 12.0;

pub(crate) fn system_header() -> bool {
    platform::is_phone()
}

pub(crate) fn sidebar_width() -> f32 {
    if platform::is_phone() { 288.0 } else { 216.0 }
}

pub(crate) fn page_narrow() -> bool {
    page_width() < 700.0
}

pub(crate) fn page_stacks() -> bool {
    page_narrow() || (platform::is_phone() && window().height.0 > window().width.0)
}

pub(crate) fn page_width() -> f32 {
    let store = store();
    let beside = if platform::compact() || store.sidebar_hidden() || store.immersive() { 0.0 } else { sidebar_width() };
    window().width.0 - beside
}

pub(crate) fn time_text(ms: impl Fn() -> i64 + 'static) -> Text {
    text(move || format::shown(format::Shown::Clock(ms())))
        .text_xs()
        .tabular_nums()
        .text_color(|| theme().muted_foreground)
}

pub(crate) fn rate_menu(
    variant: Variant,
    rate: impl Fn() -> f32 + Copy + 'static,
    set: impl Fn(f32) + Copy + 'static,
) -> impl IntoElement {
    menu(ui::menu_button(variant, Size::Sm, tr("Playback speed"), move || rate_label(rate()))).children(
        RATES.iter().map(move |option| {
            let option = *option;
            ui::MenuChoice {
                label: rate_label(option),
                checked: move || (rate() - option).abs() < 0.001,
                on_select: move || set(option),
            }
        }),
    )
}

const SLEEP_AFTER: &[(i64, &str)] =
    &[(5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes"), (45, "45 minutes"), (60, "1 hour")];

/// The sleep timer's button, showing the time left while it counts (in place
/// of the moon on a narrow page), and its choices; `end` names stopping when
/// what plays ends.
pub(crate) fn sleep_menu(variant: Variant, end: &'static str) -> impl IntoElement {
    let sleep = crate::state::sleep::SleepState::get();
    let left = move || sleep.timer().countdown().map(SharedString::from);
    let on = move || sleep.timer().is_on();
    let trigger = ui::menu_glyph_label_button(variant, Size::Sm, tr("Sleep timer"), Icon::Sleep, left, on, page_narrow);
    menu(trigger)
        .child(ui::MenuChoice {
            label: l("Off"),
            checked: move || !sleep.timer().is_on(),
            on_select: move || sleep.act(crate::state::sleep::SleepAction::Set(Sleep::Off)),
        })
        .children(SLEEP_AFTER.iter().map(move |&(minutes, label)| ui::MenuChoice {
            label: l(label),
            checked: move || sleep.timer().minutes_chosen() == Some(minutes),
            on_select: move || sleep.act(crate::state::sleep::SleepAction::Set(Sleep::minutes(minutes))),
        }))
        .child(ui::MenuChoice {
            label: l(end),
            checked: move || sleep.timer() == Sleep::AtEnd,
            on_select: move || sleep.act(crate::state::sleep::SleepAction::Set(Sleep::AtEnd)),
        })
}

pub(crate) fn top_bar() -> View {
    let store = store();
    if system_header() {
        return view().flex_shrink_0().flex_row().items_center().gap_2().px(px(ui::PAGE_INSET)).py_2();
    }
    let alone = move || (store.sidebar_hidden() || platform::compact()) && !store.immersive();
    view()
        .h(px(BAR))
        .flex_shrink_0()
        .flex_row()
        .items_center()
        .gap_2()
        .style_with(move |s| {
            let controls = title_bar();
            let left = if alone() && controls.left.0 > 0.0 { controls.left.0 + CONTROLS_GAP } else { ui::PAGE_INSET };
            let right = if controls.right.0 > 0.0 { controls.right.0 + CONTROLS_GAP } else { ui::PAGE_INSET };
            s.pl(px(left)).pr(px(right))
        })
        .child(when(alone, move || {
            view().window_drag(false).child(IconButton {
                glyph: Icon::Sidebar,
                name: tr("Show sidebar"),
                size: Size::Sm,
                on_press: move || store.act(crate::state::Action::ToggleSidebar),
            })
        }))
        .border_b_1()
        .border_color(|| theme().border)
        .window_drag(true)
}
