use listenook_core::{ContentMode, Segment, format::clock, highlights};
use nsh_base::theme;
use nsh_core::{
    element::{Position, desktop::MenuItem},
    prelude::*,
};

use super::{
    review::{Editing, Practice, Review},
    search_bar,
};
use crate::{
    services::llm,
    state::{l, tr},
    ui::{
        self, Icon, Size, Variant, button, field, icon_button, modal, modal_actions, text_area, text_field_with,
        tokens::{self, motion},
    },
};

pub(super) fn transcript(review: Review) -> impl IntoElement {
    let speaker = signal(None::<String>);
    let viewable = signal(None::<(usize, usize)>);
    let reveal = move |segment: usize, animated: bool| {
        if review.editing.get_untracked().is_some() || review.handle_at.get_untracked().is_some() {
            return;
        }
        if let Some(row) = review.shown.with_untracked(|shown| shown.iter().position(|index| *index == segment)) {
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
        if !review.paused.get() && review.scrub.get_untracked().is_none() {
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
                    let Some(segment) = review.scrubbed.get_untracked().or_else(|| review.current.get_untracked())
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
                .flex_1(),
        )
        .child(speaker_dialog(review, speaker))
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
    let read = move |f: fn(&Segment) -> SharedString| segment.with(|s| s.as_ref().map(f).unwrap_or_default());
    let id = move || segment.with(|s| s.as_ref().map(|s| s.id.clone()));
    let is_current = move || index.get().is_some() && index.get() == review.scrubbed.get().or_else(|| review.spoken());
    let is_repeating = move || index.get().is_some_and(|index| review.repeats(index));
    let range = move || review.repeat_range();
    let opens_loop = move || range().zip(index.get()).is_some_and(|((first, _), index)| index == first);
    let closes_loop = move || range().zip(index.get()).is_some_and(|((_, last), index)| index == last);
    let row_ref = element_ref();
    let cell = review.track_row(index, row_ref);
    let shows_handle = move || match review.handle_at.get() {
        Some(at) => id().is_some_and(|id| id == at),
        None => closes_loop(),
    };
    let holds_handle = move || match review.handle_cell.get() {
        Some(holder) => holder == cell,
        None => closes_loop(),
    };
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
    let tap = move || {
        if let Some(index) = index.get_untracked()
            && !review.finish_skip(index)
        {
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
                                                .focus_visible(tokens::focus_ring)
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
                                                    let runs = segment.with(|s| {
                                                        s.as_ref()
                                                            .map(|s| highlights::runs(&s.text, &s.highlights))
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
                                                            .children(runs.into_iter().map(|(run, marked)| {
                                                                let run = text(SharedString::from(run));
                                                                if marked {
                                                                    run.font_weight(FontWeight::SEMIBOLD)
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
                                            text(move || read(|s| s.translated_text.clone().unwrap_or_default().into()))
                                                .select_none()
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
                        .opacity(move || {
                            if is_current() || is_repeating() || picked() || shows_handle() { 1.0_f32 } else { 0.0 }
                        })
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
                                .child(
                                    ui::toggle_button(
                                        Variant::Ghost,
                                        Icon::Repeat,
                                        tr("Repeat sentence"),
                                        Size::Sm,
                                        is_repeating,
                                        toggle_repeat,
                                    )
                                    .self_start(),
                                )
                                .child(icon_button(Icon::Pencil, tr("Edit"), Size::Sm, edit).self_start()),
                        )
                        .child(when(
                            move || holds_handle() && review.practice.get() != Practice::Mimic,
                            move || loop_handle(review, cell, shows_handle),
                        )),
                ),
        );
    let area = move || {
        view().w_full().max_w(px(760.0)).selectable(true).on_text_selection_change(move |event: &TextSelectionEvent| {
            if let Some(id) = segment.with_untracked(|s| s.as_ref().map(|s| s.id.clone())) {
                review.pick(&id, event);
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
        return view().items_center().child(area().selection_menu(actions).child(line)).into_element();
    }
    view()
        .items_center()
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
                            set_clipboard(shown);
                        }
                    })),
            ),
        )
        .into_element()
}

fn loop_handle(review: Review, cell: u64, shown: impl Fn() -> bool + 'static) -> impl IntoElement {
    let range = move || review.repeat_range();
    let count = move || range().map_or(1, |(first, last)| last - first + 1);
    let at_end = move || {
        range().is_some_and(|(_, last)| {
            review.job.with(|job| {
                job.as_ref().and_then(|job| job.document.as_ref()).is_none_or(|d| last + 1 >= d.segments.len())
            })
        })
    };
    view()
        .flex_row()
        .items_center()
        .rounded(tokens::radius)
        .bg(move || theme().primary.opacity(if review.handle_at.get().is_some() { 0.24 } else { 0.12 }))
        .test_id("repeat-handle")
        .claim_touches(TouchClaim::on_pan(PanActivation::vertical(px(4.0), px(12.0))))
        .keep_touches(true)
        .opacity(move || if shown() { 1.0_f32 } else { 0.0 })
        .on_responder_grant(move |_: &ResponderEvent| review.begin_end_drag(cell))
        .on_responder_move(move |event: &ResponderEvent| review.drag_end_to(event.gesture.position.y.0))
        .on_responder_release(move |_: &ResponderEvent| review.finish_end_drag())
        .on_responder_terminate(move |_: &ResponderEvent| review.finish_end_drag())
        .child(ui::icon_button_while(
            Icon::ChevronUp,
            tr("Repeat one sentence less"),
            Size::Sm,
            move || count() > 1,
            move || review.move_repeat_end(-1),
        ))
        .child(
            text(move || SharedString::from(count().to_string()))
                .text_xs()
                .tabular_nums()
                .font_weight(FontWeight::MEDIUM)
                .text_color(|| theme().primary)
                .select_none()
                .test_id("repeat-count"),
        )
        .child(ui::icon_button_while(
            Icon::ChevronDown,
            tr("Repeat one more sentence"),
            Size::Sm,
            move || !at_end(),
            move || review.move_repeat_end(1),
        ))
}

fn editor(review: Review) -> impl IntoElement {
    let store = review.store;
    on_key_with("escape", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        review.editing.set(None)
    });
    on_key_with("mod+enter", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        review.save_edit()
    });
    let editing = move || review.editing.get_untracked();
    let original = move || review.editing.with(|e| e.as_ref().is_some_and(|e| e.original));
    let translation = move || review.editing.with(|e| e.as_ref().is_some_and(|e| e.translation));
    let can_retranslate = move || {
        translation()
            && !review.job.with(|job| {
                job.as_ref()
                    .is_some_and(|job| job.translation_state.status == listenook_core::TranslationStatus::Translating)
            })
            && store.setting(|s| s.llm_provider_settings.validate().is_none())
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
            text_area(review.translation_draft, SharedString::default)
                .auto_focus(!untracked(original))
                .text_sm()
                .test_id("translation-editor")
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
                .child(when(
                    move || original() || can_retranslate(),
                    move || {
                        let open = signal(false);
                        ui::menu_with(open, ui::menu_trigger(Icon::More, tr("More sentence actions"), Size::Sm, open))
                            .child(when(can_retranslate, move || {
                                ui::menu_action(Icon::Languages, l("Translate again"), move || {
                                    if let Some(Editing { segment_id, .. }) = editing() {
                                        let target = store
                                            .job_now(&review.id())
                                            .map(|job| job.translation_state.target_language.clone());
                                        let target = target.filter(|t| !t.is_empty()).unwrap_or_else(|| "en".into());
                                        llm::start_translation(&review.id(), &target, Some(vec![segment_id]));
                                        review.editing.set(None);
                                    }
                                })
                            }))
                            .child(when(move || original() && can_retranslate(), ui::menu_divider))
                            .child(when(original, move || {
                                ui::menu_action(Icon::Scissors, l("Skip this sentence"), move || review.skip_editing())
                            }))
                            .child(when(original, move || {
                                ui::menu_action(Icon::Scissors, l("Skip from here…"), move || {
                                    review.skip_editing_onward()
                                })
                            }))
                            .child(when(original, ui::menu_divider))
                            .child(when(original, move || {
                                ui::menu_danger(Icon::Trash, l("Delete sentence"), move || review.delete_editing())
                            }))
                    },
                ))
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
