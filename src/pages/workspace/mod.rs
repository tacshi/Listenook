mod brief;
mod practice;
mod review;
mod transcript;

use listenook_core::{ContentMode, ExportOptions, Segment, TRANSLATION_LANGUAGES, TranslationStatus, caption, export};
use nsh_base::theme;
use nsh_core::{desktop::WindowMode, element::desktop::current_window, prelude::*};
use review::{Practice, Review, Side};

use super::dialogs::{JobDialog, export_dialog, rename_dialog};
use crate::{
    services::{llm, media, playable},
    shell::{rate_menu, time_text, top_bar},
    state::{error_text, l, store, tr},
    ui::{
        self, Icon, Size, Tone, Variant, button, checkbox, empty_state, field, hint, icon_button, menu, menu_action,
        menu_divider, menu_toggle, modal, modal_actions, progress_bar, select, toast, toggle_icon_button,
        tokens::{self, motion},
    },
    util::file_url,
};

pub(crate) fn reader(id: &str) -> impl IntoElement {
    let store = store();
    if untracked(|| store.job(id)).is_some_and(|job| job.has_transcript()) {
        return opened(id).into_element();
    }
    view()
        .flex_1()
        .child(top_bar())
        .child(empty_state(
            Icon::Workspace,
            l("This recording has no transcript"),
            l("Transcribe it from the Library first."),
            button(Variant::Default, Size::Md, l("Back to Library")).on_press(move || store.close_reader()),
        ))
        .into_element()
}

const PRACTICE_HEIGHT: f32 = 340.0;

