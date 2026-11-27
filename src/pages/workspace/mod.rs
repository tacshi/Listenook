mod brief;
mod practice;
mod review;
mod transcript;
mod undo;

use listenook_core::{
    AiGenerationStatus, ContentMode, ExportOptions, Segment, TRANSLATION_LANGUAGES, TranslationStatus,
    format::track_position, transcript::caption, transcript::export,
};
use nsh_base::theme;
use nsh_core::{
    desktop::WindowMode,
    element::desktop::{WindowRef, current_window},
    prelude::*,
};
use review::{Practice, Review, Side};

use super::dialogs::{ExportDialog, JobDialog, export_dialog, rename_dialog};
use super::media::{MediaEvent, Playback, media_view};
use crate::ui::{error_text, l, tr};
use crate::work::{ai, podcasts};
use crate::{
    pages::chrome::{rate_menu, sleep_menu, time_text, top_bar},
    platform::file_url,
    services::media,
    state::{AiSetup, SettingsTab, store},
    ui::{
        self, EmptyState, Icon, IconButton, MenuAction, MenuDivider, MenuToggle, Modal, ModalActions, Size, Tone,
        Variant, button, checkbox, field, hint, menu, progress_bar, select, toast, toggle_icon_button,
        tokens::{self, motion},
    },
};

pub(crate) fn reader(id: &str) -> impl IntoElement {
    let store = store();
    if untracked(|| store.job(id)).is_some_and(|job| super::library::can_open(&job)) {
        return opened(id).into_element();
    }
    view()
        .flex_1()
        .child(top_bar())
        .child(EmptyState {
            glyph: Icon::Workspace,
            title: l("This recording can’t be opened"),
            description: l("Its media file is missing and it has no transcript."),
            action: button(Variant::Default, Size::Md, l("Back to Library"))
                .on_press(move || store.act(crate::state::Action::CloseReader)),
        })
        .into_element()
}

/// Practice docked at the bottom of the reader: about a third of the
/// window, within these.
const ANSWER_MIN: f32 = 200.0;
const ANSWER_MAX: f32 = 360.0;
/// A keyboard taller than this is the software one (a hardware keyboard
/// leaves only its shortcut bar).
const SOFT_KEYBOARD: f32 = 120.0;

