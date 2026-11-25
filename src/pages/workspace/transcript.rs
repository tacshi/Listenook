use listenook_core::{ContentMode, Segment, format::clock, highlights};
use nsh_base::theme;
use nsh_core::{
    TouchPhase,
    element::{Position, TouchEvent, desktop::MenuItem},
    prelude::*,
};

use super::{copy, review::Review, search_bar};
use crate::{
    services::llm,
    state::{SettingsTab, error_text, l, tr},
    ui::{
        self, Icon, Size, Tone, Variant, button, field, icon_button, modal, modal_actions, text_area, text_field_with,
        toast, toast_with_action,
        tokens::{self, motion},
    },
};

pub(super) fn transcript(review: Review) -> impl IntoElement {
    let speaker = signal(None::<String>);
    let viewable = signal(None::<(usize, usize)>);
    let reveal = move |segment: usize, animated: bool| {
        if review.editing.get_untracked().is_some() || untracked(|| review.dragging()) {
            return;
        }
        if let Some(row) = review.shown.with_untracked(|shown| shown.iter().position(|index| *index == segment)) {
            // Moved by the app: a hold left over (a gesture the platform
            // ended without saying) does not make this a scroll by hand.
            review.held(None);
            review.list.scroll_to_index(row as u32, percentage(0.35), px(0.0), animated && !reduce_motion());
        }
    };
    let bring = move |animated: bool| {
        if let Some(current) = review.current.get_untracked() {
            reveal(current, animated);
        }
    };
    effect(move || {
        review.current.get();
        if review.following.get() && !review.paused.get() && review.scrub.get_untracked().is_none() {
            bring(true);
        }
    });
    effect(move || {
        if let Some(segment) = review.scrubbed.get() {
            untracked(|| reveal(segment, false));
        }
    });
    {
        let first = std::cell::Cell::new(true);
        effect(move || {
            let _ = (review.side.get(), review.video_on_top.get(), review.fullscreen.get());
            if !first.replace(false) {
                spawn(async move {
                    timer(std::time::Duration::from_millis(250)).await;
                    let following = review.following.get_untracked();
                    let Some(segment) = review
                        .scrubbed
                        .get_untracked()
                        .or_else(|| following.then(|| review.current.get_untracked()).flatten())
                    else {
                        return;
                    };
                    let row = review.shown.with_untracked(|shown| shown.iter().position(|index| *index == segment));
                    if !row
                        .zip(viewable.get_untracked())
                        .is_some_and(|(row, (first, last))| (first..=last).contains(&row))
                    {
                        reveal(segment, false);
                    }
                });
            }
        });
    }
    let open = std::rc::Rc::new(std::cell::Cell::new(true));
    {
        let open = open.clone();
        cleanup(move || open.set(false));
    }
    spawn(async move {
        timer(std::time::Duration::from_millis(250)).await;
        if open.get() {
            bring(false);
        }
    });
    view()
        .flex_1()
        .min_h(px(0.0))
        .child(search_bar(review))
        .child(
            virtual_list(move || review.shown.with(Vec::len), move |at| row(review, at, speaker))
                .keys(move || {
                    review.shown.with(|shown| {
                        shown.iter().filter_map(|index| review.segment(*index).map(|s| s.id)).collect::<Vec<_>>()
                    })
                })
                .estimated_item_size(px(64.0))
                .content_padding(px(ui::PAGE_INSET - 12.0))
                .empty(
                    text(l("No sentences match your search."))
                        .text_sm()
                        .p(px(ui::PAGE_INSET))
                        .text_color(|| theme().muted_foreground),
                )
                .element_ref(&review.list)
                .viewability(Viewability { item_visible_threshold: Some(percentage(1.0)), ..Default::default() })
                .on_viewable_items_change(move |items: &ViewableItems| viewable.set(items.viewable))
                .on_scroll(move |event: &ScrollEvent| review.scrolled(event))
                .on_scroll_drag_start(move |at: &Point<Points>| review.held(Some(at.y.0)))
                .on_scroll_drag_end(move |_: &Point<Points>| review.held(None))
                .on_scroll_end(move |_: &Point<Points>| review.held(None))
                .on_wheel(move |event: &WheelEvent| {
                    let moved = match event.delta {
                        WheelDelta::Points(by) => by.y.0 != 0.0,
                        WheelDelta::Lines(by) => by.y != 0.0,
                    };
                    if moved {
                        review.stop_following();
                    }
                })
                .flex_1(),
        )
        .child(jump_to_playing(review, viewable))
        .child(speaker_dialog(review, speaker))
}

