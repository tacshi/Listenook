//! Recording what plays: one dialog that follows the recording from start
//! to the Library. It records at once, shows the sound coming in, and once
//! stopped lays the whole recording out to trim: its ends, and the silent
//! gaps, which are cut out unless asked not to.

use std::rc::Rc;

use listenook_core::{
    capture::{self, Span},
    format,
};
use nsh_base::theme;
use nsh_core::prelude::*;

use crate::{
    services::capture::{self as service, Support},
    state::{capture::Phase, error_text, l, store, tr},
    ui::{self, Icon, Size, Variant, button, icon, icon_text_button},
};

/// Whether recording what plays is offered: on a computer that can, or
/// that could with a newer macOS (it then says so).
pub(crate) fn offered() -> bool {
    !crate::platform::is_phone() && service::support() != Support::No
}

fn clock(ms: u64) -> SharedString {
    format::clock(ms as i64).into()
}

/// What the sidebar says beside a recording that waits.
pub(crate) fn status() -> SharedString {
    let capture = store().capture;
    match capture.phase() {
        // Paused, the light beside it turns grey.
        Phase::Recording | Phase::Stopping => clock(capture.elapsed_ms()),
        Phase::Saving => tr("Saving…"),
        _ => tr("Not saved"),
    }
}

/// The top bar's way to add to the Library: a menu of where from (files,
/// or recording what plays) where recording is offered, else a button to
/// choose files. While recording, the recording's light and time stand
/// beside it, and show it.
pub(crate) fn add_button() -> AnyElement {
    if !offered() {
        return ui::icon_button(Icon::Plus, tr("Add media…"), Size::Sm, crate::util::pick_media).into_element();
    }
    let capture = store().capture;
    let open = signal(false);
    view()
        .flex_row()
        .items_center()
        .gap_1()
        .child(when(
            move || capture.recording(),
            move || {
                ui::recording_button(
                    tr("Show the recording"),
                    move || !capture.paused(),
                    move || clock(capture.elapsed_ms()),
                )
                .on_press(move || capture.open.set(true))
            },
        ))
        .child(
            ui::menu_with(open, ui::menu_trigger(Icon::Plus, tr("Add to Library"), Size::Sm, open))
                .child(ui::menu_source(
                    Icon::File,
                    l("Files…"),
                    l("Audio or video on this computer"),
                    "mod+o",
                    crate::util::pick_media,
                ))
                .child(ui::menu_source(
                    Icon::Record,
                    move || tr(if capture.pending() { "Show the recording" } else { "Record what’s playing" }),
                    move || {
                        if capture.pending() {
                            format!("{} · {}", tr("Recording"), status()).into()
                        } else {
                            tr("Sound from a video or app as it plays")
                        }
                    },
                    "mod+shift+r",
                    move || capture.record(),
                )),
        )
        .into_element()
}

pub(crate) fn capture_dialog() -> impl IntoElement {
    let store = store();
    let capture = store.capture;
    let phase = computed(move || capture.phase());
    // Back from System Settings with recording allowed: it starts.
    effect(move || {
        if store.focused() && phase.get() == Phase::Denied {
            untracked(|| capture.retry());
        }
    });
    let title = move || match phase.get() {
        Phase::Trimming | Phase::Saving => tr("Trim recording"),
        _ => tr("Record what’s playing"),
    };
    ui::modal(
        capture.open,
        title,
        600.0,
        move || {
            dynamic(move || {
                let shown = phase.get();
                untracked(|| match shown {
                    Phase::Idle if problem().is_some() => failed().into_element(),
                    Phase::Idle | Phase::Starting => starting().into_element(),
                    Phase::Denied => denied().into_element(),
                    Phase::Recording | Phase::Stopping => recording().into_element(),
                    Phase::Trimming | Phase::Saving => match capture.take() {
                        Some(take) if capture::heard(&take.levels) => trimming(take).into_element(),
                        _ => silent().into_element(),
                    },
                })
            })
            .into_element()
        },
        move || {
            dynamic(move || {
                let shown = phase.get();
                untracked(|| match shown {
                    Phase::Idle if problem().is_some() => failed_actions(),
                    Phase::Idle | Phase::Starting => button(Variant::Outline, Size::Md, l("Cancel"))
                        .on_press(move || capture.discard())
                        .into_element(),
                    Phase::Denied => view()
                        .flex_row()
                        .gap_2()
                        .child(button(Variant::Outline, Size::Md, l("Cancel")).on_press(move || capture.discard()))
                        .child(
                            button(Variant::Primary, Size::Md, l("Open System Settings"))
                                .on_press(service::open_privacy_settings),
                        )
                        .into_element(),
                    Phase::Recording | Phase::Stopping => recording_actions(),
                    Phase::Trimming | Phase::Saving => trimming_actions(),
                })
            })
            .into_element()
        },
    )
}