fn opened(id: &str) -> impl IntoElement {
    let review = Review::new(id);
    let store = crate::state::store();
    effect(move || {
        let open = review.side.get() == Side::Brief;
        untracked(|| {
            if store.setting(|s| s.extra.get("reader_brief_open").and_then(serde_json::Value::as_bool)) != Some(open) {
                store.update_settings(|s| {
                    s.extra.insert("reader_brief_open".into(), open.into());
                });
            }
        });
    });
    let (export, rename) = (ExportDialog::new(), JobDialog::new());
    let translate = signal(false);
    let brief_dialog = signal(false);
    let has_video = review.has_video;
    let source = signal(String::new());
    let loaded = std::rc::Rc::new(std::cell::RefCell::new(None::<String>));
    effect(move || {
        let path = review.job_with(|job| job.as_ref().map(|job| job.source_path.clone()).unwrap_or_default());
        if loaded.borrow().as_deref() == Some(path.as_str()) {
            return;
        }
        loaded.replace(Some(path.clone()));
        untracked(|| source.set(file_url(&path)));
    });
    let plays_on_load = std::cell::Cell::new(store.take_play_on_open(id));
    // Two frames on: nsh tells the window's new size as macOS starts its animation, and the reader
    // switched in that same update was what macOS animated, its transcript not drawn yet.
    let restore = move || {
        spawn(async move {
            next_frame().await;
            next_frame().await;
            if untracked(|| review.is_fullscreen()) {
                batch(|| review.set_fullscreen(false));
            }
        });
    };
    let leaving = std::rc::Rc::new(std::cell::Cell::new(false));
    {
        let leaving = leaving.clone();
        current_window().on_mode_change(move |mode, _| {
            if mode != WindowMode::FullScreen && untracked(|| review.is_fullscreen()) {
                leaving.set(true);
                let leaving = leaving.clone();
                spawn(async move {
                    timer(std::time::Duration::from_millis(1200)).await;
                    if leaving.replace(false) {
                        restore();
                    }
                });
            }
        });
    }
    {
        let leaving = leaving.clone();
        current_window().on_bounds_change(move |_| {
            if leaving.replace(false) {
                restore();
            }
        });
    }
    cleanup(move || leaving.set(false));
    on_key_with("space", KeyOptions { for_focus: true, ..KeyOptions::default() }, move |_| review.toggle_play());
    on_key("left", move |_| review.step(-1));
    on_key("right", move |_| review.step(1));
    on_key("alt+left", move |_| review.step(-1));
    on_key("alt+right", move |_| review.step(1));
    let held = std::rc::Rc::new(std::cell::RefCell::new(None::<Hold>));
    {
        let held = held.clone();
        on_key_with("r", KeyOptions { repeat: true, ..KeyOptions::default() }, move |_| {
            let now = std::time::Instant::now();
            if let Some(hold) = held.borrow_mut().as_mut() {
                hold.last = now;
                hold.repeated = true;
                return;
            }
            let Some(index) = review.target_or_first() else {
                return;
            };
            let before = untracked(|| review.repeating());
            review.hold_repeat(index);
            held.replace(Some(Hold { before, last: now, repeated: false }));
            let held = held.clone();
            spawn(async move {
                loop {
                    timer(std::time::Duration::from_millis(80)).await;
                    let Some((quiet, repeated)) =
                        held.borrow().as_ref().map(|hold| (hold.last.elapsed(), hold.repeated))
                    else {
                        return;
                    };
                    let patience = if repeated { REPEAT_GAP } else { FIRST_REPEAT };
                    if quiet > patience {
                        if let Some(hold) = held.take() {
                            review.end_hold(hold.before);
                        }
                        return;
                    }
                }
            });
        });
    }
    {
        let held = held.clone();
        cleanup(move || drop(held.take()));
    }
    on_key("s", move |_| {
        let current = untracked(|| review.target()).and_then(|index| review.segment(index)).map(|segment| segment.id);
        review.toggle_revealed(current);
    });
    on_key("mod+f", move |_| {
        if untracked(|| review.has_text()) {
            review.set_searching(true);
        }
    });
    on_key("mod+z", move |_| {
        review.undo();
    });
    on_key("e", move |_| {
        if let Some(index) = untracked(|| review.target_or_first()) {
            review.edit(index);
        }
    });
    let frame = stored(current_window());
    on_key("enter", move |_| {
        if review.has_video {
            set_fullscreen(review, frame, true);
        }
    });
    on_key("escape", move |_| {
        if untracked(|| review.is_picking_skip()) {
            review.stop_picking_skip();
        } else if untracked(|| review.is_fullscreen()) {
            set_fullscreen(review, frame, false);
        } else if untracked(|| review.is_editing()) {
            review.close_editor();
        } else if untracked(|| review.is_searching()) {
            review.set_searching(false);
        } else if untracked(|| review.repeating()).is_some() && untracked(|| review.practice()) != Practice::Mimic {
            review.stop_repeating();
        } else if matches!(untracked(|| review.side()), Side::Practice | Side::Brief) {
            if untracked(|| review.side()) == Side::Practice {
                practice::stop(review);
            }
            review.set_side(Side::None);
        } else {
            store.act(crate::state::Action::CloseReader);
        }
    });
    let controls = std::rc::Rc::new(media::claim(move |command| match command {
        media::Command::Play => {
            if untracked(|| review.is_paused()) {
                review.toggle_play();
            }
        }
        media::Command::Pause => {
            if !untracked(|| review.is_paused()) {
                review.toggle_play();
            }
        }
        media::Command::Toggle => review.toggle_play(),
        media::Command::Next => review.step(1),
        media::Command::Previous => review.step(-1),
        media::Command::Seek(position_ms) => review.seek(position_ms),
    }));
    let sleeps = untracked(|| crate::state::sleep::SleepState::get().stops());
    effect(move || {
        if crate::state::sleep::SleepState::get().stops() != sleeps {
            untracked(|| review.pause());
        }
    });
    let beat = computed(move || review.position_ms.get() / 5000);
    effect(move || {
        beat.get();
        let (title, artist) = review.job_with(|job| {
            let title = job.as_ref().map(|job| job.title()).unwrap_or_default();
            (title, job.as_deref().and_then(podcasts::show_of).unwrap_or_else(|| "Listenook".into()))
        });
        controls.publish(Some(media::Now {
            title,
            artist,
            position_ms: untracked(|| review.position_ms()),
            duration_ms: review.duration_ms.get(),
            playing: !review.is_paused(),
            rate: review.rate.get(),
        }));
    });
    let last = std::rc::Rc::new(std::cell::Cell::new((untracked(|| review.position_ms()), 0_i64, false, true)));
    {
        let last = last.clone();
        effect(move || {
            last.set((review.position_ms.get(), review.duration_ms.get(), review.fullscreen.get(), review.is_paused()))
        });
    }
    let remember = move |job_id: &str, position: i64, duration: i64| {
        let resume = position > 3000 && (duration <= 0 || position < duration - 3000);
        store.act(crate::state::Action::RememberPosition(job_id, resume.then_some(position)));
    };
    {
        let (job_id, pulse) = (id.to_owned(), computed(move || review.position_ms.get() / 15_000));
        let first = std::cell::Cell::new(true);
        effect(move || {
            pulse.get();
            if !first.replace(false) {
                untracked(|| remember(&job_id, review.position_ms.get(), review.duration_ms.get()));
            }
        });
    }
    let job_id = id.to_owned();
    cleanup(move || {
        let (position, duration, fullscreen, paused) = last.get();
        remember(&job_id, position, duration);
        store.act(crate::state::Action::LeftReader(&job_id, paused));
        if fullscreen {
            store.act(crate::state::Action::SetImmersive(false));
            current_window().set_mode(WindowMode::Normal);
        }
    });
    let (boost, volume) = (signal(false), signal(1.0_f32));
    let media = media_view(
        &review.player(),
        move || source.get(),
        move || Playback {
            paused: review.is_paused() && !review.holding.get(),
            muted: review.hushed.get(),
            volume: volume.get(),
            rate: if boost.get() { super::gestures::BOOST } else { review.rate.get() },
            // Looped only while playing: a pause that lands at the very end, just
            // before the player reports it, would otherwise be undone by the loop
            // starting over (seen on the iPad, Space pressed at the last word).
            // Played again, a recording paused at its end starts from the top.
            repeat: review.looping.get() && !review.is_paused(),
            progress_ms: if review.ticks_often() { 50.0 } else { 500.0 },
        },
        move |event| match event {
            MediaEvent::Loaded(info) => review.loaded((info.duration * 1000.0) as i64, plays_on_load.replace(false)),
            MediaEvent::Progress(progress) => {
                review.on_progress((progress.current_time * 1000.0) as i64, (progress.duration * 1000.0) as i64)
            }
            MediaEvent::Ended => {
                if crate::state::sleep::SleepState::get().ended() || !untracked(|| review.is_looping()) {
                    review.set_paused(true);
                }
            }
            MediaEvent::Failed => {
                let path = review.job_with(|job| job.as_ref().map(|job| job.source_path.clone()).unwrap_or_default());
                let missing = !std::path::Path::new(&path).is_file();
                toast(Tone::Error, error_text(if missing { "missing_source" } else { "unsupported_format" }));
            }
        },
    );

    let side = move || review.side.get();
    let dock = move || review.docked();
    let narrow =
        move || (crate::pages::chrome::page_stacks() && side() != Side::None && !review.fullscreen.get()) || dock();
    let on_top = move || {
        has_video && side() == Side::Video && !review.fullscreen.get() && (review.video_on_top.get() || narrow())
    };
    let stacked = move || on_top() || narrow();
    let soft_keyboard = move || crate::platform::is_phone() && keyboard_height().0 > SOFT_KEYBOARD;
    // Docked on a touch device, the answer sits on the keyboard: the reader
    // ends where it starts (the root's padding already keeps the home
    // indicator's inset).
    let lift = move || {
        if dock() && crate::platform::is_phone() { (keyboard_height().0 - safe_area().bottom.0).max(0.0) } else { 0.0 }
    };
    let hud = signal(true);
    let wait = std::rc::Rc::new(std::cell::RefCell::new(None::<Spawned<()>>));
    let wake = move || {
        if !untracked(|| review.is_fullscreen()) {
            return;
        }
        hud.set(true);
        let later = set_timeout(std::time::Duration::from_millis(2500), move || {
            if !untracked(|| review.is_paused()) {
                hud.try_set(false);
            }
        });
        if let Some(earlier) = wait.replace(Some(later)) {
            earlier.cancel();
        }
    };
    effect({
        let wake = wake.clone();
        move || {
            let _ = (review.fullscreen.get(), review.is_paused());
            hud.set(true);
            untracked(&wake);
        }
    });
    let side_column = view()
        .style_with(move |s| match (review.fullscreen.get(), side()) {
            (true, _) => s.flex_1(),
            (false, Side::None) => s.w(px(0.0)),
            (false, Side::Practice) if dock() => {
                let room = window().height.0;
                let height = if soft_keyboard() {
                    ((room - keyboard_height().0) * 0.55).max(ANSWER_MIN)
                } else {
                    (room / 3.0).clamp(ANSWER_MIN, ANSWER_MAX)
                };
                s.w_full().h(px(height))
            }
            (false, Side::Video) if narrow() => {
                s.w_full().h(px(crate::pages::chrome::page_width() * 9.0 / 16.0)).border_b_1()
            }
            (false, _) if narrow() => s.w_full().h(px(window().height.0 * 0.45)).border_t_1(),
            (false, _) if on_top() => s.w_full().h(px(review.video_height.get())).border_b_1(),
            (false, _) => s.w(px(review.side_width.get())).border_l_1(),
        })
        .flex_shrink_0()
        .overflow_hidden()
        .border_color(|| theme().border)
        .bg(move || match (review.fullscreen.get(), dock()) {
            (true, _) => tokens::ink(tokens::Ink::Stage),
            (false, true) => theme().background,
            (false, false) => theme().card,
        })
        .child(
            view()
                .style_with(move |s| {
                    if review.fullscreen.get() || stacked() { s.w_full() } else { s.w(px(review.side_width.get())) }
                })
                .flex_1()
                .child(
                    view()
                        .bg(
                            move || {
                                if review.fullscreen.get() { tokens::ink(tokens::Ink::Stage) } else { theme().muted }
                            },
                        )
                        .style_with(move |s| match (has_video, side(), review.fullscreen.get()) {
                            (true, Side::Video, _) | (true, _, true) => s.flex_1(),
                            _ => s.h(px(1.0)).opacity(0.0),
                        })
                        .child(media)
                        .child(when(move || review.fullscreen.get(), move || subtitle(review, hud)))
                        .child(when(
                            move || {
                                crate::platform::is_phone()
                                    && crate::pages::chrome::page_narrow()
                                    && side() == Side::Video
                                    && !review.fullscreen.get()
                            },
                            move || {
                                view()
                                    .absolute()
                                    .top(px(0.0))
                                    .left(px(0.0))
                                    .right(px(0.0))
                                    .px(px(ui::PAGE_INSET))
                                    .pt_3()
                                    .pb_8()
                                    .bg_linear_to_b()
                                    .gradient_from(|| tokens::ink(tokens::Ink::Stage).opacity(0.6))
                                    .gradient_to(|| tokens::ink(tokens::Ink::Stage).opacity(0.0))
                                    .opacity(move || if review.is_paused() { 1.0_f32 } else { 0.0 })
                                    .transition_opacity()
                                    .duration(motion::BASE)
                                    .child(
                                        text(move || {
                                            review.job_with(|job| {
                                                job.as_ref()
                                                    .map(|job| SharedString::from(job.title()))
                                                    .unwrap_or_default()
                                            })
                                        })
                                        .text_base()
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .number_of_lines(1)
                                        .text_color(|| theme().foreground.dark)
                                        .role(AccessibilityRole::Header),
                                    )
                            },
                        ))
                        .child(when(
                            move || {
                                crate::platform::is_phone()
                                    && has_video
                                    && (review.fullscreen.get() || side() == Side::Video)
                            },
                            {
                                let wake = wake.clone();
                                move || {
                                    let wake = wake.clone();
                                    // Full screen a tap shows or hides the controls; beside the transcript it plays or pauses.
                                    super::gestures::layer(super::gestures::Video {
                                        position: std::rc::Rc::new(move || untracked(|| review.position_ms())),
                                        duration: std::rc::Rc::new(move || untracked(|| review.duration_ms())),
                                        seek: std::rc::Rc::new(move |ms| review.seek(ms)),
                                        tap: std::rc::Rc::new(move || {
                                            if !untracked(|| review.is_fullscreen()) {
                                                review.toggle_play();
                                            } else if hud.get_untracked() {
                                                hud.set(false);
                                            } else {
                                                wake();
                                            }
                                        }),
                                        boost,
                                        volume,
                                    })
                                }
                            },
                        )),
                )
                .child(dynamic(move || {
                    let side = if review.fullscreen.get() { Side::Video } else { side() };
                    untracked(|| match side {
                        Side::Practice => practice::practice_panel(review).into_element(),
                        Side::Brief => brief::brief_pane(review, brief_dialog).into_element(),
                        Side::None | Side::Video => view().into_element(),
                    })
                })),
        );

    view()
        .flex_1()
        .pb(move || px(lift()))
        .on_mouse_move(move |_: &MouseEvent| wake())
        .style_with(move |s| if review.fullscreen.get() && !hud.get() { s.cursor(Cursor::None) } else { s })
        .child(when(move || !review.fullscreen.get(), move || header(review, export, rename, translate)))
        .child(when(move || !review.fullscreen.get(), move || transcribe_strip(review)))
        .child(when(move || !review.fullscreen.get(), move || translation_strip(review)))
        .child(when(move || !review.fullscreen.get(), move || ad_strip(review)))
        .child(when(move || !review.fullscreen.get(), move || skip_strip(review)))
        .child(
            view()
                .flex_1()
                .min_h(px(0.0))
                .style_with(move |s| match (on_top(), narrow()) {
                    (true, _) => s.flex_col_reverse(),
                    (false, true) => s.flex_col(),
                    (false, false) => s.flex_row(),
                })
                .child(
                    view()
                        .flex_1()
                        .min_w(px(0.0))
                        .min_h(px(0.0))
                        .style_when(move || review.fullscreen.get(), |s| s.hidden())
                        .child(
                            when(move || review.has_text(), move || transcript::transcript(review))
                                .otherwise(move || untranscribed(review)),
                        ),
                )
                .child(side_column.child(when(
                    move || !narrow(),
                    move || when(on_top, move || divider(review, true)).otherwise(move || divider(review, false)),
                ))),
        )
        .child(when(move || !(dock() && soft_keyboard()), move || transport(review, hud)))
        .child(highlight_key(review))
        .child(export_dialog(export))
        .child(rename_dialog(rename))
        .child(translate_dialog(review, translate))
        .child(brief::generate_dialog(review, brief_dialog))
        .child(brief::edit_dialog(review))
}