/// Once the user scrolled the sentence playing out of view: a button back
/// to it, pointing the way, after which the list follows playback again.
fn jump_to_playing(review: Review, viewable: Signal<Option<(usize, usize)>>) -> impl IntoElement {
    let away = computed(move || {
        if review.following.get() || review.paused.get() {
            return None;
        }
        let current = review.current.get()?;
        let row = review.shown.with(|shown| shown.iter().position(|index| *index == current))?;
        let (first, last) = viewable.get()?;
        if row < first {
            Some(Icon::ArrowUp)
        } else if row > last {
            Some(Icon::ArrowDown)
        } else {
            None
        }
    });
    view()
        .absolute()
        .left(px(0.0))
        .right(px(0.0))
        .bottom(px(16.0))
        .items_center()
        .pointer_events(nsh_core::PointerEvents::BoxNone)
        .child(when(
            move || away.with(Option::is_some),
            move || {
                ui::floating_button(move || away.get().unwrap_or(Icon::ArrowDown), l("Jump to playing"))
                    .on_press(move || review.follow())
                    .test_id("jump-to-playing")
            },
        ))
}

fn row(review: Review, at: Position, speaker_dialog: Signal<Option<String>>) -> impl IntoElement {
    let run = computed(move || {
        let index = review.shown.with(|shown| shown.get(at.index()).copied())?;
        review.skipped_run(index)
    });
    when(move || run.with(Option::is_some), move || skipped_bar(review, run))
        .otherwise(move || sentence(review, at, speaker_dialog))
}

/// One row for a skipped run: how long it is, and a way to bring it back.
fn skipped_bar(review: Review, run: Memo<Option<(usize, usize)>>) -> impl IntoElement {
    let length = move || {
        let (first, last) = run.get()?;
        review.job.with(|job| Some(job.as_ref()?.document.as_ref()?.span_ms(first, last)))
    };
    let bring_back = move || {
        if let Some((first, last)) = run.get_untracked() {
            review.set_skipped(first, last, false);
        }
    };
    view().items_center().child(
        view()
            .w_full()
            .max_w(px(760.0))
            .flex_row()
            .items_center()
            .gap_2()
            .px_3()
            .py_1()
            .rounded(tokens::radius)
            .bg(|| theme().muted)
            .test_id("skipped-run")
            .child(ui::icon(Icon::Scissors, 14.0).text_color(|| theme().muted_foreground))
            .child(
                text(move || -> SharedString {
                    format!("{} · {}", tr("Skipped"), clock(length().unwrap_or_default())).into()
                })
                .text_sm()
                .tabular_nums()
                .select_none()
                .flex_1()
                .text_color(|| theme().muted_foreground),
            )
            .child(button(Variant::Ghost, Size::Sm, l("Bring back")).on_press(bring_back)),
    )
}

