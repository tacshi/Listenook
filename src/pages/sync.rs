use listenook_core::format::{bytes, date, minutes_since};
use nsh_base::theme;
use nsh_core::prelude::*;

use crate::{
    services::sync::{Mate, Peer},
    state::{
        error_text, l, store,
        sync::{Phase, counts},
        tr,
    },
    ui::{
        Icon, Size, Variant, bound_field, button, confirm_destructive, field, hint, icon, icon_button, modal,
        progress_bar, separator, spinner, switch, text_field_with, tokens,
    },
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Choosing,
    Pairing,
    Asking,
    Running,
    Done,
    Failed,
}

fn step_of(phase: &Phase) -> Step {
    match phase {
        Phase::Choosing => Step::Choosing,
        Phase::Pairing(_) => Step::Pairing,
        Phase::Asking(_) => Step::Asking,
        Phase::Running(_) | Phase::Serving(_) => Step::Running,
        Phase::Done(..) => Step::Done,
        Phase::Failed(_) => Step::Failed,
    }
}

fn platform_name(platform: &str) -> &'static str {
    match platform {
        "macos" => "Mac",
        "ios" => "iPhone / iPad",
        "android" => "Android",
        "windows" => "Windows",
        "linux" => "Linux",
        _ => "",
    }
}

fn synced_words(at: Option<&str>) -> String {
    let Some(at) = at else {
        return tr("Not synced yet").to_string();
    };
    match minutes_since(at) {
        Some(0) => tr("Synced just now").to_string(),
        Some(minutes) if minutes < 60 => format!("{} {minutes} {}", tr("Last synced"), tr("min ago")),
        Some(minutes) if minutes < 24 * 60 => format!("{} {} {}", tr("Last synced"), minutes / 60, tr("h ago")),
        _ => format!("{} {}", tr("Last synced"), date(at)),
    }
}

pub(crate) fn sync_dialog() -> impl IntoElement {
    let store = store();
    let sync = store.sync;
    let step = computed(move || step_of(&sync.phase()));
    let address = signal(String::new());
    let code = signal(String::new());
    let enter = move || sync.enter(code.get_untracked());
    effect(move || {
        let (pairing, wrong) = (step.get() == Step::Pairing, sync.wrong());
        if pairing || wrong {
            untracked(|| code.set(String::new()));
        }
    });
    modal(
        sync.open,
        l("Sync with your devices"),
        460.0,
        move || {
            dynamic(move || {
                let step = step.get();
                untracked(|| match step {
                    Step::Choosing => choosing(address).into_element(),
                    Step::Pairing => pairing(code, enter).into_element(),
                    Step::Asking | Step::Running => running().into_element(),
                    Step::Done | Step::Failed => ended().into_element(),
                })
            })
            .into_element()
        },
        move || {
            dynamic(move || {
                let step = step.get();
                untracked(|| match step {
                    Step::Choosing => button(Variant::Default, Size::Md, l("Close"))
                        .on_press(move || sync.open.set(false))
                        .into_element(),
                    Step::Pairing => view()
                        .flex_row()
                        .gap_2()
                        .child(button(Variant::Outline, Size::Md, l("Cancel")).on_press(move || sync.cancel()))
                        .child(
                            button(Variant::Primary, Size::Md, l("Pair"))
                                .disabled(move || {
                                    sync.checking()
                                        || code.with(|code| code.chars().filter(char::is_ascii_digit).count() != 6)
                                })
                                .on_press(enter),
                        )
                        .into_element(),
                    Step::Asking | Step::Running => {
                        button(Variant::Outline, Size::Md, l("Cancel")).on_press(move || sync.cancel()).into_element()
                    }
                    Step::Done => button(Variant::Primary, Size::Md, l("Done"))
                        .on_press(move || sync.open.set(false))
                        .into_element(),
                    Step::Failed => view()
                        .flex_row()
                        .gap_2()
                        .child(button(Variant::Outline, Size::Md, l("Close")).on_press(move || sync.open.set(false)))
                        .child(button(Variant::Primary, Size::Md, l("Try again")).on_press(move || sync.again()))
                        .into_element(),
                })
            })
            .into_element()
        },
    )
}