/// Where the transcript goes while there is none: what it waits on, and the
/// way to make one. The recording plays meanwhile, and the transcript takes
/// this place once it is done.
fn untranscribed(review: Review) -> impl IntoElement {
    let status = move || review.job_with(|job| job.as_ref().map(|job| job.status).unwrap_or_default());
    let active = move || status().is_active();
    let description = move || -> SharedString {
        review.job_with(|job| {
            let Some(job) = job.as_ref() else {
                return SharedString::default();
            };
            if job.status().is_transcribable() {
                tr("Transcribe it to read along, practice sentence by sentence and get an AI Brief.")
            } else if let Some(code) = job.error_code.as_deref().filter(|_| job.status().is_retryable()) {
                error_text(code)
            } else {
                tr(listenook_core::l10n::status_label(job.status))
            }
        })
    };
    EmptyState {
        glyph: Icon::Workspace,
        title: l("No transcript yet"),
        description,
        action: view()
            .w(px(240.0))
            .items_center()
            .gap_3()
            .child(when(active, move || progress_bar(move || review.job_with(|job| job.as_ref()?.fraction())).w_full()))
            .child(when(
                move || status().is_transcribable(),
                move || {
                    button(Variant::Default, Size::Md, l("Transcribe"))
                        .on_press(move || crate::work::transcribe::start(&review.id()))
                },
            ))
            .child(when(
                move || status().is_retryable(),
                move || {
                    button(Variant::Default, Size::Md, l("Retry")).on_press(move || super::library::retry(&review.id()))
                },
            ))
            .child(when(active, move || {
                button(Variant::Ghost, Size::Sm, l("Cancel"))
                    .on_press(move || crate::work::transcribe::cancel(&review.id()))
            })),
    }
}

