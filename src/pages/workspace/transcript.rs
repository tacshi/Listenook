use listenook_core::{ContentMode, Segment, format::clock, highlights};
use nsh_base::theme;
use nsh_core::{element::Position, prelude::*};

use super::{
    review::{Editing, Review},
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
    let reveal = move |segment: usize, animated: bool| {
        if review.editing.get_untracked().is_some() {
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
                .flex_1(),
        )
        .child(speaker_dialog(review, speaker))
}

fn row(review: Review, at: Position, speaker_dialog: Signal<Option<String>>) -> impl IntoElement {
    let store = review.store;
    let index = computed(move || review.shown.with(|shown| shown.get(at.index()).copied()));
    let segment = computed(move || index.get().and_then(|index| review.segment(index)));
    let read = move |f: fn(&Segment) -> SharedString| segment.with(|s| s.as_ref().map(f).unwrap_or_default());
    let id = move || segment.with(|s| s.as_ref().map(|s| s.id.clone()));
    let is_current = move || index.get().is_some() && index.get() == review.scrubbed.get().or_else(|| review.target());
    let is_repeating = move || id().is_some() && id() == review.repeating.get();
    let picked = move || review.picked_in(id().as_deref());
    let editing = move |translation: bool| {
        review.editing.with(|editing| {
            editing.as_ref().is_some_and(|e| Some(&e.segment_id) == id().as_ref() && e.translation == translation)
        })
    };
    let words = computed(move || if is_current() { index.get().and_then(|index| review.words(index)) } else { None });
    let said = computed(move || {
        let position = review.position_ms.get();
        words.with(|words| {
            let words = words.as_ref()?;
            words.partition_point(|(_, start, _)| *start <= position).checked_sub(1)
        })
    });
    let hidden = move || review.blind() && (id().is_none() || review.revealed.get() != id());
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
            review.jump_to(index);
        }
    };
    let toggle_repeat = move || {
        if let Some(index) = index.get_untracked() {
            review.toggle_repeat(index);
        }
    };
    let edit_shown = move || {
        if let Some(index) = index.get_untracked() {
            review.edit(index, untracked(mode) == ContentMode::Translated && untracked(translated));
        }
    };
    let edit_translation = move || {
        if let Some(index) = index.get_untracked() {
            review.edit(index, true);
        }
    };
    let line = view()
        .w_full()
        .max_w(px(760.0))
        .rounded(tokens::radius)
        .transition_colors()
        .duration(motion::BASE)
        .bg(move || if is_current() { tokens::highlight() } else { theme().background })
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
                        .child(when(move || editing(false) || editing(true), move || editor(review)).otherwise(
                            move || {
                                nsh_base::button()
                                    .on_press(press)
                                    .rounded(tokens::radius_sm)
                                    .focus_visible(tokens::focus_ring)
                                    .child(ui::veil(hidden, move || {
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
                                                                                listenook_core::local::lead_and_word(
                                                                                    &word,
                                                                                );
                                                                            let word = text(SharedString::from(
                                                                                word.to_owned(),
                                                                            ));
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
                                                                                    word.rounded(tokens::radius_sm).bg(
                                                                                        || theme().primary.opacity(0.3),
                                                                                    )
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
                                                text(move || {
                                                    read(|s| s.translated_text.clone().unwrap_or_default().into())
                                                })
                                                .select_none()
                                                .line_height(nsh_core::LineHeight::Multiple(1.5))
                                                .style_with(move |s| {
                                                    if mode() == ContentMode::Translated {
                                                        s.text_base()
                                                    } else {
                                                        s.text_sm()
                                                    }
                                                })
                                                .text_color(
                                                    move || {
                                                        if mode() == ContentMode::Translated {
                                                            theme().foreground
                                                        } else {
                                                            theme().muted_foreground
                                                        }
                                                    },
                                                )
                                            }))
                                    }))
                            },
                        )),
                )
                .child(
                    view()
                        .flex_row()
                        .gap_1()
                        .transition_opacity()
                        .duration(motion::INSTANT)
                        .opacity(move || if is_current() || is_repeating() || picked() { 1.0_f32 } else { 0.0 })
                        .group_hover(|s| s.opacity(1.0))
                        .child(when(picked, move || {
                            ui::toggle_button(
                                Variant::Ghost,
                                Icon::Bold,
                                tr("Highlight"),
                                Size::Sm,
                                move || review.picked_marked(),
                                move || review.toggle_highlight(),
                            )
                            .self_start()
                        }))
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
                        .child(icon_button(Icon::Pencil, tr("Edit"), Size::Sm, edit_shown).self_start())
                        .child(when(
                            move || mode() == ContentMode::Bilingual && translated(),
                            move || {
                                icon_button(Icon::Languages, tr("Edit translation"), Size::Sm, edit_translation)
                                    .self_start()
                            },
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
        return view().items_center().child(area().child(line)).into_element();
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
                    .child(ui::menu_divider())
                    .child(ui::menu_action(Icon::Pencil, l("Edit"), edit_shown))
                    .child(when(
                        move || mode() == ContentMode::Bilingual && translated(),
                        move || ui::menu_action(Icon::Languages, l("Edit translation"), edit_translation),
                    ))
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

fn editor(review: Review) -> impl IntoElement {
    let store = review.store;
    on_key_with("escape", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        review.editing.set(None)
    });
    on_key_with("mod+enter", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        review.save_edit()
    });
    let editing = move || review.editing.get_untracked();
    view()
        .gap_2()
        .child(
            text_area(review.draft, SharedString::default)
                .auto_focus(true)
                .on_selection_change(move |selection: &Selection| review.caret.set(selection.start))
                .test_id("segment-editor"),
        )
        .child(
            view()
                .flex_row()
                .gap_2()
                .child(button(Variant::Outline, Size::Sm, l("Cancel")).on_press(move || review.editing.set(None)))
                .child(button(Variant::Primary, Size::Sm, l("Save")).on_press(move || review.save_edit()))
                .child(when(
                    move || review.editing.with(|e| e.as_ref().is_some_and(|e| !e.translation)),
                    move || {
                        view()
                            .flex_row()
                            .gap_2()
                            .child(
                                button(Variant::Ghost, Size::Sm, l("Split at cursor"))
                                    .on_press(move || review.split_editing()),
                            )
                            .child(
                                button(Variant::Ghost, Size::Sm, l("Merge with next"))
                                    .disabled(move || !review.can_merge_editing())
                                    .on_press(move || review.merge_editing()),
                            )
                    },
                ))
                .child(when(
                    move || review.editing.with(|e| e.as_ref().is_some_and(|e| !e.translation)),
                    move || {
                        view().flex_1().flex_row().justify_end().child(ui::icon_button_as(
                            Variant::Danger,
                            Icon::Trash,
                            tr("Delete sentence"),
                            Size::Sm,
                            move || review.delete_editing(),
                        ))
                    },
                ))
                .child(when(
                    move || {
                        review.editing.with(|e| e.as_ref().is_some_and(|e| e.translation))
                            && !review.job.with(|job| {
                                job.as_ref().is_some_and(|job| {
                                    job.translation_state.status == listenook_core::TranslationStatus::Translating
                                })
                            })
                            && store.setting(|s| s.llm_provider_settings.validate().is_none())
                    },
                    move || {
                        button(Variant::Ghost, Size::Sm, l("Translate again")).on_press(move || {
                            if let Some(Editing { segment_id, .. }) = editing() {
                                let target = store
                                    .job_now(&review.id())
                                    .map(|job| job.translation_state.target_language.clone());
                                let target = target.filter(|t| !t.is_empty()).unwrap_or_else(|| "en".into());
                                llm::start_translation(&review.id(), &target, Some(vec![segment_id]));
                                review.editing.set(None);
                            }
                        })
                    },
                )),
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