fn sentence(review: Review, at: Position, speaker_dialog: Signal<Option<String>>) -> impl IntoElement {
    let store = review.store;
    let index = computed(move || review.shown.with(|shown| shown.get(at.index()).copied()));
    let segment = computed(move || index.get().and_then(|index| review.segment(index)));
    let id = move || segment.with(|s| s.as_ref().map(|s| s.id.clone()));
    let is_current = move || index.get().is_some() && index.get() == review.scrubbed.get().or_else(|| review.spoken());
    let is_repeating = move || index.get().is_some_and(|index| review.repeats(index));
    let range = move || review.repeat_range();
    let opens_loop = move || range().zip(index.get()).is_some_and(|((first, _), index)| index == first);
    let closes_loop = move || range().zip(index.get()).is_some_and(|((_, last), index)| index == last);
    let row_ref = element_ref();
    review.track_row(index, row_ref);
    let picked = move || review.picked_in(id().as_deref());
    let editing = move || review.editing.with(|e| e.as_ref().is_some_and(|e| Some(&e.segment_id) == id().as_ref()));
    let words = computed(move || if is_current() { index.get().and_then(|index| review.words(index)) } else { None });
    let said = computed(move || {
        if words.with(Option::is_none) {
            return None;
        }
        let position = review.position_ms.get();
        words.with(|words| {
            let words = words.as_ref()?;
            words.partition_point(|(_, start, _)| *start <= position).checked_sub(1)
        })
    });
    let hidden = move || review.blind() && id().is_none_or(|id| !review.unveiled(&id));
    let mode = move || review.mode.get();
    let translated = move || segment.with(|s| s.as_ref().is_some_and(Segment::has_translation));
    let shows_original = move || mode() != ContentMode::Translated || !translated();
    let shows_translation = move || mode() != ContentMode::Original && translated();
    let retranslating = move || id().is_some_and(|id| review.retranslating.with(|waiting| waiting.contains(&id)));
    let needle =
        move || if review.searching.get() { review.query.with(|q| q.trim().to_owned()) } else { String::new() };
    let speaker_name = move || {
        segment.with(|s| {
            let speaker = s.as_ref()?.speaker.as_deref()?;
            review
                .job
                .with(|job| Some(SharedString::from(job.as_ref()?.document.as_ref()?.speaker_name(Some(speaker)))))
        })
    };
    let press = move || {
        if let Some(index) = index.get_untracked() {
            review.follow();
            review.play_from(index);
        }
    };
    let toggle_repeat = move || {
        if let Some(index) = index.get_untracked() {
            review.toggle_repeat(index);
        }
    };
    let repeat_through = move || {
        if let Some(index) = index.get_untracked() {
            review.repeat_through(index);
        }
    };
    let edit = move || {
        if let Some(index) = index.get_untracked() {
            review.edit(index);
        }
    };
    let skip = move || {
        if let Some(index) = index.get_untracked() {
            review.set_skipped(index, index, true);
        }
    };
    let skip_from = move || {
        if let Some(index) = index.get_untracked() {
            review.begin_skip(index);
        }
    };
    // Where a touch on the row went down while text of another sentence was
    // selected: lifted there, it clears that selection and does nothing else.
    let clears = signal(None::<Point<Points>>);
    let tap = move || {
        if clears.get_untracked().is_some() {
            return;
        }
        if let Some(index) = index.get_untracked()
            && !review.finish_skip(index)
        {
            review.follow();
            review.play_from(index);
        }
    };
    let found_ad = move || index.get().is_some_and(|index| review.found_ad(index));
    let starts_skip = move || index.get().is_some() && index.get() == review.skip_start();
    let line = view()
        .element_ref(&row_ref)
        .w_full()
        .max_w(px(760.0))
        .rounded(tokens::radius)
        .transition_colors()
        .duration(motion::BASE)
        .bg(move || {
            if starts_skip() {
                theme().primary.opacity(0.16)
            } else if is_current() {
                tokens::highlight()
            } else if found_ad() {
                theme().muted
            } else {
                theme().background
            }
        })
        .child(when(is_repeating, move || {
            view()
                .absolute()
                .left(px(2.0))
                .w(px(3.0))
                .top(move || px(if opens_loop() { 8.0 } else { 0.0 }))
                .bottom(move || px(if closes_loop() { 8.0 } else { 0.0 }))
                .rounded(px(1.5))
                .bg(|| theme().primary)
                .test_id("repeat-rail")
        }))
        .child(
            view()
                .group()
                .flex_row()
                .gap_2()
                .px_3()
                .py_2()
                .rounded(tokens::radius)
                .transition_colors()
                .duration(motion::INSTANT)
                .hover(|s| s.bg(|| theme().foreground.opacity(0.05)))
                .child(
                    view()
                        .flex_1()
                        .min_w(px(0.0))
                        .gap_1()
                        .child(when(
                            move || {
                                store.setting(|s| s.show_timestamps)
                                    || (store.setting(|s| s.show_speakers) && speaker_name().is_some())
                            },
                            move || {
                                view()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .select_none()
                                    .child(when(
                                        move || store.setting(|s| s.show_timestamps),
                                        move || {
                                            text(move || segment.with(|s| clock(s.as_ref().map_or(0, |s| s.start_ms))))
                                                .text_xs()
                                                .tabular_nums()
                                                .text_color(|| theme().muted_foreground)
                                        },
                                    ))
                                    .child(when(
                                        move || store.setting(|s| s.show_speakers) && speaker_name().is_some(),
                                        move || {
                                            nsh_base::button()
                                                .accessibility_label(tr("Rename speaker"))
                                                .on_press(move || {
                                                    speaker_dialog.set(
                                                        segment.with_untracked(|s| {
                                                            s.as_ref().and_then(|s| s.speaker.clone())
                                                        }),
                                                    )
                                                })
                                                .rounded(tokens::radius_sm)
                                                .hover(|s| s.opacity(0.7))
                                                .child(
                                                    text(move || speaker_name().unwrap_or_default())
                                                        .text_xs()
                                                        .font_weight(FontWeight::MEDIUM)
                                                        .text_color(|| theme().foreground),
                                                )
                                        },
                                    ))
                            },
                        ))
                        .child(when(editing, move || editor(review)).otherwise(move || {
                            nsh_base::button().on_press(tap).rounded(tokens::radius_sm).child(ui::veil(
                                hidden,
                                move || {
                                    view()
                                        .items_start()
                                        .gap_1()
                                        .child(when(shows_original, move || {
                                            when(
                                                move || words.with(Option::is_some),
                                                move || {
                                                    dynamic(move || {
                                                        let said = said.get();
                                                        let marks = words.with(|words| {
                                                            let parts: Vec<&str> = words
                                                                .iter()
                                                                .flatten()
                                                                .map(|(word, ..)| {
                                                                    listenook_core::local::lead_and_word(word).1
                                                                })
                                                                .collect();
                                                            segment.with(|s| {
                                                                s.as_ref()
                                                                    .map(|s| {
                                                                        highlights::word_marks(
                                                                            &s.text,
                                                                            &parts,
                                                                            &s.highlights,
                                                                        )
                                                                    })
                                                                    .unwrap_or_default()
                                                            })
                                                        });
                                                        untracked(|| {
                                                            let spans = words.get_untracked().unwrap_or_default();
                                                            text("")
                                                                .text_lg()
                                                                .line_height(nsh_core::LineHeight::Multiple(1.5))
                                                                .text_color(tokens::highlight_foreground)
                                                                .children(spans.into_iter().enumerate().flat_map(
                                                                    |(at, (word, ..))| {
                                                                        let (lead, word) =
                                                                            listenook_core::local::lead_and_word(&word);
                                                                        let word =
                                                                            text(SharedString::from(word.to_owned()));
                                                                        let word = if marks
                                                                            .get(at)
                                                                            .copied()
                                                                            .unwrap_or(false)
                                                                        {
                                                                            word.font_weight(FontWeight::SEMIBOLD)
                                                                        } else {
                                                                            word
                                                                        };
                                                                        [
                                                                            text(SharedString::from(
                                                                                if at == 0 {
                                                                                    lead.trim_start()
                                                                                } else {
                                                                                    lead
                                                                                }
                                                                                .to_owned(),
                                                                            )),
                                                                            if Some(at) == said {
                                                                                word.rounded(tokens::radius_sm)
                                                                                    .bg(|| theme().primary.opacity(0.3))
                                                                            } else {
                                                                                word
                                                                            },
                                                                        ]
                                                                    },
                                                                ))
                                                                .into_element()
                                                        })
                                                    })
                                                },
                                            )
                                            .otherwise(move || {
                                                dynamic(move || {
                                                    let needle = needle();
                                                    let runs = segment.with(|s| {
                                                        s.as_ref()
                                                            .map(|s| {
                                                                highlights::found_runs(&s.text, &s.highlights, &needle)
                                                            })
                                                            .unwrap_or_default()
                                                    });
                                                    untracked(|| {
                                                        text("")
                                                            .text_lg()
                                                            .line_height(nsh_core::LineHeight::Multiple(1.5))
                                                            .text_color(move || {
                                                                if is_current() {
                                                                    tokens::highlight_foreground()
                                                                } else {
                                                                    theme().foreground
                                                                }
                                                            })
                                                            .children(runs.into_iter().map(|(run, marked, found)| {
                                                                let run = text(SharedString::from(run));
                                                                let run = if marked {
                                                                    run.font_weight(FontWeight::SEMIBOLD)
                                                                } else {
                                                                    run
                                                                };
                                                                if found {
                                                                    run.rounded(tokens::radius_sm).bg(tokens::found)
                                                                } else {
                                                                    run
                                                                }
                                                            }))
                                                            .into_element()
                                                    })
                                                })
                                            })
                                        }))
                                        .child(when(shows_translation, move || {
                                            view()
                                                .flex_row()
                                                .items_center()
                                                .gap_2()
                                                // Its own box, allowed narrower than the line it would
                                                // fill, so the translation wraps rather than runs past
                                                // the row (Chinese has no spaces to break at).
                                                .child(view().flex_shrink(1.0).min_w(px(0.0)).child(dynamic(
                                                    move || {
                                                        let needle = needle();
                                                        let runs = segment.with(|s| {
                                                            let translated =
                                                                s.as_ref().and_then(|s| s.translated_text.as_deref());
                                                            highlights::found_runs(
                                                                translated.unwrap_or_default(),
                                                                &[],
                                                                &needle,
                                                            )
                                                        });
                                                        untracked(|| {
                                                            text("")
                                                                .select_none()
                                                                .flex_shrink(1.0)
                                                                .line_height(nsh_core::LineHeight::Multiple(1.5))
                                                                .style_with(move |s| {
                                                                    if mode() == ContentMode::Translated {
                                                                        s.text_base()
                                                                    } else {
                                                                        s.text_sm()
                                                                    }
                                                                })
                                                                .text_color(move || {
                                                                    if mode() == ContentMode::Translated {
                                                                        theme().foreground
                                                                    } else {
                                                                        theme().muted_foreground
                                                                    }
                                                                })
                                                                .transition_opacity()
                                                                .duration(motion::INSTANT)
                                                                .opacity(
                                                                    move || {
                                                                        if retranslating() { 0.45_f32 } else { 1.0 }
                                                                    },
                                                                )
                                                                .children(runs.into_iter().map(|(run, _, found)| {
                                                                    let run = text(SharedString::from(run));
                                                                    if found {
                                                                        run.rounded(tokens::radius_sm).bg(tokens::found)
                                                                    } else {
                                                                        run
                                                                    }
                                                                }))
                                                                .into_element()
                                                        })
                                                    },
                                                )))
                                                .child(when(retranslating, || {
                                                    view().label(tr("Translating")).child(ui::spinner(12.0))
                                                }))
                                        }))
                                },
                            ))
                        })),
                )
                .child(
                    view()
                        .items_end()
                        .gap_1()
                        .transition_opacity()
                        .duration(motion::INSTANT)
                        .opacity(move || if is_current() || is_repeating() || picked() { 1.0_f32 } else { 0.0 })
                        .group_hover(|s| s.opacity(1.0))
                        .child(
                            view()
                                .flex_row()
                                .gap_1()
                                .child(when(
                                    move || picked() && !crate::platform::is_phone(),
                                    move || {
                                        ui::toggle_button(
                                            Variant::Ghost,
                                            Icon::Bold,
                                            tr("Highlight"),
                                            Size::Sm,
                                            move || review.picked_marked(),
                                            move || review.toggle_highlight(),
                                        )
                                        .self_start()
                                    },
                                ))
                                .child(repeat_grip(review, index, is_repeating, toggle_repeat))
                                .child(icon_button(Icon::Pencil, tr("Edit"), Size::Sm, edit).self_start()),
                        ),
                ),
        );
    let area = move || {
        view().w_full().max_w(px(760.0)).selectable(true).on_text_selection_change(move |event: &TextSelectionEvent| {
            if let Some(id) = segment.with_untracked(|s| s.as_ref().map(|s| s.id.clone())) {
                review.pick(&id, event);
            }
        })
    };
    let outer = move || {
        view().items_center().on_touch(move |event: &TouchEvent| {
            let Some(point) = event.points.iter().find(|point| point.changed) else {
                return;
            };
            match event.phase {
                TouchPhase::Start => {
                    let elsewhere = review.selection.with_untracked(Option::is_some) && !picked();
                    clears.set(elsewhere.then_some(point.page));
                }
                TouchPhase::End => {
                    if let Some(from) = clears.get_untracked()
                        && (point.page.x.0 - from.x.0).abs() < 10.0
                        && (point.page.y.0 - from.y.0).abs() < 10.0
                    {
                        review.clear_selection();
                    }
                }
                TouchPhase::Move | TouchPhase::Cancel => {}
            }
        })
    };
    if crate::platform::is_phone() {
        let actions = move || {
            if !picked() {
                return Vec::new();
            }
            let label = if review.picked_marked() { tr("Remove highlight") } else { tr("Highlight") };
            vec![MenuItem::new(label.to_string()).on_select(move || review.toggle_highlight())]
        };
        return outer().child(area().selection_menu(actions).child(line)).into_element();
    }
    outer()
        .child(
            area().child(
                ui::context_menu(line)
                    .child(when(picked, move || {
                        ui::menu_action(
                            Icon::Bold,
                            move || if review.picked_marked() { tr("Remove highlight") } else { tr("Highlight") },
                            move || review.toggle_highlight(),
                        )
                    }))
                    .child(when(picked, move || {
                        ui::menu_action(Icon::Copy, l("Copy selection"), move || review.copy_selection())
                    }))
                    .child(when(picked, ui::menu_divider))
                    .child(ui::menu_action(Icon::Play, l("Play from here"), press))
                    .child(ui::menu_action(Icon::Repeat, l("Repeat sentence"), toggle_repeat))
                    .child(when(
                        move || review.repeating.with(Option::is_some) && !is_repeating(),
                        move || ui::menu_action(Icon::Repeat, l("Repeat through here"), repeat_through),
                    ))
                    .child(ui::menu_divider())
                    .child(ui::menu_action(Icon::Scissors, l("Skip this sentence"), skip))
                    .child(ui::menu_action(Icon::Scissors, l("Skip from here…"), skip_from))
                    .child(ui::menu_divider())
                    .child(ui::menu_action(Icon::Pencil, l("Edit"), edit))
                    .child(ui::menu_action(Icon::Copy, l("Copy sentence"), move || {
                        let shown = segment.with_untracked(|s| {
                            s.as_ref().map(|s| match (mode(), s.translated_text.clone()) {
                                (ContentMode::Translated, Some(t)) => t,
                                (ContentMode::Bilingual, Some(t)) => format!("{}\n{t}", s.text),
                                _ => s.text.clone(),
                            })
                        });
                        if let Some(shown) = shown {
                            copy(shown, None);
                        }
                    })),
            ),
        )
        .into_element()
}