/// ⌘B bolds the selected words: bound only while words are selected, so
/// with none it shows or hides the sidebar, as everywhere else.
fn highlight_key(review: Review) -> impl IntoElement {
    when(
        move || review.has_selection(),
        move || {
            on_key("mod+b", move |_| review.toggle_highlight());
            view().absolute()
        },
    )
}

fn has_translation(review: Review) -> bool {
    review.job_with(|job| {
        job.as_ref().and_then(|job| job.document()).is_some_and(|d| d.segments.iter().any(Segment::has_translation))
    })
}

fn side_toggle(review: Review, side: Side, glyph: Icon, name: &'static str) -> impl IntoElement {
    let on = move || review.side.get() == side;
    view().window_drag(false).child(ui::ToggleButton {
        variant: Variant::Ghost,
        glyph,
        name: tr(name),
        size: Size::Sm,
        on,
        on_press: move || {
            let closing = untracked(on);
            let next = if closing { Side::None } else { side };
            if side == Side::Video {
                crate::state::store().update_settings(|s| {
                    s.extra.insert("reader_video_wanted".into(), (!closing).into());
                });
            }
            match next {
                Side::Practice => practice::start(review, practice::last_mode()),
                _ => {
                    if untracked(|| review.side()) == Side::Practice {
                        practice::stop(review);
                    }
                    review.set_side(next);
                }
            }
        },
    })
}

fn header(review: Review, export: ExportDialog, rename: JobDialog, translate: Signal<bool>) -> AnyElement {
    let store = crate::state::store();
    let title =
        move || review.job_with(|job| job.as_ref().map(|job| SharedString::from(job.title())).unwrap_or_default());
    let mode_label = move || match review.mode.get() {
        ContentMode::Original => tr("Original"),
        ContentMode::Translated => tr("Translated"),
        ContentMode::Bilingual => tr("Bilingual"),
    };
    let mode_item = move |mode: ContentMode, label: &'static str| ui::MenuChoice {
        label: l(label),
        checked: move || review.mode.get() == mode,
        on_select: move || {
            review.set_mode(mode);
            store.update_settings(|s| {
                s.extra.insert("reader_content_mode".into(), mode.as_str().into());
            });
        },
    };
    let touch = crate::platform::is_phone();
    let lead = if touch {
        view()
    } else {
        view()
            .flex_1()
            .min_w(px(0.0))
            .flex_row()
            .items_center()
            .gap_2()
            .child(view().window_drag(false).child(IconButton {
                glyph: Icon::ChevronLeft,
                name: tr("Back"),
                size: Size::Sm,
                on_press: move || store.act(crate::state::Action::CloseReader),
            }))
            .child(
                text(title)
                    .text_base()
                    .font_weight(FontWeight::SEMIBOLD)
                    .number_of_lines(1)
                    .flex_1()
                    .min_w(px(0.0))
                    .text_color(|| theme().foreground)
                    .role(AccessibilityRole::Header),
            )
    };
    let base = if touch {
        view()
            .h(px(44.0))
            .flex_shrink_0()
            .flex_row()
            .items_center()
            .gap_1()
            .px_1p5()
            .rounded_full()
            .style_with(|s| tokens::surface(tokens::Surface::BarGlass, s))
    } else {
        top_bar().child(lead)
    };
    let bar = base
        .child(when(
            move || has_translation(review),
            move || {
                let picker = if touch {
                    let open = signal(false);
                    ui::menu_with(open, ui::menu_trigger(Icon::Languages, tr("Language"), Size::Sm, open))
                } else {
                    menu(ui::menu_icon_text_button(Variant::Ghost, Size::Sm, Icon::Languages, mode_label))
                };
                view().window_drag(false).child(
                    picker
                        .child(mode_item(ContentMode::Original, "Original"))
                        .child(mode_item(ContentMode::Translated, "Translated"))
                        .child(mode_item(ContentMode::Bilingual, "Bilingual")),
                )
            },
        ))
        .child(when(
            move || review.has_text(),
            move || {
                view()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .child(view().window_drag(false).child(IconButton {
                        glyph: Icon::Search,
                        name: tr("Search transcript"),
                        size: Size::Sm,
                        on_press: move || review.set_searching(!untracked(|| review.is_searching())),
                    }))
                    .child(side_toggle(review, Side::Practice, Icon::Practice, "Practice"))
                    .child(side_toggle(review, Side::Brief, Icon::Sparkles, "AI Brief"))
            },
        ))
        .child(when(move || review.has_video, move || side_toggle(review, Side::Video, Icon::Film, "Video")))
        .child(when(
            move || review.has_video && review.side.get() == Side::Video && !crate::pages::chrome::page_stacks(),
            move || {
                view().window_drag(false).child(dynamic(move || {
                    let on_top = review.video_on_top.get();
                    IconButton {
                        glyph: if on_top { Icon::Columns } else { Icon::Rows },
                        name: tr(if on_top { "Video at the side" } else { "Video on top" }),
                        size: Size::Sm,
                        on_press: move || {
                            review.set_video_on_top(!on_top);
                            crate::state::store().update_settings(|s| {
                                s.extra.insert("reader_video_on_top".into(), (!on_top).into());
                            });
                        },
                    }
                }))
            },
        ))
        .child(view().window_drag(false).child({
            let open = signal(false);
            ui::menu_with(open, ui::menu_trigger(Icon::More, tr("More actions"), Size::Sm, open))
                .child(when(
                    move || {
                        review.has_text()
                            && !(review.side.get() == Side::Practice && review.practice.get() == Practice::Dictation)
                    },
                    move || MenuToggle {
                        label: l("Blind listening"),
                        checked: move || review.blind_listening(),
                        on_select: move || {
                            store.update_settings(|s| s.blind_listening_enabled = !s.blind_listening_enabled);
                            review.hide_revealed();
                        },
                    },
                ))
                .child(when(
                    move || review.has_text(),
                    move || MenuToggle {
                        label: l("Speaker labels"),
                        checked: move || store.setting(|s| s.show_speakers),
                        on_select: move || store.update_settings(|s| s.show_speakers = !s.show_speakers),
                    },
                ))
                .child(when(
                    move || review.has_text(),
                    move || MenuToggle {
                        label: l("Timestamps"),
                        checked: move || store.setting(|s| s.show_timestamps),
                        on_select: move || store.update_settings(|s| s.show_timestamps = !s.show_timestamps),
                    },
                ))
                .child(when(move || review.has_text(), || MenuDivider))
                .child(when(
                    move || review.has_text(),
                    move || MenuAction {
                        glyph: Icon::Languages,
                        label: l("Translate…"),
                        on_select: move || translate.set(true),
                    },
                ))
                .child(when(
                    move || review.has_text(),
                    move || MenuAction {
                        glyph: Icon::Scissors,
                        label: l("Find ads"),
                        on_select: move || {
                            if store.ai_ready() {
                                ai::start_ad_scan(&review.id());
                            } else {
                                toast(Tone::Info, tr("Set up AI in Settings to find ads."));
                                store.act(crate::state::Action::OpenSettings(SettingsTab::Ai));
                            }
                        },
                    },
                ))
                .child(when(
                    move || review.has_text(),
                    move || MenuAction {
                        glyph: Icon::Copy,
                        label: l("Copy transcript"),
                        on_select: move || {
                            if let Some(job) = store.job_now(&review.id()) {
                                let settings = store.settings();
                                let options = ExportOptions {
                                    show_speakers: settings.show_speakers,
                                    show_timestamps: settings.show_timestamps,
                                    content_mode: untracked(|| review.mode()),
                                    locale_code: store.lang().code().into(),
                                    ..ExportOptions::default()
                                };
                                copy(
                                    export::export(&job, export::Export::Transcript(&options)).contents,
                                    Some("Transcript copied"),
                                );
                            }
                        },
                    },
                ))
                .child(when(
                    move || review.has_text(),
                    move || MenuAction {
                        glyph: Icon::Export,
                        label: l("Export…"),
                        on_select: move || export.show(&review.id()),
                    },
                ))
                .child(MenuAction {
                    glyph: Icon::Pencil,
                    label: l("Rename…"),
                    on_select: move || rename.show(&review.id()),
                })
                .child(when(
                    move || review.job_with(|job| job.as_deref().is_some_and(super::library::can_transcribe_again)),
                    move || MenuAction {
                        glyph: Icon::Transcribe,
                        label: l("Transcribe again…"),
                        on_select: move || super::library::transcribe_again(&review.id()),
                    },
                ))
                .child(when(
                    || !crate::platform::is_phone() || cfg!(target_os = "ios"),
                    move || MenuAction {
                        glyph: Icon::Refresh,
                        label: l("Relink media…"),
                        on_select: move || crate::work::import::relink(review.id()),
                    },
                ))
        }));
    if !touch {
        return bar.into_element();
    }
    let tight = crate::pages::chrome::page_narrow;
    let pictured = move || review.has_video && review.side.get() == Side::Video;
    view()
        .border_b_1()
        .border_color(|| theme().border)
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .p_2()
                .child(ui::BarButton {
                    glyph: Icon::Back,
                    name: tr("Back"),
                    on_press: move || store.act(crate::state::Action::CloseReader),
                })
                .child(when(
                    || !crate::platform::compact(),
                    move || ui::BarButton {
                        glyph: Icon::Sidebar,
                        name: tr("Sidebar"),
                        on_press: move || store.act(crate::state::Action::ToggleSidebar),
                    },
                ))
                .child(when(tight, || view().flex_1()).otherwise(move || {
                    text(title)
                        .text_lg()
                        .font_weight(FontWeight::SEMIBOLD)
                        .number_of_lines(1)
                        .text_center()
                        .flex_1()
                        .min_w(px(0.0))
                        .text_color(|| theme().foreground)
                        .role(AccessibilityRole::Header)
                }))
                .child(bar),
        )
        .child(when(
            move || tight() && !pictured(),
            move || {
                text(title)
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .number_of_lines(1)
                    .px(px(ui::PAGE_INSET))
                    .pb_2()
                    .text_color(|| theme().foreground)
                    .role(AccessibilityRole::Header)
            },
        ))
        .into_element()
}