fn heading(label: &'static str) -> impl IntoElement {
    text(l(label))
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(|| theme().foreground)
        .role(AccessibilityRole::Header)
}

fn choosing(address: Signal<String>) -> impl IntoElement {
    let store = store();
    let sync = store.sync;
    let connect = move || sync.connect(address.get_untracked());
    let paired = move || !sync.mates().is_empty();
    view()
        .gap_4()
        .child(hint(l(
            "Pair your devices once with a code. After that they sync on their own whenever they are open on the same network, and every one ends up with every recording, transcript, group and tag, and with the podcasts you follow and where you left each episode. Where two have a recording, the one edited last is kept.",
        )))
        .child(
            view()
                .gap_3()
                .child(switch(
                    l("Visible to devices on this network"),
                    move || store.sync_visible(),
                    move |on| store.set_sync_visible(on),
                ))
                .child(when(
                    move || store.sync_visible(),
                    move || {
                        field(
                            l("This device’s name"),
                            bound_field(
                                move || store.device_name(),
                                move |name| store.set_device_name(&name),
                                SharedString::default,
                            ),
                        )
                    },
                )),
        )
        .child(when(paired, move || {
            view()
                .gap_2()
                .child(separator())
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .child(heading("My devices"))
                        .child(
                            button(Variant::Default, Size::Sm, l("Sync now"))
                                .disabled(move || sync.rounding() || !store.sync_visible())
                                .on_press(move || sync.sync_now()),
                        ),
                )
                .child(view().gap_1().child(each(move || sync.mates(), |mate| mate.id.clone(), move |mate, _| mate_row(mate))))
        }))
        .child(separator())
        .child(
            view()
                .gap_2()
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .child(
                            dynamic(move || {
                                if paired() { heading("Add a device") } else { heading("Nearby devices") }.into_element()
                            }),
                        )
                        .child(icon_button(Icon::Refresh, tr("Look again"), Size::Sm, move || sync.search())),
                )
                .child(
                    when(
                        move || sync.strangers().is_empty(),
                        || {
                            view()
                                .flex_row()
                                .items_center()
                                .gap_3()
                                .py_2()
                                .child(spinner(14.0))
                                .child(hint(l("Looking… Open Sync in Listenook on the other device too.")).flex_1())
                        },
                    )
                    .otherwise(move || {
                        view().gap_1().child(each(
                            move || sync.strangers(),
                            |peer| peer.device.id.clone(),
                            move |peer, _| device_row(peer),
                        ))
                    }),
                ),
        )
        .child(field(
            l("Or connect by address"),
            view()
                .flex_row()
                .gap_2()
                .child(
                    text_field_with(address, l("IP address, such as 192.168.1.20"), move |input| {
                        input.auto_capitalize(AutoCapitalize::None).auto_correct(false).on_submit(move |_: &str| connect())
                    })
                    .flex_1(),
                )
                .child(
                    button(Variant::Default, Size::Md, l("Connect"))
                        .disabled(move || sync.connecting() || address.with(|a| a.trim().is_empty()))
                        .on_press(connect),
                ),
        ))
}

