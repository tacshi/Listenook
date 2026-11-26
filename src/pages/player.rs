use std::{path::Path, rc::Rc};

use listenook_core::{
    format::{self, track_position},
    media::container,
    media::subtitles::{self, Cue},
};
use nsh_base::theme;
use nsh_core::{
    desktop::{TitleBarOptions, TitleBarStyle, WindowAttributes, WindowMode},
    element::desktop::{current_window, open_window, title_bar},
    prelude::*,
};

use super::gestures;
use crate::services::persist;
use crate::ui::{error_text, l, tr};
use crate::{
    platform::file_url,
    services::{media, playable},
    state::{
        podcast::{RATES, rate_label},
        store,
    },
    ui::{
        self, Icon, MenuToggle, Tone, menu, toast,
        tokens::{self},
    },
};

#[derive(Debug, Clone, PartialEq)]
struct Track {
    id: String,
    label: SharedString,
    cues: Rc<Vec<Cue>>,
}

fn find_tracks(video: &str) -> Vec<(String, String, Vec<Cue>)> {
    let mut found = Vec::new();
    let mut beside: Vec<String> = Path::new(video)
        .parent()
        .and_then(|folder| std::fs::read_dir(folder).ok())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.path().to_str().map(str::to_owned))
        .filter(|path| subtitles::is(path, subtitles::Kind::Subtitles) && subtitles::pairs_with(path, video))
        .collect();
    beside.sort();
    for path in beside {
        let imported = std::fs::read(&path).ok().and_then(|bytes| {
            subtitles::import_subtitles(&subtitles::decode(&bytes), &subtitles::extension(&path), None).ok()
        });
        if let Some(imported) = imported {
            let cues = imported
                .document
                .segments
                .into_iter()
                .map(|segment| Cue { start_ms: segment.start_ms, end_ms: segment.end_ms, text: segment.text })
                .collect();
            let name = Path::new(&path).file_name().and_then(|name| name.to_str()).unwrap_or(&path).to_owned();
            found.push((format!("file:{path}"), name, cues));
        }
    }
    let built_in = container::subtitles_in(Path::new(video));
    for (index, track) in built_in.into_iter().enumerate() {
        found.push((format!("embedded:{index}"), track.label, track.cues));
    }
    found
}

/// Plays the video at `path`: in a window of its own on a computer, in the app's on a phone or
/// where a window cannot open.
pub(crate) fn open_video(path: &str) {
    if crate::platform::is_phone() || !open_player(path) {
        store().act(crate::state::Action::ShowVideo(path));
    }
}

pub(crate) fn pick_video() {
    let answer = pick_paths(nsh_core::file_dialog::OpenDialog::files().filter(nsh_core::file_dialog::FileFilter::new(
        "Videos",
        listenook_core::media::subtitles::VIDEO_EXTENSIONS.to_vec(),
    )));
    store().run(async move {
        if let Ok(Some(paths)) = answer.await
            && let Some(path) = paths.first().and_then(|path| path.to_str())
        {
            open_video(path);
        }
    });
}

pub(crate) fn open_player(path: &str) -> bool {
    let title = Path::new(path).file_name().and_then(|name| name.to_str()).unwrap_or(path).to_owned();
    let content = path.to_owned();
    let mut bar = TitleBarOptions::default();
    bar.style = TitleBarStyle::Hidden;
    bar.height = Some(px(TITLE));
    if cfg!(target_os = "macos") {
        bar.controls_offset = Some(point(px(-200.0), px(-200.0)));
    }
    let mut attributes = WindowAttributes::default();
    attributes.title_bar = Some(bar);
    open_window(
        nsh_core::element::desktop::window()
            .id(format!("video:{path}"))
            .title(title)
            .attributes(attributes)
            .default_size(size(px(960.0), px(600.0)))
            .content(move || player(&content).into_element()),
    )
    .inspect(|player| player.focus())
    .is_some()
}