/// While a recording that has a transcript is transcribed again, or its words are timed: what it
/// is doing, how far it is, and a way to stop it. The transcript it has stays readable meanwhile.
fn transcribe_strip(review: Review) -> impl IntoElement {
    let job = move |f: fn(&listenook_core::Job) -> bool| review.job_with(|job| job.as_deref().is_some_and(f));
    let visible = move || job(|job| job.status().is_active() && job.has_transcript());
    when(visible, move || {
        view()
            .flex_row()
            .items_center()
            .gap_3()
            .px(px(ui::PAGE_INSET))
            .py_2()
            .border_b_1()
            .border_color(|| theme().border)
            .bg(|| theme().muted)
            .child(
                text(move || {
                    review.job_with(|job| {
                        job.as_ref().map(|job| tr(listenook_core::l10n::status_label(job.status))).unwrap_or_default()
                    })
                })
                .text_xs()
                .text_color(|| theme().muted_foreground),
            )
            .child(progress_bar(move || review.job_with(|job| job.as_ref()?.fraction())).flex_1())
            .child(
                button(Variant::Ghost, Size::Sm, l("Cancel"))
                    .on_press(move || crate::work::transcribe::cancel(&review.id())),
            )
    })
}

fn translation_strip(review: Review) -> impl IntoElement {
    let state =
        move || review.job_with(|job| job.as_ref().map(|job| job.translation_state.clone()).unwrap_or_default());
    let visible = move || !matches!(state().status, TranslationStatus::Idle | TranslationStatus::Completed);
    when(visible, move || {
        let running = move || state().status == TranslationStatus::Translating;
        view()
            .flex_row()
            .items_center()
            .gap_3()
            .px(px(ui::PAGE_INSET))
            .py_2()
            .border_b_1()
            .border_color(|| theme().border)
            .bg(|| theme().muted)
            .child(
                text(move || -> SharedString {
                    let state = state();
                    match state.status {
                        TranslationStatus::Translating => {
                            format!("{} {}/{}", tr("Translating"), state.completed_segments, state.total_segments)
                                .into()
                        }
                        _ => state
                            .error_code
                            .as_deref()
                            .map(error_text)
                            .unwrap_or_else(|| tr("Translation stopped before it finished.")),
                    }
                })
                .text_xs()
                .text_color(|| theme().muted_foreground),
            )
            .child(when(running, move || {
                progress_bar(move || {
                    let state = state();
                    Some(state.completed_segments as f32 / state.total_segments.max(1) as f32)
                })
                .flex_1()
            }))
            .child(
                when(running, move || {
                    button(Variant::Ghost, Size::Sm, l("Cancel")).on_press(move || ai::cancel_translation(&review.id()))
                })
                .otherwise(move || {
                    let dismiss = move || {
                        store().update_job(&review.id(), |job| job.apply(listenook_core::Change::DismissTranslation));
                    };
                    view()
                        .flex_1()
                        .flex_row()
                        .justify_end()
                        .gap_2()
                        // A missing or rejected key is put right in Settings, not by trying again.
                        .child(when(
                            move || state().error_code.as_deref().is_some_and(ai::needs_setup),
                            move || {
                                button(Variant::Outline, Size::Sm, l("Settings")).on_press(move || {
                                    dismiss();
                                    store().act(crate::state::Action::OpenSettings(SettingsTab::Ai));
                                })
                            },
                        ))
                        .child(button(Variant::Ghost, Size::Sm, l("Dismiss")).on_press(dismiss))
                }),
            )
    })
}