fn opened(id: &str) -> impl IntoElement {
    let review = Review::new(id);
    let store = review.store;
    let (export, rename) = (JobDialog::new(), JobDialog::new());
    let translate = signal(false);
    let brief_dialog = signal(false);
    let has_video = review.has_video;
    let path = review.job.with_untracked(|job| job.as_ref().map(|job| job.source_path.clone()).unwrap_or_default());
    let source = signal(if playable::needs_help(&path) { String::new() } else { file_url(&path) });
    let waiting_for_source = signal(playable::needs_help(&path));
    if playable::needs_help(&path) {
        let job_id = review.job.with_untracked(|job| job.as_ref().map(|job| job.id.clone()).unwrap_or_default());
        if playable::made(&job_id).is_none() {
            toast(Tone::Info, tr("Preparing this recording for playback…"));
        }
        spawn(async move {
            match playable::prepare(job_id, path).await {
                Some(made) => source.set(file_url(&made.to_string_lossy())),
                None => toast(Tone::Error, tr("This recording's format cannot be played here.")),
            }
        });
    }
    let start_at = review.position_ms.get_untracked();
    let restore = move || {
        if review.fullscreen.get_untracked() {
            batch(|| {
                review.fullscreen.set(false);
                review.store.set_immersive(false);
            });
        }
    };
    let leaving = std::rc::Rc::new(std::cell::Cell::new(false));
    {
        let leaving = leaving.clone();
        current_window().on_mode_change(move |mode, _| {
            if mode != WindowMode::FullScreen && review.fullscreen.get_untracked() {
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
    on_key("space", move |_| review.toggle_play());
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
            let before = review.repeating.get_untracked();
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
        review.revealed.update(|revealed| *revealed = if revealed.is_some() { None } else { current });
    });
    on_key("mod+f", move |_| review.searching.set(true));
    on_key("e", move |_| {
        if let Some(index) = untracked(|| review.target_or_first()) {
            let translation = review.mode.get_untracked() == ContentMode::Translated
                && review.segment(index).is_some_and(|segment| segment.has_translation());
            review.edit(index, translation);
        }
    });
    on_key("escape", move |_| {
        if review.fullscreen.get_untracked() {
            set_fullscreen(review, false);
        } else if review.editing.get_untracked().is_some() {
            review.editing.set(None);
        } else if review.searching.get_untracked() {
            review.searching.set(false);
        } else {
            store.close_reader();
        }
    });
    let controls = std::rc::Rc::new(media::claim(move |command| match command {
        media::Command::Play => {
            if review.paused.get_untracked() {
                review.toggle_play();
            }
        }
        media::Command::Pause => {
            if !review.paused.get_untracked() {
                review.toggle_play();
            }
        }
        media::Command::Toggle => review.toggle_play(),
        media::Command::Next => review.step(1),
        media::Command::Previous => review.step(-1),
        media::Command::Seek(position_ms) => review.seek(position_ms),
    }));
    let beat = computed(move || review.position_ms.get() / 5000);
    effect(move || {
        beat.get();
        let title = review.job.with(|job| job.as_ref().map(|job| job.title()).unwrap_or_default());
        controls.publish(Some(media::Now {
            title,
            artist: "Listenook".into(),
            position_ms: review.position_ms.get_untracked(),
            duration_ms: review.duration_ms.get(),
            playing: !review.paused.get(),
            rate: review.rate.get(),
        }));
    });
    let last = std::rc::Rc::new(std::cell::Cell::new((review.position_ms.get_untracked(), 0_i64, false)));
    {
        let last = last.clone();
        effect(move || last.set((review.position_ms.get(), review.duration_ms.get(), review.fullscreen.get())));
    }
    let remember = move |job_id: &str, position: i64, duration: i64| {
        let resume = position > 3000 && (duration <= 0 || position < duration - 3000);
        store.update_settings(|settings| {
            if resume {
                settings.playback_positions_ms.insert(job_id.to_owned(), position);
            } else {
                settings.playback_positions_ms.remove(job_id);
            }
        });
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
        let (position, duration, fullscreen) = last.get();
        remember(&job_id, position, duration);
        if fullscreen {
            store.set_immersive(false);
            current_window().set_mode(WindowMode::Normal);
        }
    });
    let media = video(move || source.get())
        .element_ref(&review.player)
        .paused(move || review.paused.get())
        .rate(move || review.rate.get())
        .audio_session(|| nsh_core::AudioSession::Playback)
        .progress_interval(50.0)
        .on_load(move |info: &VideoInfo| {
            review.duration_ms.set((info.duration * 1000.0) as i64);
            if start_at > 0 {
                review.player.seek(start_at as f64 / 1000.0);
            }
        })
        .on_progress(move |progress: &VideoProgress| {
            review.on_progress((progress.current_time * 1000.0) as i64, (progress.duration * 1000.0) as i64);
        })
        .repeat(move || review.looping.get())
        .on_end(move || {
            if !review.looping.get_untracked() {
                review.paused.set(true);
            }
        })
        .on_error(move |_: &str| {
            if waiting_for_source.get_untracked() {
                waiting_for_source.set(false);
            } else {
                toast(Tone::Error, error_text("missing_source"));
            }
        });

    let side = move || review.side.get();
    let narrow = move || crate::shell::page_stacks() && side() != Side::None && !review.fullscreen.get();
    let on_top = move || {
        has_video && side() == Side::Video && !review.fullscreen.get() && (review.video_on_top.get() || narrow())
    };
    let stacked = move || on_top() || narrow();
    let typing = move || crate::platform::is_phone() && keyboard_height().0 > 0.0;
    let hud = signal(true);
    let wait = std::rc::Rc::new(std::cell::RefCell::new(None::<Spawned<()>>));
    let wake = move || {
        if !review.fullscreen.get_untracked() {
            return;
        }
        hud.set(true);
        let later = set_timeout(std::time::Duration::from_millis(2500), move || {
            if !review.paused.get_untracked() {
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
            let _ = (review.fullscreen.get(), review.paused.get());
            hud.set(true);
            untracked(&wake);
        }
    });
    let side_column = view()
        .style_with(move |s| match (review.fullscreen.get(), side()) {
            (true, _) => s.flex_1(),
            (false, Side::None) => s.w(px(0.0)),
            (false, Side::Video) if narrow() => s.w_full().h(px(crate::shell::page_width() * 9.0 / 16.0)).border_b_1(),
            (false, Side::Practice) if narrow() => {
                s.w_full().h(px((window().height.0 * 0.45).min(PRACTICE_HEIGHT))).border_t_1()
            }
            (false, _) if narrow() => s.w_full().h(px(window().height.0 * 0.45)).border_t_1(),
            (false, _) if on_top() => s.w_full().h(px(review.video_height.get())).border_b_1(),
            (false, _) => s.w(px(review.side_width.get())).border_l_1(),
        })
        .flex_shrink_0()
        .overflow_hidden()
        .border_color(|| theme().border)
        .bg(move || if review.fullscreen.get() { tokens::stage() } else { theme().card })
        .child(
            view()
                .style_with(move |s| {
                    if review.fullscreen.get() || stacked() { s.w_full() } else { s.w(px(review.side_width.get())) }
                })
                .flex_1()
                .child(
                    view()
                        .bg(move || if review.fullscreen.get() { tokens::stage() } else { theme().muted })
                        .style_with(move |s| match (has_video, side(), review.fullscreen.get()) {
                            (true, Side::Video, _) | (true, _, true) => s.flex_1(),
                            (true, _, false) if narrow() || typing() => s.h(px(1.0)).opacity(0.0),
                            (true, _, false) => s.h(px(review.side_width.get() * 9.0 / 16.0)),
                            (false, ..) => s.h(px(1.0)).opacity(0.0),
                        })
                        .child(media.flex_1())
                        .child(when(move || review.fullscreen.get(), move || subtitle(review, hud)))
                        .child(when(
                            move || {
                                crate::platform::is_phone()
                                    && crate::shell::page_narrow()
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
                                    .gradient_from(|| tokens::stage().opacity(0.6))
                                    .gradient_to(|| tokens::stage().opacity(0.0))
                                    .opacity(move || if review.paused.get() { 1.0_f32 } else { 0.0 })
                                    .transition_opacity()
                                    .duration(motion::BASE)
                                    .child(
                                        text(move || {
                                            review.job.with(|job| {
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
                        .child(when(move || review.fullscreen.get() && crate::platform::is_phone(), {
                            let wake = wake.clone();
                            move || {
                                let wake = wake.clone();
                                view()
                                    .absolute()
                                    .inset_0()
                                    .label("Controls")
                                    .on_press(move || if hud.get_untracked() { hud.set(false) } else { wake() })
                            }
                        })),
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
        .on_mouse_move(move |_: &MouseEvent| wake())
        .style_with(move |s| if review.fullscreen.get() && !hud.get() { s.cursor(Cursor::None) } else { s })
        .child(when(move || !review.fullscreen.get(), move || header(review, export, rename, translate)))
        .child(when(move || !review.fullscreen.get(), move || translation_strip(review)))
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
                        .child(transcript::transcript(review)),
                )
                .child(side_column.child(when(
                    move || !narrow(),
                    move || when(on_top, move || divider(review, true)).otherwise(move || divider(review, false)),
                ))),
        )
        .child(transport(review, hud))
        .child(export_dialog(export))
        .child(rename_dialog(rename))
        .child(translate_dialog(review, translate))
        .child(brief::generate_dialog(review, brief_dialog))
        .child(brief::edit_dialog(review))
}

fn has_translation(review: Review) -> bool {
    review.job.with(|job| {
        job.as_ref()
            .and_then(|job| job.document.as_ref())
            .is_some_and(|d| d.segments.iter().any(Segment::has_translation))
    })
}

fn side_toggle(review: Review, side: Side, glyph: Icon, name: &'static str) -> impl IntoElement {
    let on = move || review.side.get() == side;
    view().window_drag(false).child(ui::toggle_button(Variant::Ghost, glyph, tr(name), Size::Sm, on, move || {
        let closing = untracked(on);
        if side == Side::Video {
            review.video_wanted.set(!closing);
        }
        let next = match (closing, side) {
            (false, _) => side,
            (true, Side::Video) => Side::None,
            (true, _) if review.has_video && review.video_wanted.get_untracked() => Side::Video,
            (true, _) => Side::None,
        };
        match next {
            Side::Practice => practice::start(review, Practice::Mimic),
            _ => {
                if review.side.get_untracked() == Side::Practice {
                    practice::stop(review);
                }
                review.side.set(next);
            }
        }
    }))
}

fn header(review: Review, export: JobDialog, rename: JobDialog, translate: Signal<bool>) -> AnyElement {
    let store = review.store;
    let title =
        move || review.job.with(|job| job.as_ref().map(|job| SharedString::from(job.title())).unwrap_or_default());
    let mode_label = move || match review.mode.get() {
        ContentMode::Original => tr("Original"),
        ContentMode::Translated => tr("Translated"),
        ContentMode::Bilingual => tr("Bilingual"),
    };
    let mode_item = move |mode: ContentMode, label: &'static str| {
        ui::menu_choice(l(label), move || review.mode.get() == mode, move || review.mode.set(mode))
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
            .child(
                view()
                    .window_drag(false)
                    .child(icon_button(Icon::ChevronLeft, tr("Back"), Size::Sm, move || store.close_reader())),
            )
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
            .style_with(tokens::bar_glass)
    } else {
        top_bar().child(lead)
    };
    let bar = base
        .child(when(
            move || has_translation(review),
            move || {
                view().window_drag(false).child(
                    menu(ui::icon_text_button(Variant::Ghost, Size::Sm, Icon::Languages, mode_label))
                        .child(mode_item(ContentMode::Original, "Original"))
                        .child(mode_item(ContentMode::Translated, "Translated"))
                        .child(mode_item(ContentMode::Bilingual, "Bilingual")),
                )
            },
        ))
        .child(view().window_drag(false).child(icon_button(
            Icon::Search,
            tr("Search transcript"),
            Size::Sm,
            move || review.searching.set(!review.searching.get_untracked()),
        )))
        .child(side_toggle(review, Side::Practice, Icon::Practice, "Practice"))
        .child(side_toggle(review, Side::Brief, Icon::Sparkles, "AI Brief"))
        .child(when(move || review.has_video, move || side_toggle(review, Side::Video, Icon::Film, "Video")))
        .child(when(
            move || review.has_video && review.side.get() == Side::Video && !crate::shell::page_stacks(),
            move || {
                view().window_drag(false).child(dynamic(move || {
                    let on_top = review.video_on_top.get();
                    icon_button(
                        if on_top { Icon::Columns } else { Icon::Rows },
                        tr(if on_top { "Video at the side" } else { "Video on top" }),
                        Size::Sm,
                        move || {
                            review.video_on_top.set(!on_top);
                            review.store.update_settings(|s| {
                                s.extra.insert("reader_video_on_top".into(), (!on_top).into());
                            });
                        },
                    )
                }))
            },
        ))
        .child(view().window_drag(false).child({
            let open = signal(false);
            ui::menu_with(open, ui::menu_trigger(Icon::More, tr("More actions"), Size::Sm, open))
                .child(when(
                    move || !(review.side.get() == Side::Practice && review.practice.get() == Practice::Dictation),
                    move || {
                        menu_toggle(
                            l("Blind listening"),
                            move || review.blind_listening(),
                            move || {
                                store.update_settings(|s| s.blind_listening_enabled = !s.blind_listening_enabled);
                                review.revealed.set(None);
                            },
                        )
                    },
                ))
                .child(menu_toggle(
                    l("Speaker labels"),
                    move || store.setting(|s| s.show_speakers),
                    move || store.update_settings(|s| s.show_speakers = !s.show_speakers),
                ))
                .child(menu_toggle(
                    l("Timestamps"),
                    move || store.setting(|s| s.show_timestamps),
                    move || store.update_settings(|s| s.show_timestamps = !s.show_timestamps),
                ))
                .child(menu_divider())
                .child(menu_action(Icon::Languages, l("Translate…"), move || translate.set(true)))
                .child(menu_action(Icon::Copy, l("Copy transcript"), move || {
                    if let Some(job) = store.job_now(&review.id()) {
                        let settings = store.settings();
                        let options = ExportOptions {
                            show_speakers: settings.show_speakers,
                            show_timestamps: settings.show_timestamps,
                            content_mode: review.mode.get_untracked(),
                            locale_code: store.lang().code().into(),
                            ..ExportOptions::default()
                        };
                        set_clipboard(export::export_transcript(&job, &options));
                        toast(Tone::Success, tr("Transcript copied"));
                    }
                }))
                .child(menu_action(Icon::Export, l("Export…"), move || export.show(&review.id())))
                .child(menu_action(Icon::Pencil, l("Rename…"), move || rename.show(&review.id())))
        }));
    if !touch {
        return bar.into_element();
    }
    let tight = crate::shell::page_narrow;
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
                .child(ui::bar_button(Icon::Back, tr("Back"), move || store.close_reader()))
                .child(when(
                    || !crate::platform::compact(),
                    move || ui::bar_button(Icon::Sidebar, tr("Sidebar"), move || store.toggle_sidebar()),
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

fn translation_strip(review: Review) -> impl IntoElement {
    let state =
        move || review.job.with(|job| job.as_ref().map(|job| job.translation_state.clone()).unwrap_or_default());
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
                    button(Variant::Ghost, Size::Sm, l("Cancel"))
                        .on_press(move || llm::cancel_translation(&review.id()))
                })
                .otherwise(move || {
                    view().flex_1().items_end().child(button(Variant::Ghost, Size::Sm, l("Dismiss")).on_press(
                        move || {
                            store().update_job(&review.id(), |job| {
                                job.translation_state.status = TranslationStatus::Idle;
                                job.translation_state.error_code = None;
                            });
                        },
                    ))
                }),
            )
    })
}

fn transport(review: Review, hud: Signal<bool>) -> impl IntoElement {
    let dragging = signal(None::<f64>);
    let active = move || !review.paused.get() || review.waiting.get();
    let variant = move |picture: bool| if picture { Variant::Picture } else { Variant::Ghost };
    let position = move |picture: bool| {
        (if picture { ui::slider_on_picture } else { ui::slider })(
            "Position",
            move || dragging.get().unwrap_or(review.position_ms.get() as f64),
            move || review.duration_ms.get() as f64,
            move |value| dragging.set(Some(value)),
            move |value| {
                review.seek(value as i64);
                dragging.set(None);
            },
        )
        .flex_1()
    };
    let skip = move |size: Size, picture: bool| {
        view()
            .flex_row()
            .items_center()
            .gap_3()
            .child(ui::icon_button_as(variant(picture), Icon::SkipBack, tr("Previous sentence"), size, move || {
                review.step(-1)
            }))
            .child(
                toggle_icon_button(
                    move || if active() { Icon::Pause } else { Icon::Play },
                    move || if active() { tr("Pause") } else { tr("Play") },
                    variant(picture),
                    size,
                )
                .on_press(move || review.toggle_play()),
            )
            .child(ui::icon_button_as(variant(picture), Icon::SkipForward, tr("Next sentence"), size, move || {
                review.step(1)
            }))
    };
    let on_picture = |time: Text, picture: bool| {
        if picture { time.text_color(|| theme().foreground.dark.opacity(0.8)) } else { time }
    };
    let at = move |picture: bool| {
        on_picture(time_text(move || dragging.get().map_or(review.position_ms.get(), |ms| ms as i64)), picture)
    };
    let length = move |picture: bool| on_picture(time_text(move || review.duration_ms.get()), picture);
    let repeat = move |picture: bool| {
        ui::toggle_button(
            variant(picture),
            Icon::Repeat,
            tr("Repeat all"),
            Size::Sm,
            move || review.looping.get(),
            move || review.looping.set(!review.looping.get_untracked()),
        )
    };
    let rate = move |picture: bool| {
        rate_menu(
            variant(picture),
            move || review.rate.get(),
            move |rate| {
                review.rate.set(rate);
                store().save_rate("playback_rate", rate);
            },
        )
    };
    let screen = move |picture: bool| {
        when(
            move || review.has_video,
            move || {
                if picture {
                    ui::icon_button_as(Variant::Picture, Icon::Minimize, tr("Exit full screen"), Size::Sm, move || {
                        set_fullscreen(review, false)
                    })
                } else {
                    icon_button(Icon::Maximize, tr("Full screen"), Size::Sm, move || set_fullscreen(review, true))
                }
            },
        )
    };
    let wide = move |picture: bool| {
        view()
            .h(px(48.0))
            .flex_row()
            .items_center()
            .gap_3()
            .child(skip(Size::Sm, picture))
            .child(at(picture))
            .child(position(picture))
            .child(length(picture))
            .child(repeat(picture))
            .child(rate(picture))
            .child(screen(picture))
    };
    let narrow = move |picture: bool| {
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
                    .child(view().flex_1().flex_row().items_center().child(rate(picture)))
                    .child(skip(Size::Md, picture))
                    .child(
                        view()
                            .flex_1()
                            .flex_row()
                            .items_center()
                            .justify_end()
                            .gap_1()
                            .child(repeat(picture))
                            .child(screen(picture)),
                    ),
            )
    };
    let layout = computed(move || (crate::shell::page_narrow(), review.fullscreen.get()));
    view()
        .flex_shrink_0()
        .px(px(ui::PAGE_INSET))
        .border_color(|| theme().border)
        .bg(move || if review.fullscreen.get() { theme().card.opacity(0.0) } else { theme().card })
        .style_when(move || review.fullscreen.get(), tokens::glass)
        .transition_opacity()
        .duration(motion::BASE)
        .style_with(move |s| {
            if review.fullscreen.get() {
                s.absolute()
                    .left(px(16.0))
                    .right(px(16.0))
                    .bottom(px(16.0))
                    .rounded(tokens::radius_lg)
                    .border_1()
                    .border_color(|| theme().foreground.dark.opacity(0.16))
                    .shadow_xl()
                    .opacity(if hud.get() { 1.0 } else { 0.0 })
            } else {
                s.border_t_1()
            }
        })
        .child(dynamic(move || {
            let (tight, picture) = layout.get();
            untracked(|| if tight { narrow(picture).into_element() } else { wide(picture).into_element() })
        }))
}

struct Hold {
    before: Option<String>,
    last: std::time::Instant,
    repeated: bool,
}

const FIRST_REPEAT: std::time::Duration =
    std::time::Duration::from_millis(if cfg!(target_os = "ios") { 650 } else { 1500 });
const REPEAT_GAP: std::time::Duration = std::time::Duration::from_millis(450);

fn set_fullscreen(review: Review, on: bool) {
    if review.fullscreen.get_untracked() == on {
        return;
    }
    if crate::platform::is_phone() {
        batch(|| {
            review.fullscreen.set(on);
            review.store.set_immersive(on);
        });
        return;
    }
    if on {
        batch(|| {
            review.fullscreen.set(true);
            review.store.set_immersive(true);
        });
        current_window().set_mode(WindowMode::FullScreen);
    } else {
        current_window().set_mode(WindowMode::Normal);
    }
}

fn subtitle(review: Review, hud: Signal<bool>) -> impl IntoElement {
    let index = move || review.target();
    let current = move || index().and_then(|index| review.segment(index));
    let hidden = move || review.blind() && current().is_none_or(|segment| review.revealed.get() != Some(segment.id));
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
        let position = review.position_ms.get();
        words.with(|words| words.as_ref()?.partition_point(|(_, start, _)| *start <= position).checked_sub(1))
    });
    let line = computed(move || lines.with(|lines| lines.get(caption::line_of(lines, said.get())).cloned()));
    let translated = move || current().is_some_and(|segment| segment.has_translation());
    let shows_original = move || review.mode.get() != ContentMode::Translated || !translated();
    let shows_translation = move || review.mode.get() != ContentMode::Original && translated();
    view()
        .absolute()
        .left(px(0.0))
        .right(px(0.0))
        .bottom(move || px(if hud.get() { 88.0 } else { 32.0 }))
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
                    .rounded(tokens::radius)
                    .bg(|| tokens::stage().opacity(0.7))
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
                                                        let (lead, word) = listenook_core::local::lead_and_word(&word);
                                                        let word = text(SharedString::from(word.to_owned()));
                                                        [
                                                            text(SharedString::from(
                                                                if at == first { lead.trim_start() } else { lead }
                                                                    .to_owned(),
                                                            )),
                                                            if Some(at) == said {
                                                                word.rounded(tokens::radius_sm)
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
    let store = review.store;
    let target = signal(SharedString::from(
        Some(store.settings().translation_preferences.target_language)
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| "en".into()),
    ));
    let replace = signal(false);
    let configured = move || store.setting(|s| s.llm_provider_settings.validate().is_none());
    modal(
        open,
        l("Translate"),
        420.0,
        move || {
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
                    .otherwise(|| hint(l("Configure the AI provider in Settings before translating."))),
                )
                .into_element()
        },
        move || {
            modal_actions(open, l("Cancel"), l("Translate"), configured, move || {
                let (id, language) = (review.id(), target.get_untracked().to_string());
                if replace.get_untracked() {
                    store.update_document(&id, |document| {
                        for segment in &mut document.segments {
                            segment.translated_text = None;
                        }
                    });
                }
                store.update_settings(|s| s.translation_preferences.target_language = language.clone());
                llm::start_translation(&id, &language, None);
                batch(|| {
                    review.mode.set(ContentMode::Bilingual);
                    open.set(false);
                });
            })
        },
    )
}

fn search_bar(review: Review) -> impl IntoElement {
    when(
        move || review.searching.get(),
        move || {
            on_key_with(
                "escape",
                KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() },
                move |_| review.searching.set(false),
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
                .child(ui::focused_search_field(review.query, l("Search transcript")).flex_1())
                .child(hint(move || -> SharedString {
                    format!("{} {}", review.shown.with(Vec::len), tr("sentences")).into()
                }))
                .child(icon_button(Icon::Close, tr("Close"), Size::Md, move || review.searching.set(false)))
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
                    review.store.update_settings(|s| {
                        s.extra.insert(key.into(), kept.into());
                    });
                }
            }
        })
}
