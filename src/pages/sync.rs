//! Syncing the Library with another device on the local network: the
//! dialog this device starts a sync from, and the question it asks when
//! another device wants one.

use listenook_core::format::bytes;
use nsh_base::theme;
use nsh_core::prelude::*;

use crate::{
    services::sync::Peer,
    state::{
        error_text, l, store,
        sync::{Phase, counts},
        tr,
    },
    ui::{
        Icon, Size, Variant, bound_field, button, field, hint, icon, icon_button, modal, modal_actions, progress_bar,
        separator, spinner, switch, text_field_with, tokens,
    },
};

/// What a phase shows: the dialog is built again only when this changes,
/// not with every byte copied.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Choosing,
    Asking,
    Running,
    Done,
    Failed,
}

fn step_of(phase: &Phase) -> Step {
    match phase {
        Phase::Choosing => Step::Choosing,
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

/// The Sync dialog. Placed once, in the shell.
pub(crate) fn sync_dialog() -> impl IntoElement {
    let store = store();
    let sync = store.sync;
    let step = computed(move || step_of(&sync.phase()));
    let address = signal(String::new());
    // Put away while a sync runs, it goes on: the toast tells its end.
    modal(
        sync.open,
        l("Sync with another device"),
        460.0,
        move || {
            dynamic(move || {
                let step = step.get();
                untracked(|| match step {
                    Step::Choosing => choosing(address).into_element(),
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
                    Step::Asking | Step::Running => {
                        button(Variant::Outline, Size::Md, l("Cancel")).on_press(move || sync.cancel()).into_element()
                    }
                    Step::Done => button(Variant::Primary, Size::Md, l("Done"))
                        .on_press(move || sync.open.set(false))
                        .into_element(),
                    Step::Failed => modal_actions(sync.open, l("Close"), l("Try again"), || true, move || sync.again()),
                })
            })
            .into_element()
        },
    )
}

/// Choosing a device: whether this one can be found, those found, and an
/// address for one that was not.
fn choosing(address: Signal<String>) -> impl IntoElement {
    let store = store();
    let sync = store.sync;
    let connect = move || sync.connect(address.get_untracked());
    view()
        .gap_4()
        .child(hint(l(
            "Both Libraries end up with every recording, transcript, group and tag. Where both have a recording, the one edited last is kept. Nothing is deleted.",
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
                            text(l("Nearby devices"))
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(|| theme().foreground)
                                .role(AccessibilityRole::Header),
                        )
                        .child(icon_button(Icon::Refresh, tr("Look again"), Size::Sm, move || sync.search())),
                )
                .child(
                    when(
                        move || sync.peers().is_empty(),
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
                            move || sync.peers(),
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

/// A device found: what it is, and the button that syncs with it.
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
        .child(button(Variant::Primary, Size::Sm, l("Sync")).on_press(move || sync.start(peer.get_untracked())))
}

/// Waiting for the other device's answer, then copying.
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
            // By bytes where media is copied, which is where the time goes.
            Some(if copied.bytes_total > 0 {
                (copied.bytes as f32 / copied.bytes_total as f32).min(1.0)
            } else {
                copied.items as f32 / copied.items_total.max(1) as f32
            })
        }))
        .child(hint(move || {
            if asking() {
                return tr("Accept the sync on the other device.");
            }
            let copied = sync.copied();
            if copied.waiting {
                return tr("Connection lost. Reconnecting…");
            }
            // The other device drives the sync it asked for, and an older
            // Listenook does not say how much there is: what went, then.
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

/// How the sync ended.
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

/// `text` with its first letter a capital.
fn sentence(text: &str) -> String {
    let mut letters = text.chars();
    match letters.next() {
        Some(first) => first.to_uppercase().chain(letters).collect(),
        None => String::new(),
    }
}

/// Asks whether to accept another device's sync. Placed once, in the
/// shell. Put away any other way, the answer is no.
pub(crate) fn sync_request_dialog() -> impl IntoElement {
    let sync = store().sync;
    let open = signal(false);
    effect(move || {
        let asked = sync.request().is_some();
        untracked(|| open.set(asked));
    });
    effect(move || {
        if !open.get() && untracked(|| sync.request().is_some()) {
            sync.answer(false);
        }
    });
    modal(
        open,
        l("Sync request"),
        420.0,
        move || {
            let name = sync.request().map(|(_, device)| device.name).unwrap_or_default();
            view()
                .gap_2()
                .child(
                    text(SharedString::from(format!("“{name}” {}", tr("wants to sync its Library with this one."))))
                        .text_sm()
                        .text_color(|| theme().foreground),
                )
                .child(hint(l(
                    "Both Libraries end up with every recording, transcript, group and tag. Where both have a recording, the one edited last is kept. Nothing is deleted.",
                )))
                .into_element()
        },
        move || modal_actions(open, l("Decline"), l("Accept"), || true, move || sync.answer(true)),
    )
}