/// While a stretch to skip is picked: what to do next, and a way out.
fn skip_strip(review: Review) -> impl IntoElement {
    when(
        move || review.is_picking_skip(),
        move || {
            on_key_with(
                "escape",
                KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() },
                move |_| review.stop_picking_skip(),
            );
            view()
                .flex_row()
                .items_center()
                .gap_3()
                .px(px(ui::PAGE_INSET))
                .py_2()
                .border_b_1()
                .border_color(|| theme().border)
                .bg(|| theme().primary.opacity(0.08))
                .test_id("skip-strip")
                .child(ui::icon(Icon::Scissors, 14.0).text_color(|| theme().primary))
                .child(
                    text(l("Now tap the last sentence to skip.")).text_sm().flex_1().text_color(|| theme().foreground),
                )
                .child(button(Variant::Ghost, Size::Sm, l("Cancel")).on_press(move || review.stop_picking_skip()))
        },
    )
}

/// The search for ads: while it runs, and what it found, to skip or not.
fn ad_strip(review: Review) -> impl IntoElement {
    let scan = move || review.job_with(|job| job.as_ref().map(|job| job.ad_scan.clone()).unwrap_or_default());
    let visible = move || !scan().is_idle();
    when(visible, move || {
        let running = move || scan().status == AiGenerationStatus::Generating;
        let found = move || scan().found.len();
        let length = move || {
            let scan = scan();
            review.job_with(|job| {
                let document = job.as_ref()?.document()?;
                Some(
                    scan.found
                        .iter()
                        .filter_map(|finding| listenook_core::ai::ads::locate(finding, &document))
                        .map(|(first, last)| document.span_ms(first, last))
                        .sum::<i64>(),
                )
            })
        };
        view()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_3()
            .px(px(ui::PAGE_INSET))
            .py_2()
            .border_b_1()
            .border_color(|| theme().border)
            .bg(|| theme().muted)
            .test_id("ad-strip")
            .child(ui::icon(Icon::Scissors, 14.0).text_color(|| theme().muted_foreground))
            .child(
                text(move || -> SharedString {
                    let scan = scan();
                    match scan.status {
                        AiGenerationStatus::Generating if scan.total_chunks > 1 => {
                            format!("{} {}/{}", tr("Looking for ads…"), scan.completed_chunks, scan.total_chunks).into()
                        }
                        AiGenerationStatus::Generating => tr("Looking for ads…"),
                        AiGenerationStatus::Failed => {
                            scan.error_code.as_deref().map(error_text).unwrap_or_else(|| tr("Something went wrong."))
                        }
                        _ if scan.found.is_empty() => tr("No ads found."),
                        _ => format!(
                            "{} {} · {}",
                            tr("Ads found:"),
                            scan.found.len(),
                            listenook_core::format::shown(listenook_core::format::Shown::Clock(
                                length().unwrap_or_default()
                            ))
                        )
                        .into(),
                    }
                })
                .text_sm()
                .text_color(|| theme().foreground),
            )
            .child(when(running, move || {
                progress_bar(move || {
                    let scan = scan();
                    (scan.total_chunks > 1).then(|| scan.completed_chunks as f32 / scan.total_chunks as f32)
                })
                .flex_1()
            }))
            .child(view().flex_1())
            .child(
                when(running, move || {
                    button(Variant::Ghost, Size::Sm, l("Cancel")).on_press(move || ai::cancel_ad_scan(&review.id()))
                })
                .otherwise(move || {
                    view()
                        .flex_row()
                        .gap_2()
                        .child(when(
                            move || found() > 0,
                            move || {
                                button(Variant::Primary, Size::Sm, l("Skip them")).on_press(move || review.skip_found())
                            },
                        ))
                        .child(
                            button(
                                Variant::Ghost,
                                Size::Sm,
                                move || {
                                    if found() > 0 { tr("Keep them") } else { tr("Dismiss") }
                                },
                            )
                            .on_press(move || review.forget_found()),
                        )
                }),
            )
    })
}

fn transport(review: Review, hud: Signal<bool>) -> impl IntoElement {
    let active = move || !review.is_paused() || review.waiting.get();
    let variant = move |picture: bool| if picture { Variant::Picture } else { Variant::Ghost };
    let on_track = computed(move || track_position(review.position_ms.get(), review.duration_ms.get()));
    let second = computed(move || review.position_ms.get() / 1000 * 1000);
    let position = move |picture: bool| {
        (if picture { ui::slider_on_picture } else { ui::slider })(
            tr("Position"),
            move || review.scrub.get().unwrap_or_else(|| on_track.get()) as f64,
            move || review.duration_ms.get() as f64,
            move |value| review.scrub_to(Some(value as i64)),
            move |value| {
                review.seek(value as i64);
                review.scrub_to(None);
            },
        )
        .flex_1()
    };
    let skip = move |size: Size, picture: bool, sentences: bool| {
        let (back, back_name, on, on_name) = if sentences {
            (Icon::SkipBack, "Previous sentence", Icon::SkipForward, "Next sentence")
        } else {
            (Icon::Rewind, "Back 15 seconds", Icon::FastForward, "Forward 30 seconds")
        };
        view()
            .flex_row()
            .items_center()
            .gap_3()
            .child(ui::IconButtonAs {
                variant: variant(picture),
                glyph: back,
                name: tr(back_name),
                size,
                on_press: move || review.step(-1),
            })
            .child(
                toggle_icon_button(
                    move || if active() { Icon::Pause } else { Icon::Play },
                    move || if active() { tr("Pause playback") } else { tr("Play") },
                    variant(picture),
                    size,
                )
                .on_press(move || review.toggle_play()),
            )
            .child(ui::IconButtonAs {
                variant: variant(picture),
                glyph: on,
                name: tr(on_name),
                size,
                on_press: move || review.step(1),
            })
    };
    let on_picture = |time: Text, picture: bool| {
        if picture { time.text_color(|| theme().foreground.dark.opacity(0.8)) } else { time }
    };
    let at =
        move |picture: bool| on_picture(time_text(move || review.scrub.get().unwrap_or_else(|| second.get())), picture);
    let length = move |picture: bool| on_picture(time_text(move || review.duration_ms.get()), picture);
    let repeat = move |picture: bool| ui::ToggleButton {
        variant: variant(picture),
        glyph: Icon::Repeat,
        name: tr("Repeat all"),
        size: Size::Sm,
        on: move || review.looping.get(),
        on_press: move || review.toggle_looping(),
    };
    let sleep = move |picture: bool| sleep_menu(variant(picture), "When this recording ends");
    let rate = move |picture: bool| {
        rate_menu(
            variant(picture),
            move || review.rate.get(),
            move |rate| {
                review.set_rate(rate);
                store().act(crate::state::Action::SaveRate("playback_rate", rate));
            },
        )
    };
    let frame = stored(current_window());
    let screen = move |picture: bool| {
        when(
            move || review.has_video,
            move || {
                if picture {
                    ui::IconButtonAs {
                        variant: Variant::Picture,
                        glyph: Icon::Minimize,
                        name: tr("Exit full screen"),
                        size: Size::Sm,
                        on_press: move || set_fullscreen(review, frame, false),
                    }
                    .into_element()
                } else {
                    IconButton {
                        glyph: Icon::Maximize,
                        name: tr("Full screen"),
                        size: Size::Sm,
                        on_press: move || set_fullscreen(review, frame, true),
                    }
                    .into_element()
                }
            },
        )
    };
    let wide = move |picture: bool, sentences: bool| {
        view()
            .h(px(48.0))
            .flex_row()
            .items_center()
            .gap_3()
            .child(skip(Size::Sm, picture, sentences))
            .child(at(picture))
            .child(position(picture))
            .child(length(picture))
            .child(repeat(picture))
            .child(rate(picture))
            .child(sleep(picture))
            .child(screen(picture))
    };
    let narrow = move |picture: bool, sentences: bool| {
        view()
            .child(
                view()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .pt_3()
                    .child(at(picture))
                    .child(position(picture))
                    .child(length(picture)),
            )
            .child(
                view()
                    .h(px(56.0))
                    .flex_row()
                    .items_center()
                    // Each side keeps its share, but never less than its
                    // buttons need: a running countdown can push the transport
                    // over rather than overlap it.
                    .child(
                        view()
                            .flex_1()
                            .min_w(Length::Auto)
                            .flex_row()
                            .items_center()
                            .gap_1()
                            .child(rate(picture))
                            .child(sleep(picture)),
                    )
                    .child(skip(Size::Md, picture, sentences))
                    .child(
                        view()
                            .flex_1()
                            .min_w(Length::Auto)
                            .flex_row()
                            .items_center()
                            .justify_end()
                            .gap_1()
                            .child(repeat(picture))
                            .child(screen(picture)),
                    ),
            )
    };
    let layout = computed(move || (crate::pages::chrome::page_narrow(), review.fullscreen.get(), review.has_text()));
    view()
        .flex_shrink_0()
        .px(px(ui::PAGE_INSET))
        .border_color(|| theme().border)
        .bg(move || if review.fullscreen.get() { theme().card.opacity(0.0) } else { theme().card })
        .style_when(move || review.fullscreen.get(), |s| tokens::surface(tokens::Surface::Glass, s))
        .transition_opacity()
        .duration(motion::BASE)
        .style_with(move |s| {
            if review.fullscreen.get() {
                let edge = safe_area();
                s.absolute()
                    .left(px(16.0 + edge.left.0))
                    .right(px(16.0 + edge.right.0))
                    .bottom(px(16.0 + edge.bottom.0))
                    .rounded(|| tokens::corner(tokens::Corner::Large))
                    .border_1()
                    .border_color(|| theme().foreground.dark.opacity(0.16))
                    .shadow_xl()
                    .opacity(if hud.get() { 1.0 } else { 0.0 })
            } else {
                s.border_t_1()
            }
        })
        .child(dynamic(move || {
            let (tight, picture, sentences) = layout.get();
            untracked(|| {
                if tight { narrow(picture, sentences).into_element() } else { wide(picture, sentences).into_element() }
            })
        }))
}

