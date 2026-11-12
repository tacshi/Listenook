//! Surfaces over the page: menus, dialogs, confirmations and toasts.

use std::time::Duration;

use nsh_base::{
    Anchor, MenuElement, ToastManager, ToastMotion, ToastOptions, ToastStackState, alert_dialog, dialog, menu_item,
    menu_separator, theme, toast as base_toast, toast_stack,
};
use nsh_core::{prelude::*, time::now};

use super::{
    button::{Size, Variant, button, icon_button},
    icons::{Icon, icon},
    tokens::{self, motion},
};

/// Whether menus open beside their button on this device: on a tablet,
/// in a window wide enough for it. NSH's own menu is a sheet at the bottom
/// of the screen on every touch device, which on a tablet is far from
/// the button that asked for it; a phone, and a narrow window, keep that.
fn anchored() -> bool {
    crate::platform::is_phone() && !untracked(crate::platform::compact)
}

thread_local! {
    /// Counts the commands chosen in menus that open beside their button:
    /// each such menu closes when it changes.
    static CHOSEN: Signal<u64> = signal(0);
}

/// A menu opening from `trigger`. Its children are [`menu_action`]s and
/// [`menu_divider`]s.
pub enum Menu {
    /// NSH's menu: a popup on a computer, a sheet on a phone.
    Native(MenuElement),
    /// A panel beside the trigger, on a tablet.
    Anchored(nsh_base::PopoverElement),
}

impl Menu {
    /// Adds an item (or several, or a region of them).
    pub fn child(self, item: impl IntoElements) -> Self {
        match self {
            Menu::Native(menu) => Menu::Native(menu.children(item.into_elements())),
            Menu::Anchored(menu) => Menu::Anchored(menu.children(item.into_elements())),
        }
    }

    /// Adds items.
    pub fn children<E: IntoElement>(self, items: impl IntoIterator<Item = E>) -> Self {
        let items: Vec<AnyElement> = items.into_iter().map(IntoElement::into_element).collect();
        self.child(items)
    }
}

impl IntoElement for Menu {
    fn into_element(self) -> AnyElement {
        match self {
            Menu::Native(menu) => menu.into_element(),
            Menu::Anchored(menu) => menu.into_element(),
        }
    }
}

/// A menu opening from `trigger`. Its children are [`menu_action`]s and
/// [`menu_divider`]s.
pub fn menu(trigger: impl IntoElement) -> Menu {
    menu_with(signal(false), trigger)
}

/// A [`menu`] whose state is `open`, so its trigger can stay pressed while
/// it shows (see [`super::menu_trigger`]).
pub fn menu_with(open: Signal<bool>, trigger: impl IntoElement) -> Menu {
    if anchored() {
        // A command chosen in it closes it.
        let chosen = CHOSEN.with(|chosen| *chosen);
        let first = std::cell::Cell::new(true);
        effect(move || {
            chosen.get();
            if !first.replace(false) {
                open.set(false);
            }
        });
        return Menu::Anchored(
            nsh_base::popover()
                .open(move || Some(open.get()))
                .on_open_change(move |event: &nsh_base::PopoverEvent| {
                    if let nsh_base::PopoverEvent::OpenChange(next, _) = event {
                        open.set(*next);
                    }
                })
                .offset(px(6.0))
                .margin(px(8.0))
                .popup_style(|s| tokens::popup_surface(s).min_w(px(240.0)).p_2())
                .popup_starting_class(tokens::POPUP_STARTING)
                .popup_ending_class(tokens::POPUP_ENDING)
                .trigger(trigger),
        );
    }
    Menu::Native(
        nsh_base::menu()
            .open(move || Some(open.get()))
            .on_open_change(move |event: &nsh_base::MenuEvent| {
                if let nsh_base::MenuEvent::OpenChange(next, _) = event {
                    open.set(*next);
                }
            })
            .offset(px(4.0))
            .margin(px(8.0))
            .popup_style(tokens::menu_surface)
            .popup_starting_class(tokens::POPUP_STARTING)
            .popup_ending_class(tokens::POPUP_ENDING)
            .backdrop_style(|s| s.bg(tokens::scrim))
            .trigger(trigger),
    )
}

/// The menu of what is under the pointer: a secondary click on `target`
/// opens it there (Shift+F10 or the Menu key from the keyboard). Its
/// children are [`menu_action`]s and [`menu_divider`]s; it is for a
/// computer, where they are NSH's menu items.
pub fn context_menu(target: impl IntoElement) -> nsh_base::ContextMenuElement {
    nsh_base::context_menu()
        .offset(px(4.0))
        .margin(px(8.0))
        .popup_style(tokens::popup_surface)
        .popup_starting_class(tokens::POPUP_STARTING)
        .popup_ending_class(tokens::POPUP_ENDING)
        .trigger(target)
}