/// What keeps recording from starting: a Mac too old, or the last try's
/// error.
fn problem() -> Option<SharedString> {
    if service::support() == Support::NeedsNewerMac {
        return Some(tr("Recording what plays needs macOS 14.2 or later."));
    }
    store().capture.error().map(error_text)
}

fn failed() -> impl IntoElement {
    view()
        .flex_row()
        .gap_3()
        .items_start()
        .child(view().text_color(|| theme().destructive).child(icon(Icon::Alert, 18.0)))
        .child(text(move || problem().unwrap_or_default()).text_sm().flex_1().text_color(|| theme().foreground))
}

fn failed_actions() -> AnyElement {
    let capture = store().capture;
    let close = button(Variant::Outline, Size::Md, l("Close")).on_press(move || capture.open.set(false));
    if service::support() == Support::NeedsNewerMac {
        return close.into_element();
    }
    view()
        .flex_row()
        .gap_2()
        .child(close)
        .child(button(Variant::Primary, Size::Md, l("Try again")).on_press(move || capture.record()))
        .into_element()
}

fn starting() -> impl IntoElement {
    view()
        .gap_2()
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_3()
                .child(ui::spinner(16.0))
                .child(text(l("Getting ready to record…")).text_sm().text_color(|| theme().foreground)),
        )
        .child(when(
            || cfg!(target_os = "macos"),
            || ui::hint(l("If macOS asks, allow Listenook to record system audio.")),
        ))
}

fn denied() -> impl IntoElement {
    view()
        .gap_2()
        .bind_motion(&motion().entering(MotionPreset::FadeIn))
        .child(
            text(l("Allow Listenook to hear other apps"))
                .text_sm()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(|| theme().foreground),
        )
        .child(
            text(l("In System Settings, open Privacy & Security, then Screen & System Audio Recording, and turn on \
                 Listenook under System Audio Recording Only. Recording starts when you come back."))
            .text_sm()
            .text_color(|| theme().muted_foreground),
        )
}

fn recording() -> impl IntoElement {
    let capture = store().capture;
    on_key("space", move |_| {
        if capture.phase() == Phase::Recording {
            capture.set_paused(!capture.paused());
        }
    });
    view()
        .gap_3()
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .child(ui::recording_dot(move || !capture.paused(), 10.0))
                .child(
                    text(move || tr(if capture.paused() { "Paused" } else { "Recording" }))
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(|| theme().foreground),
                )
                .child(view().flex_1())
                .child(
                    text(move || clock(capture.elapsed_ms()))
                        .text_2xl()
                        .tabular_nums()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(|| theme().foreground)
                        .label(move || format!("{} {}", tr("Recorded"), clock(capture.elapsed_ms()))),
                ),
        )
        .child(ui::live_wave(capture.recent(), move || !capture.paused()))
        .child(ui::hint(move || {
            tr(if capture.heard() {
                "Recording goes on if you close this window."
            } else {
                "Play the video or audio you want to record, in any app."
            })
        }))
}