struct Hold {
    before: Option<review::Span>,
    last: std::time::Instant,
    repeated: bool,
}

const FIRST_REPEAT: std::time::Duration =
    std::time::Duration::from_millis(if cfg!(target_os = "ios") { 650 } else { 1500 });
const REPEAT_GAP: std::time::Duration = std::time::Duration::from_millis(450);

/// Shows the reader full screen, or not. `frame`: the reader's window, kept from its render, as
/// `current_window()` in a press is nsh's invisible host, whose modes do nothing.
fn set_fullscreen(review: Review, frame: Stored<WindowRef>, on: bool) {
    if untracked(|| review.is_fullscreen()) == on {
        return;
    }
    if crate::platform::is_phone() {
        batch(|| review.set_fullscreen(on));
        return;
    }
    let window = frame.with(|frame| frame.clone());
    if on {
        batch(|| review.set_fullscreen(true));
        // The window follows once the page is drawn full screen. As macOS grows it, nsh waits
        // only a frame's time for the layout at the new size; the page's own switch made the
        // engine miss that, and the old frame showed through the animation. The store runs the
        // wait: the button pressed goes with the switch, and a task of its own would go too.
        store().run(async move {
            next_frame().await;
            next_frame().await;
            window.set_mode(WindowMode::FullScreen);
        });
    } else if cfg!(target_os = "macos") {
        // Through AppKit, not nsh's `set_mode`, which macOS answered with the window's old
        // full-screen content through its animation (longbridge/nsh#3494).
        crate::services::leave_full_screen();
    } else {
        window.set_mode(WindowMode::Normal);
    }
}

fn subtitle(review: Review, hud: Signal<bool>) -> impl IntoElement {
    let index = move || review.spoken();
    let current = move || index().and_then(|index| review.segment(index));
    let hidden = move || review.blind() && current().is_none_or(|segment| !review.unveiled(&segment.id));
    let words = computed(move || {
        index().and_then(|index| review.words(index)).map(|words| {
            caption::tidy(&words)
                .into_iter()
                .map(|(text, start, end)| (SharedString::from(text), start, end))
                .collect::<Vec<_>>()
        })
    });
    let lines = computed(move || words.with(|words| words.as_deref().map(caption::lines).unwrap_or_default()));
    let said = computed(move || {
        if words.with(Option::is_none) {
            return None;
        }
        let position = review.position_ms.get();
        words.with(|words| words.as_ref()?.partition_point(|(_, start, _)| *start <= position).checked_sub(1))
    });
    let line = computed(move || lines.with(|lines| lines.get(caption::line_of(lines, said.get())).cloned()));
    let translated = move || current().is_some_and(|segment| segment.has_translation());
    let shows_original = move || review.mode.get() != ContentMode::Translated || !translated();
    let shows_translation = move || review.mode.get() != ContentMode::Original && translated();
    view()
        .absolute()
        .left(move || px(safe_area().left.0))
        .right(move || px(safe_area().right.0))
        .bottom(move || px(safe_area().bottom.0 + if hud.get() { 88.0 } else { 32.0 }))
        .items_center()
        .px_8()
        .child(when(
            move || current().is_some() && !hidden(),
            move || {
                view()
                    .max_w(px(960.0))
                    .px_4()
                    .py_2()
                    .gap_1()
                    .items_center()
                    .rounded(|| tokens::corner(tokens::Corner::Medium))
                    .bg(|| tokens::ink(tokens::Ink::Stage).opacity(0.7))
                    .child(when(shows_translation, move || {
                        subtitle_text(text(move || {
                            current()
                                .and_then(|segment| segment.translated_text)
                                .map(SharedString::from)
                                .unwrap_or_default()
                        }))
                    }))
                    .child(when(shows_original, move || {
                        when(
                            move || words.with(Option::is_some),
                            move || {
                                dynamic(move || {
                                    let said = said.get();
                                    let line = line.get().unwrap_or_default();
                                    untracked(|| {
                                        let spans = words.get_untracked().unwrap_or_default();
                                        let first = line.start;
                                        subtitle_text(text(""))
                                            .children(
                                                spans.into_iter().enumerate().skip(first).take(line.len()).flat_map(
                                                    |(at, (word, ..))| {
                                                        let (lead, word) =
                                                            listenook_core::transcript::local::lead_and_word(&word);
                                                        let word = text(SharedString::from(word.to_owned()));
                                                        [
                                                            text(SharedString::from(
                                                                if at == first { lead.trim_start() } else { lead }
                                                                    .to_owned(),
                                                            )),
                                                            if Some(at) == said {
                                                                word.rounded(|| tokens::corner(tokens::Corner::Small))
                                                                    .bg(|| theme().primary.opacity(0.45))
                                                            } else {
                                                                word
                                                            },
                                                        ]
                                                    },
                                                ),
                                            )
                                            .into_element()
                                    })
                                })
                            },
                        )
                        .otherwise(move || {
                            subtitle_text(text(move || {
                                current().map(|segment| SharedString::from(segment.text)).unwrap_or_default()
                            }))
                        })
                    }))
            },
        ))
}

