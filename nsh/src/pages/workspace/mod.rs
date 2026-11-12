//! The reader: one recording's transcript in a reading column, its media on
//! one transport, and a side panel for practice, the AI Brief or the video.

mod brief;
mod practice;
mod review;
mod transcript;

use listenook_core::{ContentMode, ExportOptions, Segment, TRANSLATION_LANGUAGES, TranslationStatus, export};
use nsh_base::theme;
use nsh_core::{desktop::WindowMode, element::desktop::current_window, prelude::*};
use review::{Practice, Review, Side};

use super::dialogs::{JobDialog, export_dialog, rename_dialog};
use crate::{
    services::{llm, media, playable},
    shell::{rate_menu, time_text, top_bar},
    state::{error_text, l, store, tr},
    ui::{
        self, Icon, Size, Tone, Variant, button, checkbox, empty_state, field, hint, icon, icon_button, menu,
        menu_action, menu_divider, menu_toggle, modal, modal_actions, progress_bar, select, toast, toggle_icon_button,
        tokens::{self, motion},
    },
    util::file_url,
};

/// The reader for job `id`, or a way back when it has no transcript.
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

/// The height of the practice panel under the transcript: its controls
/// and the sentence being practiced.
const PRACTICE_HEIGHT: f32 = 340.0;