fn recording_actions() -> AnyElement {
    let capture = store().capture;
    let stopping = move || capture.phase() == Phase::Stopping;
    view()
        .flex_1()
        .flex_row()
        .gap_2()
        .child(button(Variant::Ghost, Size::Md, l("Discard…")).disabled(stopping).on_press(confirm_discard))
        .child(view().flex_1())
        .child(dynamic(move || {
            let paused = capture.paused();
            untracked(|| {
                let (glyph, label) = if paused { (Icon::Play, "Resume") } else { (Icon::Pause, "Pause") };
                icon_text_button(Variant::Outline, Size::Md, glyph, l(label))
                    .disabled(stopping)
                    .on_press(move || capture.set_paused(!paused))
                    .into_element()
            })
        }))
        .child(
            icon_text_button(Variant::Primary, Size::Md, Icon::Stop, l("Stop"))
                .busy(stopping)
                .disabled(stopping)
                .on_press(move || capture.stop()),
        )
        .into_element()
}

fn confirm_discard() {
    let capture = store().capture;
    ui::confirm_destructive(
        tr("Discard this recording?"),
        tr("It is deleted, and can’t be brought back."),
        tr("Cancel"),
        tr("Discard"),
        move || capture.discard(),
    );
}

/// What a recording stopped with nothing heard says.
fn silent() -> impl IntoElement {
    view()
        .gap_2()
        .bind_motion(&motion().entering(MotionPreset::FadeIn))
        .child(
            text(l("Nothing was heard")).text_sm().font_weight(FontWeight::SEMIBOLD).text_color(|| theme().foreground),
        )
        .child(
            text(l("Check that the video or audio was playing and not muted, then record again."))
                .text_sm()
                .text_color(|| theme().muted_foreground),
        )
}