/// A panel of controls opening from `trigger`, without leaving the page.
pub fn popover(trigger: impl IntoElement, content: impl Fn() -> AnyElement + 'static) -> nsh_base::PopoverElement {
    nsh_base::popover()
        .offset(px(6.0))
        .margin(px(8.0))
        .popup_style(|s| tokens::popup_surface(s).w(px(340.0)).p_4())
        .popup_starting_class(tokens::POPUP_STARTING)
        .popup_ending_class(tokens::POPUP_ENDING)
        .trigger(trigger)
        .child(dynamic(content))
}

/// A row of a menu: an icon or a check mark, and a label. In NSH's menu
/// it is a menu item; beside the trigger on a tablet, a button that
/// closes the panel once it has done its work (`stays`: unless it is a
/// setting, toggled with the menu left open).
fn menu_row(
    mark: AnyElement,
    label: impl IntoReactive<SharedString>,
    danger: bool,
    stays: bool,
    checked: Option<Box<dyn Fn() -> bool>>,
    on_select: impl Fn() + 'static,
) -> AnyElement {
    let touch = crate::platform::is_phone();
    let ink = move || if danger { theme().destructive } else { theme().popover_foreground };
    let label = {
        let label = text(label).flex_1();
        if touch { label.text_base() } else { label.text_sm() }
    };
    let mark = view().size(px(if touch { 18.0 } else { 14.0 })).child(mark);
    if anchored() {
        return nsh_base::button()
            .on_press(move || {
                on_select();
                if !stays {
                    CHOSEN.with(|chosen| chosen.update(|count| *count += 1));
                }
            })
            .flex_row()
            .items_center()
            .gap_3()
            .px_3()
            .min_h(px(44.0))
            .rounded(tokens::radius_sm)
            .text_color(ink)
            .hover(|s| s.bg(|| theme().accent))
            .active(|s| s.bg(|| theme().input))
            .focus_visible(tokens::focus_ring)
            .child(mark)
            .child(label)
            .into_element();
    }
    let row = menu_item().close_on_select(!stays).on_select(on_select);
    let row = match checked {
        Some(checked) => row.checked(move || Some(checked())),
        None => row,
    };
    // A pointer's size on a computer, a finger's on a phone (44 points,
    // the smallest a finger hits surely).
    let row = if touch { row.gap_3().px_3().min_h(px(44.0)) } else { row.gap_2().px_2().py_1p5() };
    row.flex_row()
        .items_center()
        .rounded(tokens::radius_sm)
        .text_color(ink)
        .hover(|s| s.bg(|| theme().accent))
        .focus(|s| s.bg(|| theme().accent))
        .active(|s| s.bg(|| theme().input))
        .disabled_style(|s| s.opacity(0.45))
        .child(mark)
        .child(label)
        .into_element()
}

fn mark_size() -> f32 {
    if crate::platform::is_phone() { 18.0 } else { 14.0 }
}

/// A command of a menu.
pub fn menu_action(glyph: Icon, label: impl IntoReactive<SharedString>, on_select: impl Fn() + 'static) -> AnyElement {
    menu_row(icon(glyph, mark_size()).into_element(), label, false, false, None, on_select)
}

/// A destructive command of a menu, set apart by its color.
pub fn menu_danger(glyph: Icon, label: impl IntoReactive<SharedString>, on_select: impl Fn() + 'static) -> AnyElement {
    menu_row(icon(glyph, mark_size()).into_element(), label, true, false, None, on_select)
}

/// A setting toggled from a menu; the menu stays open.
pub fn menu_toggle(
    label: impl IntoReactive<SharedString>,
    checked: impl Fn() -> bool + Copy + 'static,
    on_select: impl Fn() + 'static,
) -> AnyElement {
    let size = mark_size();
    let mark = when(checked, move || icon(Icon::Check, size)).into_element();
    menu_row(mark, label, false, true, Some(Box::new(checked)), on_select)
}

/// One of several choices in a menu, the chosen one checked; choosing
/// closes the menu.
pub fn menu_choice(
    label: impl IntoReactive<SharedString>,
    checked: impl Fn() -> bool + Copy + 'static,
    on_select: impl Fn() + 'static,
) -> AnyElement {
    let size = mark_size();
    let mark = when(checked, move || icon(Icon::Check, size)).into_element();
    menu_row(mark, label, false, false, Some(Box::new(checked)), on_select)
}