pub(crate) fn mate_row(mate: ReadSignal<Mate>) -> impl IntoElement {
    let sync = store().sync;
    let entrance = motion().entering(MotionPreset::FadeInUp);
    let remove = move || {
        let (id, name) = mate.with_untracked(|mate| (mate.id.clone(), mate.name.clone()));
        confirm_destructive(
            format!("{} “{name}”?", tr("Unpair")),
            tr("It stops syncing with your devices. Pair it again to bring it back."),
            tr("Cancel"),
            tr("Unpair"),
            move || sync.remove(&id),
        );
    };
    view()
        .bind_motion(&entrance)
        .flex_row()
        .items_center()
        .gap_3()
        .py_1p5()
        .child(view().text_color(|| theme().muted_foreground).child(icon(Icon::Devices, 18.0)))
        .child(
            view()
                .flex_1()
                .min_w(px(0.0))
                .child(
                    text(move || SharedString::from(mate.with(|mate| mate.name.clone())))
                        .text_sm()
                        .number_of_lines(1)
                        .text_color(|| theme().foreground),
                )
                .child(
                    hint(move || {
                        mate.with(|mate| {
                            let mut line = format!(
                                "{} · {}",
                                platform_name(&mate.platform),
                                synced_words(mate.synced_at.as_deref())
                            );
                            if mate.nearby.is_some() {
                                line.push_str(&format!(" · {}", tr("Nearby")));
                            }
                            SharedString::from(line)
                        })
                    })
                    .number_of_lines(1),
                ),
        )
        .child(button(Variant::Ghost, Size::Sm, l("Unpair")).on_press(remove))
}

fn device_row(peer: ReadSignal<Peer>) -> impl IntoElement {
    let sync = store().sync;
    let entrance = motion().entering(MotionPreset::FadeInUp);
    view()
        .bind_motion(&entrance)
        .flex_row()
        .items_center()
        .gap_3()
        .py_1p5()
        .child(view().text_color(|| theme().muted_foreground).child(icon(Icon::Devices, 18.0)))
        .child(
            view()
                .flex_1()
                .min_w(px(0.0))
                .child(
                    text(move || SharedString::from(peer.with(|peer| peer.device.name.clone())))
                        .text_sm()
                        .number_of_lines(1)
                        .text_color(|| theme().foreground),
                )
                .child(
                    hint(move || {
                        peer.with(|peer| {
                            SharedString::from(format!(
                                "{} · {}",
                                platform_name(&peer.device.platform),
                                peer.address.ip()
                            ))
                        })
                    })
                    .number_of_lines(1),
                ),
        )
        .child(button(Variant::Primary, Size::Sm, l("Pair")).on_press(move || sync.start(peer.get_untracked())))
}

fn pairing(code: Signal<String>, enter: impl Fn() + Copy + 'static) -> impl IntoElement {
    let sync = store().sync;
    let name = move || match sync.phase() {
        Phase::Pairing(peer) => peer.device.name,
        _ => String::new(),
    };
    view()
        .gap_3()
        .child(
            text(move || SharedString::from(format!("{} “{}”.", tr("Enter the code shown on"), name())))
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(|| theme().foreground),
        )
        .child(text_field_with(code, l("6-digit code"), move |input| {
            input
                .keyboard_type(KeyboardType::Number)
                .auto_focus(true)
                .auto_correct(false)
                .on_submit(move |_: &str| enter())
        }))
        .child(
            when(
                move || sync.wrong(),
                || {
                    view()
                        .text_color(|| theme().destructive)
                        .child(hint(l("That code is not right. Check it on the other device and try again.")))
                },
            )
            .otherwise(|| {
                hint(l("Once paired, the two devices sync on their own whenever both are open on the same network."))
            }),
        )
}