pub(crate) fn player(path: &str) -> impl IntoElement {
    let store = store();
    let path = path.to_owned();
    let frame = stored(current_window());
    let own_window = frame.with(|frame| !frame.is_main());
    if own_window {
        store.act(crate::state::Action::PlayerOpened);
    }
    let title: SharedString =
        Path::new(&path).file_name().and_then(|name| name.to_str()).unwrap_or(&path).to_owned().into();
    let remembered = store.data_root().and_then(|root| persist::video_position(&root, &path));
    let start_at = remembered.as_ref().map_or(0, |entry| entry.position_ms);

    let media = element_ref();
    let (paused, rate) = (signal(false), signal(store.saved_rate("playback_rate")));
    let (position_ms, duration_ms) = (signal(start_at), signal(0_i64));
    let sleeps = untracked(|| crate::state::sleep::SleepState::get().stops());
    effect(move || {
        if crate::state::sleep::SleepState::get().stops() != sleeps {
            paused.set(true);
        }
    });
    let dragging = signal(None::<f64>);
    let fullscreen = signal(false);
    let (boost, volume) = (signal(false), signal(1.0_f32));
    let tracks = signal(Vec::<Track>::new());
    let chosen = signal(remembered.as_ref().and_then(|entry| entry.subtitle_id.clone()));
    let repeating = signal(false);
    // The subtitle being repeated, as (start, end): kept while it plays, so an earlier one that
    // overlaps it and ends first does not take the repeat over.
    let held = stored(None::<(i64, i64)>);

    let cues = computed(move || {
        let id = chosen.get()?;
        tracks.with(|tracks| tracks.iter().find(|track| track.id == id).map(|track| track.cues.clone()))
    });
    let current = computed(move || {
        let position = position_ms.get();
        cues.with(|cues| {
            let cues = cues.as_ref()?;
            let index = cues.partition_point(|cue| cue.start_ms <= position).checked_sub(1)?;
            (position < cues[index].end_ms).then_some(index)
        })
    });
    let seek = move |ms: i64| {
        let ms = ms.clamp(0, duration_ms.get_untracked().max(0));
        position_ms.set(ms);
        media.seek(ms as f64 / 1000.0);
    };
    let step = move |forward: bool| {
        let position = position_ms.get_untracked();
        let target = cues.with_untracked(|cues| {
            let cues = cues.as_ref()?;
            if forward {
                cues.iter().find(|cue| cue.start_ms > position + 50).map(|cue| cue.start_ms)
            } else {
                cues.iter().rev().find(|cue| cue.start_ms < position - 1000).map(|cue| cue.start_ms)
            }
        });
        seek(target.unwrap_or(position + if forward { 5000 } else { -5000 }));
    };
    let last = Rc::new(std::cell::RefCell::new((start_at, 0_i64, None::<String>, false)));
    {
        let last = last.clone();
        effect(move || {
            *last.borrow_mut() = (position_ms.get(), duration_ms.get(), chosen.get(), fullscreen.get());
        });
    }
    let save = {
        let (path, last) = (path.clone(), last.clone());
        move || {
            if let Some(root) = store.data_root() {
                let (position, duration, subtitles, _) = last.borrow().clone();
                let position = if duration > 0 && position > duration - 2000 { 0 } else { position };
                persist::remember_video(&root, &path, position, subtitles);
            }
        }
    };

    {
        let video = path.clone();
        spawn(async move {
            let found = blocking(move || find_tracks(&video)).await.unwrap_or_default();
            let found: Vec<Track> = found
                .into_iter()
                .map(|(id, label, cues)| Track { id, label: label.into(), cues: Rc::new(cues) })
                .collect();
            batch(|| {
                if remembered.is_none() && chosen.get_untracked().is_none() {
                    chosen.set(found.first().map(|track| track.id.clone()));
                }
                tracks.set(found);
            });
        });
    }

    let cache_id = format!("player-{:016x}", {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        path.hash(&mut hasher);
        hasher.finish()
    });
    let needs_help = playable::needs_help(&path);
    let source = signal(if needs_help { String::new() } else { file_url(&path) });
    let waiting_for_source = signal(needs_help);
    if needs_help {
        let (id, video) = (cache_id.clone(), path.clone());
        toast(Tone::Info, tr("Preparing this recording for playback…"));
        spawn(async move {
            match playable::prepare(id, video).await {
                Some(made) => source.set(file_url(&made.to_string_lossy())),
                None => toast(Tone::Error, tr("This recording's format cannot be played here.")),
            }
        });
    }

    let set_fullscreen = move |on: bool| {
        if fullscreen.get_untracked() == on {
            return;
        }
        // A phone or tablet has no window to make full screen: the page takes the whole screen itself.
        if crate::platform::is_phone() {
            batch(|| {
                fullscreen.set(on);
                store.act(crate::state::Action::SetImmersive(on));
            });
            return;
        }
        if on {
            batch(|| {
                fullscreen.set(true);
                if !own_window {
                    store.act(crate::state::Action::SetImmersive(true));
                }
            });
        }
        frame.with(|frame| frame.set_mode(if on { WindowMode::FullScreen } else { WindowMode::Normal }));
    };
    frame.with(|frame| {
        frame.on_mode_change(move |mode, _| {
            if mode != WindowMode::FullScreen && fullscreen.get_untracked() {
                batch(|| {
                    fullscreen.set(false);
                    if !own_window {
                        store.act(crate::state::Action::SetImmersive(false));
                    }
                });
            }
        })
    });
    let controls = Rc::new(media::claim(move |command| match command {
        media::Command::Play => paused.set(false),
        media::Command::Pause => paused.set(true),
        media::Command::Toggle => paused.set(!paused.get_untracked()),
        media::Command::Next => step(true),
        media::Command::Previous => step(false),
        media::Command::Seek(position) => seek(position),
    }));
    {
        let title = title.clone();
        let beat = computed(move || position_ms.get() / 5000);
        effect(move || {
            beat.get();
            controls.publish(Some(media::Now {
                title: title.to_string(),
                artist: "Listenook".into(),
                position_ms: position_ms.get_untracked(),
                duration_ms: duration_ms.get(),
                playing: !paused.get(),
                rate: rate.get(),
            }));
        });
    }
    on_key_with("space", KeyOptions { for_focus: true, ..KeyOptions::default() }, move |_| {
        paused.set(!paused.get_untracked())
    });
    on_key("left", move |_| step(false));
    on_key("right", move |_| step(true));
    on_key("r", move |_| repeating.set(!repeating.get_untracked()));
    on_key("f", move |_| set_fullscreen(!fullscreen.get_untracked()));
    on_key("escape", move |_| {
        if fullscreen.get_untracked() {
            set_fullscreen(false);
        } else if own_window {
            frame.with(|frame| frame.close());
        } else {
            store.act(crate::state::Action::CloseVideo);
        }
    });
    {
        let save = save.clone();
        cleanup(move || {
            save();
            playable::forget(&cache_id);
            if last.borrow().3 {
                store.act(crate::state::Action::SetImmersive(false));
                if !own_window {
                    frame.with(|frame| frame.set_mode(WindowMode::Normal));
                }
            }
            if own_window && store.player_closed() {
                nsh_core::element::desktop::quit();
            }
        });
    }

    let save_on_pause = save.clone();
    let video_view = video(move || source.get())
        .element_ref(&media)
        .paused(move || paused.get())
        .rate(move || if boost.get() { gestures::BOOST } else { rate.get() })
        .volume(move || volume.get())
        .audio_session(|| nsh_core::AudioSession::Playback)
        .progress_interval(100.0)
        .on_load(move |info: &VideoInfo| {
            duration_ms.set((info.duration * 1000.0) as i64);
            if start_at > 0 {
                media.seek(start_at as f64 / 1000.0);
            }
        })
        .on_progress(move |progress: &VideoProgress| {
            let position = (progress.current_time * 1000.0) as i64;
            if !paused.get_untracked() {
                crate::state::activity::ActivityState::get()
                    .act(crate::state::activity::ActivityAction::Note(listenook_core::activity::Kind::Listen));
                crate::state::sleep::SleepState::get().act(crate::state::sleep::SleepAction::Heard);
            }
            let again = repeating.get_untracked().then(|| {
                cues.with_untracked(|cues| {
                    let cues = cues.as_ref()?;
                    let before = position_ms.get_untracked();
                    let spans = cues.iter().map(|cue| (cue.start_ms, cue.end_ms));
                    let kept = listenook_core::playback::repeated_cue(spans, held.get(), before);
                    held.replace(kept);
                    kept.filter(|&(_, end)| position >= end)
                })
            });
            if !repeating.get_untracked() {
                held.replace(None);
            }
            match again.flatten() {
                Some((start, _)) => {
                    position_ms.set(start);
                    media.seek(start as f64 / 1000.0);
                }
                None => position_ms.set(position),
            }
        })
        .on_end(move || {
            crate::state::sleep::SleepState::get().ended();
            paused.set(true);
        })
        .on_error(move |_: &str| {
            if waiting_for_source.get_untracked() {
                waiting_for_source.set(false);
            } else {
                toast(Tone::Error, error_text("unsupported_format"));
            }
        });
    effect(move || {
        if paused.get() {
            untracked(&save_on_pause);
        }
    });

    let hud = signal(true);
    // Full screen, the page reaches past the safe area (the root drops its padding): what floats
    // on the picture keeps clear of it.
    let edge = move |side: fn(EdgeInsets) -> f32| if fullscreen.get() { side(safe_area()) } else { 0.0 };
    let subtitle_line = view()
        .pointer_events(nsh_core::PointerEvents::None)
        .absolute()
        .left(move || px(edge(|edges| edges.left.0)))
        .right(move || px(edge(|edges| edges.right.0)))
        .bottom(move || px(edge(|edges| edges.bottom.0) + if hud.get() { 80.0 } else { 28.0 }))
        .items_center()
        .px_8()
        .child(when(
            move || current.get().is_some(),
            move || {
                view()
                    .max_w(px(960.0))
                    .px_4()
                    .py_2()
                    .rounded(|| tokens::corner(tokens::Corner::Medium))
                    .bg(|| tokens::ink(tokens::Ink::Stage).opacity(0.7))
                    .child(
                        text(move || {
                            let index = current.get();
                            cues.with(|cues| {
                                index
                                    .and_then(|index| {
                                        cues.as_ref()?.get(index).map(|cue| SharedString::from(cue.text.clone()))
                                    })
                                    .unwrap_or_default()
                            })
                        })
                        .text_2xl()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_center()
                        .text_color(ink),
                    )
            },
        ));

    let subtitle_menu = menu(
        view()
            .size(px(32.0))
            .items_center()
            .justify_center()
            .rounded(|| tokens::corner(tokens::Corner::Medium))
            .label(tr("Subtitles"))
            .tooltip(ui::tip(tr("Subtitles")))
            .text_color(move || if chosen.get().is_some() { lit() } else { ink() })
            .hover(|s| s.bg(|| ink().opacity(0.14)))
            .active(|s| s.bg(|| ink().opacity(0.24)))
            .child(ui::icon(Icon::Captions, 18.0)),
    )
    .child(MenuToggle {
        label: l("Subtitles off"),
        checked: move || chosen.get().is_none(),
        on_select: move || chosen.set(None),
    })
    .child(each(
        tracks,
        |track: &Track| track.id.clone(),
        move |track, _| {
            let label = track.with_untracked(|track| track.label.clone());
            MenuToggle {
                label,
                checked: move || track.with(|track| chosen.get().as_ref() == Some(&track.id)),
                on_select: move || chosen.set(Some(track.with_untracked(|track| track.id.clone()))),
            }
        },
    ));

    let on_track = computed(move || track_position(position_ms.get(), duration_ms.get()));
    let second = computed(move || position_ms.get() / 1000 * 1000);
    let position = move || {
        ui::slider_on_picture(
            tr("Position"),
            move || dragging.get().unwrap_or_else(|| on_track.get() as f64),
            move || duration_ms.get() as f64,
            move |value| dragging.set(Some(value)),
            move |value| {
                seek(value as i64);
                dragging.set(None);
            },
        )
        .flex_1()
    };
    let time = |ms: Box<dyn Fn() -> i64>| {
        text(move || format::shown(format::Shown::Clock(ms())))
            .text_xs()
            .tabular_nums()
            .text_color(|| ink().opacity(0.8))
    };
    let controls = view()
        .h(px(44.0))
        .flex_row()
        .items_center()
        .gap_2()
        .child(stage_button(|| Icon::SkipBack, "Previous subtitle", || false, move || step(false)))
        .child(stage_button(
            move || if paused.get() { Icon::Play } else { Icon::Pause },
            "Play or pause",
            || false,
            move || paused.set(!paused.get_untracked()),
        ))
        .child(stage_button(|| Icon::SkipForward, "Next subtitle", || false, move || step(true)))
        .child(time(Box::new(move || dragging.get().map_or_else(|| second.get(), |ms| ms as i64))))
        .child(when(move || !crate::platform::compact(), position).otherwise(|| view().flex_1()))
        .child(time(Box::new(move || duration_ms.get())))
        .child(stage_button(
            || Icon::Repeat,
            "Repeat this subtitle",
            move || repeating.get(),
            move || repeating.set(!repeating.get_untracked()),
        ))
        .child(subtitle_menu)
        .child(
            menu(
                view()
                    .h(px(32.0))
                    .px_2()
                    .items_center()
                    .justify_center()
                    .rounded(|| tokens::corner(tokens::Corner::Medium))
                    .label(tr("Playback speed"))
                    .hover(|s| s.bg(|| ink().opacity(0.14)))
                    .child(
                        text(move || rate_label(rate.get()))
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .tabular_nums()
                            .text_color(ink),
                    ),
            )
            .children(RATES.iter().map(move |option| {
                let option = *option;
                ui::MenuChoice {
                    label: rate_label(option),
                    checked: move || (rate.get() - option).abs() < 0.001,
                    on_select: move || {
                        rate.set(option);
                        store.act(crate::state::Action::SaveRate("playback_rate", option));
                    },
                }
            })),
        )
        .child(
            when(
                move || fullscreen.get(),
                move || stage_button(|| Icon::Minimize, "Exit full screen", || false, move || set_fullscreen(false)),
            )
            .otherwise(move || stage_button(|| Icon::Maximize, "Full screen", || false, move || set_fullscreen(true))),
        );

    let wait = std::rc::Rc::new(std::cell::RefCell::new(None::<Spawned<()>>));
    let wake = move || {
        hud.set(true);
        let later = set_timeout(std::time::Duration::from_millis(2500), move || {
            if !paused.get_untracked() {
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
            let _ = (fullscreen.get(), paused.get());
            untracked(&wake);
        }
    });
    let shown = move |s: nsh_core::element::StyleRefinement| s.opacity(if hud.get() { 1.0 } else { 0.0 });
    let surface = if crate::platform::is_phone() {
        let wake = wake.clone();
        gestures::layer(gestures::Video {
            position: Rc::new(move || position_ms.get_untracked()),
            duration: Rc::new(move || duration_ms.get_untracked()),
            seek: Rc::new(seek),
            tap: Rc::new(move || if hud.get_untracked() { hud.set(false) } else { wake() }),
            boost,
            volume,
        })
        .into_element()
    } else {
        view()
            .absolute()
            .inset_0()
            .window_drag(own_window)
            .label(tr("Play or pause"))
            .on_press(move || paused.set(!paused.get_untracked()))
            .into_element()
    };
    view()
        .flex_1()
        .bg(|| tokens::ink(tokens::Ink::Stage))
        .on_mouse_move(move |_: &MouseEvent| wake())
        .style_with(move |s| if !hud.get() { s.cursor(Cursor::None) } else { s })
        .child(view().flex_1().min_h(px(0.0)).child(video_view.flex_1()).child(surface).child(subtitle_line))
        .child(when(
            move || !fullscreen.get(),
            move || {
                view()
                    .absolute()
                    .top(px(0.0))
                    .left(px(0.0))
                    .right(px(0.0))
                    .h(px(TITLE))
                    .flex_row()
                    .items_center()
                    .window_drag(true)
                    .bg(|| tokens::ink(tokens::Ink::Stage).opacity(0.45))
                    .transition_opacity()
                    .duration(tokens::motion::BASE)
                    .style_with(shown)
                    .child(
                        view().style_with(|s| s.w(px(title_bar().right.0.max(84.0)))).items_start().ps_3().child(
                            when(
                                move || !own_window,
                                move || {
                                    view().window_drag(false).child(stage_button(
                                        || Icon::ChevronLeft,
                                        "Back",
                                        || false,
                                        move || store.act(crate::state::Action::CloseVideo),
                                    ))
                                },
                            )
                            .otherwise(move || {
                                when(
                                    || cfg!(target_os = "macos"),
                                    move || {
                                        view()
                                            .flex_row()
                                            .gap_2()
                                            .window_drag(false)
                                            .child(window_button(
                                                "Close",
                                                || tokens::ink(tokens::Ink::WindowClose),
                                                move || frame.with(|frame| frame.close()),
                                            ))
                                            .child(window_button(
                                                "Minimize",
                                                || tokens::ink(tokens::Ink::WindowMinimize),
                                                move || frame.with(|frame| frame.minimize()),
                                            ))
                                            .child(window_button(
                                                "Full screen",
                                                || tokens::ink(tokens::Ink::WindowZoom),
                                                move || set_fullscreen(true),
                                            ))
                                    },
                                )
                            }),
                        ),
                    )
                    .child(
                        text(title.clone())
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .number_of_lines(1)
                            .text_center()
                            .flex_1()
                            .text_color(ink),
                    )
                    .child(view().style_with(|s| s.w(px(title_bar().right.0.max(84.0)))))
            },
        ))
        .child(
            view()
                .absolute()
                .left(move || px(12.0 + edge(|edges| edges.left.0)))
                .right(move || px(12.0 + edge(|edges| edges.right.0)))
                .bottom(move || px(12.0 + edge(|edges| edges.bottom.0)))
                .px_3()
                .rounded(|| tokens::corner(tokens::Corner::Large))
                .style_with(|s| tokens::surface(tokens::Surface::Glass, s))
                .window_drag(false)
                .transition_opacity()
                .duration(tokens::motion::BASE)
                .style_with(shown)
                .child(when(crate::platform::compact, move || view().flex_row().pt_3().child(position())))
                .child(controls),
        )
}

const TITLE: f32 = 36.0;

fn ink() -> Hsla {
    theme().foreground.dark
}

fn lit() -> Hsla {
    theme().primary.dark
}

fn stage_button(
    glyph: impl Fn() -> Icon + 'static,
    name: &'static str,
    on: impl Fn() -> bool + Copy + 'static,
    on_press: impl Fn() + 'static,
) -> impl IntoElement {
    view().flex_shrink_0().tooltip(ui::tip(tr(name))).child(
        nsh_base::button()
            .accessibility_label(tr(name))
            .on_press(on_press)
            .size(px(32.0))
            .items_center()
            .justify_center()
            .rounded(|| tokens::corner(tokens::Corner::Medium))
            .text_color(move || if on() { lit() } else { ink() })
            .hover(|s| s.bg(|| ink().opacity(0.14)))
            .active(|s| s.bg(|| ink().opacity(0.24)))
            .child(ui::icon_of(glyph, 18.0)),
    )
}

fn window_button(name: &'static str, color: fn() -> AdaptiveColor, on_press: impl Fn() + 'static) -> impl IntoElement {
    view().tooltip(ui::tip(tr(name))).child(
        nsh_base::button()
            .accessibility_label(tr(name))
            .on_press(on_press)
            .size(px(12.0))
            .rounded_full()
            .bg(color)
            .hover(|s| s.opacity(0.8))
            .active(|s| s.opacity(0.6)),
    )
}