/// The line between groups of a menu.
pub fn menu_divider() -> AnyElement {
    if anchored() {
        return view().h(px(1.0)).my_1().bg(|| theme().border).into_element();
    }
    menu_separator().h(px(1.0)).my_1().bg(|| theme().border).into_element()
}

/// A dialog centered in the window: a title, the content and a row of
/// actions. Escape and a press on the backdrop close it.
pub fn modal(
    open: Signal<bool>,
    title: impl Fn() -> SharedString + Copy + 'static,
    width: f32,
    content: impl Fn() -> AnyElement + 'static,
    actions: impl Fn() -> AnyElement + 'static,
) -> impl IntoElement {
    modal_sized(open, title, width, None, content, actions)
}

/// A [`modal`] that keeps one height whatever it shows (as far as the
/// window allows), for a dialog whose content changes, such as tabs:
/// its parts stay where they are.
pub fn modal_sized(
    open: Signal<bool>,
    title: impl Fn() -> SharedString + Copy + 'static,
    width: f32,
    height: Option<f32>,
    content: impl Fn() -> AnyElement + 'static,
    actions: impl Fn() -> AnyElement + 'static,
) -> AnyElement {
    // A tall dialog is the system's sheet on an iPhone or an iPad: it
    // comes up from the bottom and is swiped down to put away.
    if cfg!(target_os = "ios") && height.is_some() {
        return when(open, move || {
            dialog()
                .presentation(if crate::platform::compact() {
                    nsh_core::ModalPresentation::PageSheet
                } else {
                    nsh_core::ModalPresentation::FormSheet
                })
                .on_cancel(move || open.set(false))
                .flex_1()
                .bg(|| theme().card)
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .ps_5()
                        .pe_3()
                        .pt_4()
                        .child(
                            text(title)
                                .text_base()
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(|| theme().card_foreground)
                                .role(AccessibilityRole::Header),
                        )
                        .child(icon_button(Icon::Close, crate::state::tr("Close"), Size::Md, move || open.set(false))),
                )
                .child(scroll().flex_1().child(view().px_5().py_4().gap_4().child(content())))
                .child(
                    view()
                        .flex_row()
                        .justify_end()
                        .gap_2()
                        .px_5()
                        .pt_3()
                        .pb_safe_area_plus(px(12.0))
                        .border_t_1()
                        .border_color(|| theme().border)
                        .child(actions()),
                )
        })
        .into_element();
    }
    when(open, move || {
        // The dialog fades in whole, backdrop and card together (left to
        // itself it slides up from the bottom, backdrop and all), and the
        // card rises a little into place as it does.
        let card = motion().entering(MotionPreset::FadeInUp);
        dialog()
            .animation(nsh_core::ModalAnimation::Fade)
            .on_cancel(move || open.set(false))
            .flex_1()
            .items_center()
            .justify_center()
            .style_with(|s| if window().width.0 < 700.0 { s.p_3() } else { s.p_6() })
            .bg(tokens::scrim)
            .child(
                view()
                    .bind_motion(&card)
                    .w(move || px(width.min(window().width.0 - 24.0)))
                    .max_w(relative(1.0))
                    .max_h(relative(1.0))
                    .style_with(move |s| match height {
                        Some(height) => s.h(move || px(height.min(window().height.0 - 48.0))),
                        None => s,
                    })
                    .rounded(tokens::radius_lg)
                    .border_1()
                    .border_color(|| theme().border)
                    .bg(|| theme().card)
                    .shadow_xl()
                    .overflow_hidden()
                    .child(
                        view()
                            .flex_row()
                            .items_center()
                            .justify_between()
                            .ps_5()
                            .pe_3()
                            .pt_3()
                            .child(
                                text(title)
                                    .text_base()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(|| theme().card_foreground)
                                    .role(AccessibilityRole::Header),
                            )
                            .child(icon_button(Icon::Close, crate::state::tr("Close"), Size::Sm, move || {
                                open.set(false)
                            })),
                    )
                    .child(
                        scroll()
                            .flex_grow(if height.is_some() { 1.0 } else { 0.0 })
                            .flex_shrink(1.0)
                            .child(view().px_5().py_4().gap_4().child(content())),
                    )
                    .child(
                        view()
                            .flex_row()
                            .justify_end()
                            .gap_2()
                            .px_5()
                            .py_3()
                            .border_t_1()
                            .border_color(|| theme().border)
                            .child(actions()),
                    ),
            )
    })
    .into_element()
}