/// The repeat button: a tap loops the sentence (or ends the loop it is in),
/// and a drag up or down from it loops every sentence the finger passes.
fn repeat_grip(
    review: Review,
    index: Memo<Option<usize>>,
    is_repeating: impl Fn() -> bool + Copy + 'static,
    toggle_repeat: impl Fn() + Copy + 'static,
) -> impl IntoElement {
    view()
        .self_start()
        .rounded(tokens::radius)
        .test_id("repeat-grip")
        .claim_touches(TouchClaim::on_pan(PanActivation::vertical(px(4.0), px(12.0))))
        .keep_touches(true)
        .on_responder_grant(move |_: &ResponderEvent| {
            if let Some(index) = index.get_untracked() {
                review.begin_repeat_drag(index);
            }
        })
        .on_responder_move(move |event: &ResponderEvent| review.drag_to(event.gesture.position.y.0))
        .on_responder_release(move |_: &ResponderEvent| review.finish_repeat_drag())
        .on_responder_terminate(move |_: &ResponderEvent| review.finish_repeat_drag())
        .child(ui::toggle_button(
            Variant::Ghost,
            Icon::Repeat,
            tr("Repeat sentence"),
            Size::Sm,
            is_repeating,
            toggle_repeat,
        ))
}

fn editor(review: Review) -> impl IntoElement {
    on_key_with("escape", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        review.editing.set(None)
    });
    on_key_with("mod+enter", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        review.save_edit()
    });
    let original = move || review.editing.with(|e| e.as_ref().is_some_and(|e| e.original));
    let translation = move || review.editing.with(|e| e.as_ref().is_some_and(|e| e.translation));
    let translating = signal(false);
    // Fills the translation box from the sentence as it reads in the editor
    // now, and leaves saving to Save.
    let translate = move || {
        let source = review.draft.get_untracked().trim().to_owned();
        if translating.get_untracked() || source.is_empty() {
            return;
        }
        let (target, before) = (review.translation_target(), review.translation_draft.get_untracked());
        translating.set(true);
        // Owned by the store: the button that starts it gives way to a spinner.
        review.store.run(async move {
            let result = llm::translate_line(&source, &target).await;
            if !translating.try_set(false) {
                return;
            }
            match result {
                Ok(line) if review.translation_draft.get_untracked() == before => review.translation_draft.set(line),
                Ok(_) => {}
                Err(code) if llm::needs_setup(&code) => {
                    toast_with_action(Tone::Error, error_text(&code), tr("Settings"), move || {
                        review.store.open_settings(SettingsTab::Ai)
                    })
                }
                Err(code) => toast(Tone::Error, error_text(&code)),
            }
        });
    };
    view()
        .gap_2()
        .child(when(original, move || {
            text_area(review.draft, SharedString::default)
                .auto_focus(true)
                .on_selection_change(move |selection: &Selection| review.caret.set(selection.start))
                .test_id("segment-editor")
        }))
        .child(when(translation, move || {
            view()
                .child(
                    text_area(review.translation_draft, SharedString::default)
                        .auto_focus(!untracked(original))
                        .text_sm()
                        .pr(px(40.0))
                        .test_id("translation-editor"),
                )
                .child(when(
                    move || translating.get() || review.can_translate(),
                    move || {
                        view().absolute().top(px(4.0)).right(px(4.0)).child(
                            when(translating, || {
                                view().size(px(32.0)).items_center().justify_center().child(ui::spinner(14.0))
                            })
                            .otherwise(move || {
                                icon_button(Icon::Languages, tr("Translate again"), Size::Sm, translate)
                            }),
                        )
                    },
                ))
        }))
        .child(
            view()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap_2()
                .child(when(original, move || {
                    view()
                        .flex_row()
                        .gap_1()
                        .child(
                            button(Variant::Ghost, Size::Sm, l("Split at cursor"))
                                .on_press(move || review.split_editing()),
                        )
                        .child(
                            button(Variant::Ghost, Size::Sm, l("Merge with next"))
                                .disabled(move || !review.can_merge_editing())
                                .on_press(move || review.merge_editing()),
                        )
                }))
                .child(when(original, move || {
                    let open = signal(false);
                    ui::menu_with(open, ui::menu_trigger(Icon::More, tr("More sentence actions"), Size::Sm, open))
                        .child(ui::menu_action(Icon::Scissors, l("Skip this sentence"), move || review.skip_editing()))
                        .child(ui::menu_action(Icon::Scissors, l("Skip from here…"), move || {
                            review.skip_editing_onward()
                        }))
                        .child(ui::menu_divider())
                        .child(ui::menu_danger(Icon::Trash, l("Delete sentence"), move || review.delete_editing()))
                }))
                // Grows from its own width, so on a narrow screen Cancel and Save wrap
                // together to the right of a line of their own rather than squeezing.
                .child(
                    view()
                        .flex_grow(1.0)
                        .flex_shrink_0()
                        .flex_row()
                        .justify_end()
                        .gap_2()
                        .child(
                            button(Variant::Outline, Size::Sm, l("Cancel")).on_press(move || review.editing.set(None)),
                        )
                        .child(button(Variant::Primary, Size::Sm, l("Save")).on_press(move || review.save_edit())),
                ),
        )
}

fn speaker_dialog(review: Review, speaker: Signal<Option<String>>) -> impl IntoElement {
    let open = signal(false);
    let name = signal(String::new());
    effect(move || {
        if let Some(id) = speaker.get() {
            let current = review.job.with_untracked(|job| {
                job.as_ref()
                    .and_then(|job| job.document.as_ref())
                    .map(|d| d.speaker_name(Some(&id)))
                    .unwrap_or_default()
            });
            batch(|| {
                name.set(current);
                open.set(true);
            });
        }
    });
    effect(move || {
        if !open.get() {
            speaker.set(None);
        }
    });
    let rename = move || {
        if let Some(id) = speaker.get_untracked() {
            review.rename_speaker(&id, &name.get_untracked());
        }
        open.set(false);
    };
    modal(
        open,
        l("Rename speaker"),
        380.0,
        move || {
            field(
                l("Name"),
                text_field_with(name, SharedString::default, move |input| {
                    input.auto_focus(true).on_submit(move |_: &str| rename())
                }),
            )
            .into_element()
        },
        move || modal_actions(open, l("Cancel"), l("Rename"), move || !name.with(|n| n.trim().is_empty()), rename),
    )
}