fn subtitle_text(line: Text) -> Text {
    line.text_2xl().font_weight(FontWeight::SEMIBOLD).text_center().text_color(|| theme().foreground.dark)
}

fn translate_dialog(review: Review, open: Signal<bool>) -> impl IntoElement {
    let store = crate::state::store();
    let target = signal(SharedString::from(
        Some(store.settings().translation_preferences.target_language)
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| "en".into()),
    ));
    let replace = signal(false);
    let configured = move || store.ai_ready();
    Modal {
        open,
        title: l("Translate"),
        width: 420.0,
        content: move || {
            view()
                .gap_4()
                .child(field(
                    l("Target language"),
                    select(
                        "Target language",
                        TRANSLATION_LANGUAGES.iter().map(|(code, name)| ((*code).into(), (*name).into())).collect(),
                        move || target.get(),
                        move |value| target.set(value),
                    ),
                ))
                .child(when(
                    move || has_translation(review),
                    move || {
                        checkbox(l("Replace existing translations"), move || replace.get(), move |on| replace.set(on))
                    },
                ))
                .child(
                    when(configured, move || {
                        hint(move || -> SharedString {
                            format!("{} {}", tr("Model:"), store.setting(|s| s.llm_provider_settings.model.clone()))
                                .into()
                        })
                    })
                    .otherwise(move || {
                        view()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(
                                hint(move || {
                                    tr(match store.ai_setup() {
                                        Some(AiSetup::Key) => {
                                            "Add an API key for the AI provider in Settings to translate."
                                        }
                                        Some(AiSetup::SignIn) => "Sign in with ChatGPT in Settings to translate.",
                                        _ => "Configure the AI provider in Settings before translating.",
                                    })
                                })
                                .flex_1(),
                            )
                            .child(button(Variant::Outline, Size::Sm, l("Settings")).on_press(move || {
                                open.set(false);
                                store.act(crate::state::Action::OpenSettings(SettingsTab::Ai));
                            }))
                    }),
                )
                .into_element()
        },
        actions: move || {
            ModalActions {
                open,
                cancel: l("Cancel"),
                commit: l("Translate"),
                enabled: configured,
                on_commit: move || {
                    let (id, language) = (review.id(), target.get_untracked().to_string());
                    if replace.get_untracked() {
                        store.update_document(&id, |document| {
                            for segment in &mut document.segments {
                                segment.translated_text = None;
                            }
                        });
                    }
                    store.update_settings(|s| s.translation_preferences.target_language = language.clone());
                    ai::start_translation(&id, &language, None);
                    batch(|| {
                        review.set_mode(ContentMode::Bilingual);
                        open.set(false);
                    });
                },
            }
            .into_element()
        },
    }
}

/// Puts `text` on the clipboard and says `copied` once it's there, or that it wasn't copied when
/// the clipboard refused it, whether or not there is a `copied` to say.
fn copy(text: String, copied: Option<&'static str>) {
    spawn(async move {
        match set_clipboard(text).await {
            ClipboardWrite::Failed => toast(Tone::Error, tr("Couldn’t copy. Try again.")),
            _ => {
                if let Some(copied) = copied {
                    toast(Tone::Success, tr(copied));
                }
            }
        }
    });
}

fn search_bar(review: Review) -> impl IntoElement {
    when(
        move || review.searching.get(),
        move || {
            on_key_with(
                "escape",
                KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() },
                move |_| review.set_searching(false),
            );
            let entrance = motion().entering(MotionPreset::FadeInDown);
            view()
                .bind_motion(&entrance)
                .flex_row()
                .items_center()
                .gap_2()
                .px(px(ui::PAGE_INSET))
                .py_2()
                .border_b_1()
                .border_color(|| theme().border)
                .child(ui::focused_search_field(review.query(), l("Search transcript")).flex_1())
                .child(hint(move || -> SharedString { format!("{} {}", review.shown_count(), tr("sentences")).into() }))
                .child(IconButton {
                    glyph: Icon::Close,
                    name: tr("Close"),
                    size: Size::Md,
                    on_press: move || review.set_searching(false),
                })
        },
    )
}

fn divider(review: Review, under: bool) -> impl IntoElement {
    use nsh_core::{TouchPhase, element::TouchEvent};

    use self::review::{SIDE_MAX, SIDE_MIN, VIDEO_MAX, VIDEO_MIN};
    let from = signal(None::<(f32, f32)>);
    let size = if under { review.video_height } else { review.side_width };
    let handle = view().absolute();
    let handle = if under {
        handle.left(px(0.0)).right(px(0.0)).bottom(px(0.0)).h(px(8.0)).cursor(Cursor::RowResize)
    } else {
        handle.left(px(0.0)).top(px(0.0)).bottom(px(0.0)).w(px(8.0)).cursor(Cursor::ColResize)
    };
    handle
        .transition_colors()
        .duration(motion::FAST)
        .bg(move || theme().primary.opacity(if from.get().is_some() { 0.4 } else { 0.0 }))
        .hover(|s| s.bg(|| theme().primary.opacity(0.25)))
        .on_touch(move |event: &TouchEvent| {
            let Some(point) = event.points.iter().find(|point| point.changed) else {
                return;
            };
            let at = if under { point.page.y.0 } else { point.page.x.0 };
            match event.phase {
                TouchPhase::Start => from.set(Some((at, size.get_untracked()))),
                TouchPhase::Move => {
                    if let Some((start, before)) = from.get_untracked() {
                        size.set(if under {
                            (before + at - start).clamp(VIDEO_MIN, VIDEO_MAX)
                        } else {
                            (before + start - at).clamp(SIDE_MIN, SIDE_MAX)
                        });
                    }
                }
                TouchPhase::End | TouchPhase::Cancel => {
                    from.set(None);
                    let kept = f64::from(size.get_untracked().round());
                    let key = if under { "reader_video_height" } else { "reader_side_width" };
                    crate::state::store().update_settings(|s| {
                        s.extra.insert(key.into(), kept.into());
                    });
                }
            }
        })
}