fn opened(id: &str) -> impl IntoElement {
    let review = Review::new(id);
    let store = review.store;
    let (export, rename) = (JobDialog::new(), JobDialog::new());
    let translate = signal(false);
    let brief_dialog = signal(false);
    let has_video = review.has_video;
    let path = review.job.with_untracked(|job| job.as_ref().map(|job| job.source_path.clone()).unwrap_or_default());
    // A file the player cannot open is made into one it can, once; until
    // then there is nothing to load.
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
    // The page comes back when the window has left full screen, however
    // it was asked to (the button, Escape, the system's own control), and
    // only once the window has finished shrinking: until then the picture
    // alone shrinks with it.
    let restore = move || {
        if review.fullscreen.get_untracked() {
            batch(|| {
                review.fullscreen.set(false);
                review.store.set_immersive(false);
            });
        }
    };
    // Kept outside the signals: the wait below may outlive the reader.
    let leaving = std::rc::Rc::new(std::cell::Cell::new(false));
    {
        let leaving = leaving.clone();
        current_window().on_mode_change(move |mode, _| {
            if mode != WindowMode::FullScreen && review.fullscreen.get_untracked() {
                leaving.set(true);
                // Should the window's new size never be told.
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
    // R loops the current sentence while it is held, and lets go of it
    // when the key is released. A key's release is not told: a held key
    // repeats, so the hold lasts while its repeats keep coming.
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
                    // Gone: the reader closed, and its signals with it.
                    let Some((quiet, repeated)) =
                        held.borrow().as_ref().map(|hold| (hold.last.elapsed(), hold.repeated))
                    else {
                        return;
                    };
                    // The first repeat of a held key takes longer to come than the rest.
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
    // The media keys and Now Playing follow the recording being read.
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
    // Now Playing counts on by itself: it is told again every five
    // seconds, and at once when anything else changes.
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
    // Where playback is, kept outside the signals: when the reader closes
    // they are gone before this last save runs.
    let last = std::rc::Rc::new(std::cell::Cell::new((review.position_ms.get_untracked(), 0_i64, false)));
    {
        let last = last.clone();
        effect(move || last.set((review.position_ms.get(), review.duration_ms.get(), review.fullscreen.get())));
    }
    // A recording heard to its end starts over next time.
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
    // Kept while playing too: quitting the app runs no cleanup.
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
        .on_end(move || review.paused.set(true))
        .on_error(move |_: &str| {
            // The player complains once about having nothing to load while
            // a file is being made playable: that is not a missing file.
            if waiting_for_source.get_untracked() {
                waiting_for_source.set(false);
            } else {
                toast(Tone::Error, error_text("missing_source"));
            }
        });

    // The side column is always there, so the media element is made once:
    // it is as wide as the panel showing, and the picture takes all of it
    // when the panel is the video, a band above the others, and nothing for
    // a recording without one.
    let side = move || review.side.get();
    // The video can sit above the transcript instead of beside it. The
    // other panels are lists that want height, and stay at the side.
    // In a narrow window nothing fits beside the transcript: the video is
    // always above it, and the other panels take the lower half.
    let narrow = move || crate::shell::page_stacks() && side() != Side::None && !review.fullscreen.get();
    let on_top = move || {
        has_video && side() == Side::Video && !review.fullscreen.get() && (review.video_on_top.get() || narrow())
    };
    let stacked = move || on_top() || narrow();
    // The software keyboard is up, taking half of a tablet's screen.
    let typing = move || crate::platform::is_phone() && keyboard_height().0 > 0.0;
    // In full screen the controls float over the picture, and go away
    // while it plays: moving the pointer brings them back for a while.
    let hud = signal(true);
    // The wait that puts them away; a new movement takes its place.
    let wait = std::rc::Rc::new(std::cell::RefCell::new(None::<Spawned<()>>));
    let wake = move || {
        if !review.fullscreen.get_untracked() {
            return;
        }
        hud.set(true);
        let later = set_timeout(std::time::Duration::from_millis(2500), move || {
            // Not while paused: then they are what the user is looking for.
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
            // Shown on entering full screen and whenever playback stops or starts.
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
            // Practice is a few controls: as tall as they are, not the half
            // of the page a list of notes wants.
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
                            // No room for the picture over a panel in a narrow
                            // window, nor while the keyboard is up under one:
                            // what is typed into, and its buttons, stay in sight.
                            (true, _, false) if narrow() || typing() => s.h(px(1.0)).opacity(0.0),
                            (true, _, false) => s.h(px(review.side_width.get() * 9.0 / 16.0)),
                            (false, ..) => s.h(px(1.0)).opacity(0.0),
                        })
                        .child(media.flex_1())
                        .child(when(move || review.fullscreen.get(), move || subtitle(review, hud)))
                        // A phone's bar has no room for the title: it is over
                        // the top of the picture while that is paused, and
                        // goes as it plays.
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
                                        // Light on the dark of the stage, in either theme.
                                        .text_color(|| theme().foreground.dark)
                                        .role(AccessibilityRole::Header),
                                    )
                            },
                        ))
                        // Under a finger there is no pointer to move: a tap
                        // on the picture shows the controls, or puts them away.
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
        // No pointer over a picture that is playing by itself.
        .style_with(move |s| if review.fullscreen.get() && !hud.get() { s.cursor(Cursor::None) } else { s })
        .child(when(move || !review.fullscreen.get(), move || header(review, export, rename, translate)))
        .child(when(move || !review.fullscreen.get(), move || translation_strip(review)))
        .child(
            view()
                .flex_1()
                .min_h(px(0.0))
                // The panel comes second: to the right in a row, on top
                // in a column read from its end.
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
                // The handle goes in last, over the panel's content.
                .child(side_column.child(when(
                    // A narrow window lays the panel out itself: nothing to drag.
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

/// A toolbar toggle for a side panel: lit while its panel shows.
fn side_toggle(review: Review, side: Side, glyph: Icon, name: &'static str) -> impl IntoElement {
    let on = move || review.side.get() == side;
    view()
        .rounded(tokens::radius)
        .window_drag(false)
        .transition_colors()
        .duration(motion::FAST)
        .bg(move || if on() { theme().accent } else { theme().background })
        .text_color(move || if on() { theme().primary } else { theme().foreground })
        .child(icon_button(glyph, tr(name), Size::Sm, move || {
            let closing = untracked(on);
            // The Video button says whether the picture is wanted; closing
            // Practice or the AI Brief leaves it as it was before them.
            if side == Side::Video {
                review.video_wanted.set(!closing);
            }
            let next = match (closing, side) {
                (false, _) => side,
                (true, Side::Video) => Side::None,
                (true, _) if review.has_video && review.video_wanted.get_untracked() => Side::Video,
                (true, _) => Side::None,
            };
            // No sliding into place here: the transcript's lines wrap anew
            // at its new width, and rows animated to it keep wrong heights.
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
    // On a phone or a tablet the system's header is done without (it
    // cannot be put away for a video filling the screen): a bar like it
    // stands above this one, with the way back, the sidebar's button
    // beside the sidebar, and the title.
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
    // There the tools are one capsule at the end of that bar, as the
    // system groups the buttons of its own.
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
                // The button shows the layout it changes to.
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
        .child(
            view().window_drag(false).child(
                menu(
                    view()
                        .size(px(40.0))
                        .items_center()
                        .justify_center()
                        .rounded(tokens::radius)
                        .label("More actions")
                        .hover(|s| s.bg(|| theme().accent))
                        .child(icon(Icon::More, 18.0)),
                )
                // Not while an answer is typed from hearing: that is blind
                // listening already, and the switch would change nothing.
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
                .child(menu_action(Icon::Languages, l("Translate with LLM…"), move || translate.set(true)))
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
                .child(menu_action(Icon::Pencil, l("Rename…"), move || rename.show(&review.id()))),
            ),
        );
    if !touch {
        return bar.into_element();
    }
    // One line: the way back, the sidebar's button beside the sidebar, the
    // title, the tools. A phone's page has no room for the title there:
    // it is over the picture while that is paused (see `opened`), and for
    // a recording without one, or with its picture away, a line under the
    // bar.
    let tight = crate::shell::page_narrow;
    let pictured = move || review.has_video && review.side.get() == Side::Video;
    view()
        .border_b_1()
        .border_color(|| theme().border)
        .child(
            view()
                .flex_row()
                .items_center()
                .gap(px(10.0))
                .p(px(10.0))
                .child(ui::bar_button(Icon::Back, tr("Back"), move || store.close_reader()))
                .child(when(
                    || !crate::platform::compact(),
                    move || ui::bar_button(Icon::Sidebar, tr("Sidebar"), move || store.toggle_sidebar()),
                ))
                .child(when(tight, || view().flex_1()).otherwise(move || {
                    text(title)
                        .text_size(px(17.0))
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

/// How the translation goes, while it runs or after it stopped short.
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
                // What stopped has been said: the note can be put away.
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

/// The one transport: play, sentence steps, position, repeat and speed.
fn transport(review: Review, hud: Signal<bool>) -> impl IntoElement {
    let dragging = signal(None::<f64>);
    let active = move || !review.paused.get() || review.waiting.get();
    let position = move || {
        ui::slider(
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
    // The parts, laid out one way in a wide page and another in a narrow one.
    let skip = move |size: Size| {
        view()
            .flex_row()
            .items_center()
            .gap_3()
            .child(icon_button(Icon::SkipBack, tr("Previous sentence"), size, move || review.step(-1)))
            .child(
                toggle_icon_button(
                    move || if active() { Icon::Pause } else { Icon::Play },
                    move || if active() { "Pause".into() } else { "Play".into() },
                    Variant::Ghost,
                    size,
                )
                .on_press(move || review.toggle_play()),
            )
            .child(icon_button(Icon::SkipForward, tr("Next sentence"), size, move || review.step(1)))
    };
    let at = move || time_text(move || dragging.get().map_or(review.position_ms.get(), |ms| ms as i64));
    let length = move || time_text(move || review.duration_ms.get());
    let repeat = move || {
        view()
            .rounded(tokens::radius)
            .transition_colors()
            .duration(motion::FAST)
            .bg(move || if review.repeating.get().is_some() { theme().accent } else { theme().accent.opacity(0.0) })
            .text_color(move || if review.repeating.get().is_some() { theme().primary } else { theme().foreground })
            .child(icon_button(Icon::Repeat, tr("Repeat sentence"), Size::Sm, move || {
                if let Some(index) = review.target_or_first() {
                    review.toggle_repeat(index);
                }
            }))
    };
    let rate = move || {
        rate_menu(
            move || review.rate.get(),
            move |rate| {
                review.rate.set(rate);
                store().save_rate("playback_rate", rate);
            },
        )
    };
    let screen = move || {
        when(
            move || review.has_video,
            move || {
                when(
                    move || review.fullscreen.get(),
                    move || {
                        icon_button(Icon::Minimize, tr("Exit full screen"), Size::Sm, move || {
                            set_fullscreen(review, false)
                        })
                    },
                )
                .otherwise(move || {
                    icon_button(Icon::Maximize, tr("Full screen"), Size::Sm, move || set_fullscreen(review, true))
                })
            },
        )
    };
    // A wide page: one row, the position between the times.
    let wide = move || {
        view()
            .h(px(48.0))
            .flex_row()
            .items_center()
            .gap_3()
            .child(skip(Size::Sm))
            .child(at())
            .child(position())
            .child(length())
            .child(repeat())
            .child(rate())
            .child(screen())
    };
    // A narrow one, held in a hand: the position between the times on a
    // row of its own, and under it playing in the middle, where a thumb
    // is, with the speed at one side and the rest at the other.
    let narrow = move || {
        view()
            .child(view().flex_row().items_center().gap_3().pt_3().child(at()).child(position()).child(length()))
            .child(
                view()
                    .h(px(56.0))
                    .flex_row()
                    .items_center()
                    .child(view().flex_1().flex_row().items_center().child(rate()))
                    .child(skip(Size::Md))
                    .child(
                        view().flex_1().flex_row().items_center().justify_end().gap_1().child(repeat()).child(screen()),
                    ),
            )
    };
    view()
        .flex_shrink_0()
        .px(px(ui::PAGE_INSET))
        .border_color(|| theme().border)
        // See-through over the picture.
        .bg(move || if review.fullscreen.get() { theme().card.opacity(0.0) } else { theme().card })
        .style_when(move || review.fullscreen.get(), tokens::glass)
        .transition_opacity()
        .duration(motion::BASE)
        // In full screen: a bar floating over the picture, there while wanted.
        .style_with(move |s| {
            if review.fullscreen.get() {
                s.absolute()
                    .left(px(16.0))
                    .right(px(16.0))
                    .bottom(px(16.0))
                    .rounded(tokens::radius_lg)
                    .border_1()
                    .shadow_xl()
                    .opacity(if hud.get() { 1.0 } else { 0.0 })
            } else {
                s.border_t_1()
            }
        })
        .child(when(crate::shell::page_narrow, narrow).otherwise(wide))
}

/// The R key being held: what was looping before it, and when the key
/// last said it was down.
struct Hold {
    before: Option<String>,
    last: std::time::Instant,
    repeated: bool,
}

/// How long after a key goes down its first repeat may take to come (an
/// iPad's comes after 0.4 s; a Mac's as the user set it, up to about 2 s),
/// and the longest gap between the repeats after it.
const FIRST_REPEAT: std::time::Duration =
    std::time::Duration::from_millis(if cfg!(target_os = "ios") { 650 } else { 1500 });
const REPEAT_GAP: std::time::Duration = std::time::Duration::from_millis(450);

/// Fills the window, and the screen, with the video and the sentence being
/// said; or goes back to the reader.
fn set_fullscreen(review: Review, on: bool) {
    if review.fullscreen.get_untracked() == on {
        return;
    }
    // A phone's or a tablet's window is the screen already: the picture
    // takes it, and there is no window to wait for.
    if crate::platform::is_phone() {
        batch(|| {
            review.fullscreen.set(on);
            review.store.set_immersive(on);
        });
        return;
    }
    if on {
        // The picture takes the window first, then the window the screen:
        // one thing grows, instead of the page changing as it does.
        batch(|| {
            review.fullscreen.set(true);
            review.store.set_immersive(true);
        });
        current_window().set_mode(WindowMode::FullScreen);
    } else {
        // The other way round going back: the window shrinks with the
        // picture in it, and the page returns once it has (see `reader`,
        // which hears the window leave full screen).
        current_window().set_mode(WindowMode::Normal);
    }
}

/// The sentence being said, over the bottom of the picture, with the word
/// being said marked as the transcript marks it.
fn subtitle(review: Review, hud: Signal<bool>) -> impl IntoElement {
    let index = move || review.target();
    let current = move || index().and_then(|index| review.segment(index));
    let hidden = move || review.blind() && current().is_none_or(|segment| review.revealed.get() != Some(segment.id));
    let words = computed(move || index().and_then(|index| review.words(index)));
    let said = computed(move || {
        let position = review.position_ms.get();
        words.with(|words| {
            // The last word that has started: none is passed over in a pause.
            words.as_ref()?.partition_point(|(_, start, _)| *start <= position).checked_sub(1)
        })
    });
    let translated = move || current().is_some_and(|segment| segment.has_translation());
    let shows_original = move || review.mode.get() != ContentMode::Translated || !translated();
    let shows_translation = move || review.mode.get() != ContentMode::Original && translated();
    // Clear of the controls while they show.
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
                                    untracked(|| {
                                        let spans = words.get_untracked().unwrap_or_default();
                                        subtitle_text(text(""))
                                            .children(spans.into_iter().enumerate().flat_map(|(at, (word, ..))| {
                                                // The mark is on the word alone, not on the
                                                // space or the quote before it.
                                                let (lead, word) = listenook_core::local::lead_and_word(&word);
                                                let word = text(SharedString::from(word.to_owned()));
                                                [
                                                    text(SharedString::from(
                                                        if at == 0 { lead.trim_start() } else { lead }.to_owned(),
                                                    )),
                                                    if Some(at) == said {
                                                        word.rounded(tokens::radius_sm)
                                                            .bg(|| theme().primary.opacity(0.45))
                                                    } else {
                                                        word
                                                    },
                                                ]
                                            }))
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

/// A line of the full-screen subtitle: light on its dark plate.
fn subtitle_text(line: Text) -> Text {
    line.text_2xl().font_weight(FontWeight::SEMIBOLD).text_center().text_color(|| theme().foreground)
}

/// Translate the transcript with the AI provider.
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
        l("Translate with LLM"),
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

/// The search field over the transcript, while searching.
fn search_bar(review: Review) -> impl IntoElement {
    when(
        move || review.searching.get(),
        move || {
            // Escape closes the search from inside its field too.
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

/// The handle on the panel's edge: dragged, it resizes the panel, and the
/// size is kept for the next recording. Beside the transcript it changes
/// the panel's width; under a video on top, the video's height.
fn divider(review: Review, under: bool) -> impl IntoElement {
    use nsh_core::{TouchPhase, element::TouchEvent};

    use self::review::{SIDE_MAX, SIDE_MIN, VIDEO_MAX, VIDEO_MIN};
    // Where the drag began: the pointer, and the size then.
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
                        // The side panel is on the right, so moving left
                        // widens it; the video grows downwards.
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