/// The Cancel and commit buttons of a dialog.
pub fn modal_actions(
    open: Signal<bool>,
    cancel: impl IntoReactive<SharedString>,
    commit: impl IntoReactive<SharedString>,
    enabled: impl Fn() -> bool + 'static,
    on_commit: impl Fn() + 'static,
) -> AnyElement {
    view()
        .flex_row()
        .gap_2()
        .child(button(Variant::Outline, Size::Md, cancel).on_press(move || open.set(false)))
        .child(button(Variant::Primary, Size::Md, commit).disabled(move || !enabled()).on_press(on_commit))
        .into_element()
}

/// Asks before something that cannot be undone, with the system's alert.
/// `on_confirm` runs only for the destructive answer.
pub fn confirm_destructive(
    title: impl Into<SharedString>,
    description: impl Into<SharedString>,
    cancel: impl Into<SharedString>,
    confirm: impl Into<SharedString>,
    on_confirm: impl FnOnce() + 'static,
) {
    let answer = alert_dialog()
        .title(title.into())
        .description(description.into())
        .cancel("cancel", cancel.into())
        .destructive("confirm", confirm.into())
        .show();
    spawn(async move {
        if answer.await.is_ok_and(|answer| answer.action.as_deref() == Some("confirm")) {
            on_confirm();
        }
    });
}

/// How a toast reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Info,
    Success,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
struct ToastData {
    tone: Tone,
    text: SharedString,
}

#[derive(Clone, Default)]
struct Pending {
    next_id: u64,
    waiting: Vec<(u64, ToastData)>,
}

/// Shows a short message at the bottom of the window. For results that are
/// not already visible where they happened.
pub fn toast(tone: Tone, text: impl Into<SharedString>) {
    let text = text.into();
    global::<Pending>().update(|pending| {
        pending.next_id += 1;
        pending.waiting.push((pending.next_id, ToastData { tone, text }));
    });
}

/// The stack toasts appear in: placed once, at the app's root.
pub fn toast_host() -> impl IntoElement {
    let manager = stored(ToastManager::<u64, ToastData>::new(ToastMotion::sonner()));
    let shown = signal(Vec::new());
    let state = ToastStackState::new();
    let sync = move || {
        shown.set(
            manager.with(|m| m.visible(3).map(|(id, data, status)| (*id, data.clone(), status)).collect::<Vec<_>>()),
        )
    };
    effect(move || {
        let waiting = global::<Pending>().with(|pending| pending.waiting.clone());
        if waiting.is_empty() {
            return;
        }
        untracked(|| {
            global::<Pending>().update(|pending| pending.waiting.clear());
            for (id, data) in waiting {
                let seconds = if data.tone == Tone::Error { 7 } else { 4 };
                manager.with(|m| m.push(id, data, ToastOptions::timeout(Some(Duration::from_secs(seconds))), now()));
            }
            sync();
        });
    });
    set_interval(Duration::from_millis(100), move || {
        if manager.with(|m| !m.is_empty() && m.advance(now(), state.is_expanded()).changed) {
            sync();
        }
    });
    toast_stack()
        .placement(Anchor::BottomCenter)
        .state(state)
        .w(px(360.0))
        // Clear of the system's tab bar on a phone.
        .style_with(|s| if crate::platform::is_phone() && crate::platform::compact() { s.mb(px(72.0)) } else { s })
        .child(each(
            shown,
            |(id, _, _)| *id,
            move |item, _| {
                let data = item.get_untracked().1;
                let id = item.get_untracked().0;
                let tone = data.tone;
                base_toast()
                    .transition_status(move || item.get().2)
                    .accessibility_label(data.text.clone())
                    .on_dismiss_request(move || {
                        manager.with(|m| m.dismiss(&id, now()));
                    })
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_4()
                    .py_3()
                    .rounded(tokens::radius_lg)
                    .border_1()
                    .border_color(|| theme().border)
                    .bg(|| theme().popover)
                    .shadow_lg()
                    .transition_all()
                    .duration(motion::BASE)
                    .starting_class("opacity-0 translate-y-4")
                    .ending_class("opacity-0 scale-95")
                    .child(
                        view()
                            .text_color(move || match tone {
                                Tone::Info => theme().muted_foreground,
                                Tone::Success => tokens::success(),
                                Tone::Error => theme().destructive,
                            })
                            .child(icon(
                                match tone {
                                    Tone::Info => Icon::Info,
                                    Tone::Success => Icon::Check,
                                    Tone::Error => Icon::Alert,
                                },
                                16.0,
                            )),
                    )
                    .child(text(data.text).text_sm().flex_1().text_color(|| theme().popover_foreground))
            },
        ))
}