fn running() -> impl IntoElement {
    let sync = store().sync;
    let name = move || match sync.phase() {
        Phase::Asking(peer) | Phase::Running(peer) => peer.device.name,
        Phase::Serving(name) => name,
        _ => String::new(),
    };
    let asking = move || matches!(sync.phase(), Phase::Asking(_));
    view()
        .gap_3()
        .child(
            text(move || {
                SharedString::from(if asking() {
                    format!("{} {}…", tr("Waiting for"), name())
                } else {
                    format!("{} {}…", tr("Syncing with"), name())
                })
            })
            .text_sm()
            .font_weight(FontWeight::MEDIUM)
            .text_color(|| theme().foreground),
        )
        .child(progress_bar(move || {
            let copied = sync.copied();
            if asking() || (copied.items_total == 0 && copied.bytes_total == 0) {
                return None;
            }
            Some(if copied.bytes_total > 0 {
                (copied.bytes as f32 / copied.bytes_total as f32).min(1.0)
            } else {
                copied.items as f32 / copied.items_total.max(1) as f32
            })
        }))
        .child(hint(move || {
            if asking() {
                return tr("Keep Listenook open on the other device.");
            }
            let copied = sync.copied();
            if copied.waiting {
                return tr("Connection lost. Reconnecting…");
            }
            if copied.items_total == 0 && copied.bytes_total == 0 {
                return SharedString::from(bytes(copied.bytes as i64));
            }
            let mut line = format!("{} / {} {}", copied.items, copied.items_total, tr("recordings"));
            if copied.bytes_total > 0 {
                line.push_str(&format!(" · {} / {}", bytes(copied.bytes as i64), bytes(copied.bytes_total as i64)));
            }
            line.into()
        }))
}

fn ended() -> impl IntoElement {
    let sync = store().sync;
    let failed = move || matches!(sync.phase(), Phase::Failed(_));
    let entrance = motion().entering(MotionPreset::FadeInUp);
    view()
        .bind_motion(&entrance)
        .flex_row()
        .items_start()
        .gap_3()
        .child(
            view()
                .pt(px(2.0))
                .text_color(move || if failed() { theme().destructive } else { tokens::success() })
                .child(when(failed, || icon(Icon::Alert, 16.0)).otherwise(|| icon(Icon::Check, 16.0))),
        )
        .child(
            view()
                .flex_1()
                .gap_1()
                .child(
                    text(move || match sync.phase() {
                        Phase::Done(name, _) => SharedString::from(format!("{} {name}", tr("Synced with"))),
                        Phase::Failed(_) => tr("The sync did not finish"),
                        _ => SharedString::default(),
                    })
                    .text_sm()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(|| theme().foreground),
                )
                .child(hint(move || match sync.phase() {
                    Phase::Done(_, summary) => SharedString::from(sentence(&counts(summary.received, summary.sent))),
                    Phase::Failed(code) => error_text(code),
                    _ => SharedString::default(),
                })),
        )
}

fn sentence(text: &str) -> String {
    let mut letters = text.chars();
    match letters.next() {
        Some(first) => first.to_uppercase().chain(letters).collect(),
        None => String::new(),
    }
}

pub(crate) fn sync_code_dialog() -> impl IntoElement {
    let sync = store().sync;
    let open = signal(false);
    effect(move || {
        let shown = sync.code().is_some();
        untracked(|| open.set(shown));
    });
    effect(move || {
        if !open.get() && untracked(|| sync.code().is_some()) {
            sync.dismiss_code();
        }
    });
    modal(
        open,
        l("Pair a device"),
        420.0,
        move || {
            let (name, code) = sync.code().map(|code| (code.device.name, code.code)).unwrap_or_default();
            let shown = format!("{} {}", code.get(..3).unwrap_or(""), code.get(3..).unwrap_or(""));
            view()
                .gap_3()
                .child(
                    text(SharedString::from(format!(
                        "{} “{name}” {}",
                        tr("Enter this code on"),
                        tr("to pair it with this device.")
                    )))
                    .text_sm()
                    .text_color(|| theme().foreground),
                )
                .child(
                    text(SharedString::from(shown))
                        .text_3xl()
                        .font_weight(FontWeight::BOLD)
                        .tabular_nums()
                        .text_color(|| theme().foreground)
                        .text_center(),
                )
                .child(hint(l(
                    "Once paired, the two devices sync on their own whenever both are open on the same network.",
                )))
                .into_element()
        },
        move || button(Variant::Outline, Size::Md, l("Cancel")).on_press(move || sync.dismiss_code()).into_element(),
    )
}