fn trimming(take: Rc<service::Take>) -> impl IntoElement {
    let capture = store().capture;
    let duration = take.duration_ms;
    let levels = Rc::new(take.levels.clone());
    let source = crate::util::file_url(&take.path.to_string_lossy());

    // The preview: plays what is kept, skipping what is cut.
    let player = element_ref();
    let playing = signal(false);
    let position = signal(None::<u64>);
    let seek = move |ms: u64| {
        position.set(Some(ms));
        player.seek(ms as f64 / 1000.0);
    };
    let follow = move |ms: u64| {
        position.set(Some(ms));
        if !playing.get_untracked() {
            return;
        }
        let kept = capture.kept();
        match capture::next_kept(&kept, ms) {
            Some(next) if next > ms + 30 => player.seek(next as f64 / 1000.0),
            Some(_) => {}
            None => {
                playing.set(false);
                if let Some(first) = kept.first() {
                    seek(first.start_ms);
                }
            }
        }
    };
    let toggle = move || {
        if playing.get_untracked() {
            playing.set(false);
            return;
        }
        let kept = capture.kept();
        let from = position.get_untracked().and_then(|at| capture::next_kept(&kept, at));
        if let Some(from) = from.or_else(|| kept.first().map(|span| span.start_ms)) {
            seek(from);
            playing.set(true);
        }
    };
    on_key("space", move |_| toggle());
    let media = video(source)
        .element_ref(&player)
        .paused(move || !playing.get())
        .audio_session(|| nsh_core::AudioSession::Playback)
        .progress_interval(|| 50.0_f32)
        .on_load(move |_: &VideoInfo| {
            if let Some(at) = position.get_untracked() {
                player.seek(at as f64 / 1000.0);
            }
        })
        .on_progress(move |progress: &VideoProgress| follow((progress.current_time * 1000.0).max(0.0) as u64))
        .on_end(move || playing.set(false));

    let kept_ms = move || capture::total_ms(&capture.kept());
    let gap_summary = move || {
        let trim = capture.trim.get();
        let inside: Vec<Span> = capture.gaps().with(|gaps| {
            gaps.iter()
                .filter(|gap| gap.end_ms > trim.start_ms && gap.start_ms < trim.end_ms)
                .map(|gap| Span::new(gap.start_ms.max(trim.start_ms), gap.end_ms.min(trim.end_ms)))
                .collect()
        });
        if inside.is_empty() {
            return tr("No silence to cut.");
        }
        let (time, count) = (clock(capture::total_ms(&inside)), inside.len().to_string());
        let said = match (trim.cut_gaps, inside.len()) {
            (true, 1) => tr("Cuts {time} of silence in 1 place."),
            (true, _) => tr("Cuts {time} of silence in {count} places."),
            (false, 1) => tr("{time} of silence in 1 place stays in."),
            (false, _) => tr("{time} of silence in {count} places stays in."),
        };
        said.replace("{time}", &time).replace("{count}", &count).into()
    };

    view()
        .gap_4()
        .child(ui::field(
            l("Name"),
            ui::text_field_with(capture.title, SharedString::default, move |input| {
                // Return saves it as named: stopping, then Return, keeps a recording.
                input.test_id("recording-name").auto_focus(true).on_submit(move |_: &str| {
                    if capture.phase() == Phase::Trimming {
                        capture.save(capture.transcribes());
                    }
                })
            }),
        ))
        .child(
            view()
                .gap_2()
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(dynamic(move || {
                            let on = playing.get();
                            untracked(|| {
                                let (glyph, name) = if on { (Icon::Pause, "Pause") } else { (Icon::Play, "Play") };
                                ui::icon_button(glyph, tr(name), Size::Sm, toggle).into_element()
                            })
                        }))
                        .child(
                            text(move || clock(position.get().unwrap_or(capture.trim.get().start_ms)))
                                .text_sm()
                                .tabular_nums()
                                .text_color(|| theme().foreground),
                        )
                        .child(view().flex_1())
                        .child(
                            text(move || {
                                SharedString::from(
                                    tr("Keeps {kept} of {total}")
                                        .replace("{kept}", &clock(kept_ms()))
                                        .replace("{total}", &clock(duration)),
                                )
                            })
                            .text_sm()
                            .tabular_nums()
                            .text_color(|| theme().muted_foreground),
                        ),
                )
                .child(ui::waveform(levels, move || duration, move || capture.kept(), move || position.get(), seek))
                .child(ui::range_slider(
                    tr("Trim"),
                    move || {
                        let trim = capture.trim.get();
                        (trim.start_ms as f64, trim.end_ms as f64)
                    },
                    move || duration as f64,
                    100.0,
                    move |start, end| {
                        capture.trim.update(|trim| {
                            trim.start_ms = start.round() as u64;
                            trim.end_ms = (end.round() as u64).min(duration);
                        })
                    },
                ))
                .child(
                    view()
                        .flex_row()
                        .justify_between()
                        .child(ui::hint(move || clock(capture.trim.get().start_ms)).tabular_nums())
                        .child(ui::hint(move || clock(capture.trim.get().end_ms)).tabular_nums()),
                ),
        )
        .child(
            view()
                .gap_1()
                .child(ui::switch(
                    l("Cut out silent gaps"),
                    move || capture.trim.get().cut_gaps,
                    move |on| capture.set_cut_gaps(on),
                ))
                .child(ui::hint(gap_summary)),
        )
        .child(view().h(px(1.0)).opacity(0.0).child(media.flex_1()))
}

fn trimming_actions() -> AnyElement {
    let capture = store().capture;
    let saving = move || capture.phase() == Phase::Saving;
    let nothing = move || capture.take().is_none_or(|take| !capture::heard(&take.levels));
    let transcribe = signal(capture.transcribes());
    if untracked(nothing) {
        return view()
            .flex_row()
            .gap_2()
            .child(button(Variant::Outline, Size::Md, l("Discard")).on_press(move || capture.discard()))
            .child(button(Variant::Primary, Size::Md, l("Record again")).on_press(move || {
                capture.discard();
                capture.record();
            }))
            .into_element();
    }
    view()
        .flex_1()
        .flex_row()
        .items_center()
        .gap_3()
        .child(button(Variant::Ghost, Size::Md, l("Discard…")).disabled(saving).on_press(confirm_discard))
        .child(view().flex_1())
        .child(ui::checkbox(l("Transcribe"), move || transcribe.get(), move |on| transcribe.set(on)))
        .child(
            button(Variant::Primary, Size::Md, move || tr(if saving() { "Saving…" } else { "Save to Library" }))
                .busy(saving)
                .disabled(move || saving() || capture.kept().is_empty())
                .on_press(move || capture.save(transcribe.get_untracked())),
        )
        .into_element()
}
