use listenook_core::{
    AiBrief, AiBriefSection, AiGenerationStatus, AiInsightType, AiLanguageNote, AiLanguageNoteKind, AiLearningLevel,
    TRANSLATION_LANGUAGES,
    brief::BriefRequest,
    export,
    format::{clock, safe_file_name},
    highlights,
};
use nsh_base::theme;
use nsh_core::prelude::*;

use super::review::{BriefPart, Review, Side};
use crate::{
    pages::dialogs::save_text,
    services::llm,
    state::{error_text, l, tr},
    ui::{
        Icon, Size, Tone, Variant, button, card, checkbox, empty_state, field, hint, icon, icon_button,
        icon_text_button, menu, menu_action, modal, modal_actions, progress_bar, section, select, text_area,
        text_field, toast,
        tokens::{self, motion},
    },
};

fn section_label(section: AiBriefSection) -> &'static str {
    match section {
        AiBriefSection::Overview => "Overview",
        AiBriefSection::Chapters => "Chapters",
        AiBriefSection::KeyIdeas => "Key ideas",
        AiBriefSection::Decisions => "Decisions",
        AiBriefSection::ActionItems => "Action items",
        AiBriefSection::OpenQuestions => "Open questions",
        AiBriefSection::LanguageNotes => "Language notes",
    }
}

pub(super) fn brief_pane(review: Review, dialog: Signal<bool>) -> impl IntoElement {
    let store = review.store;
    let state =
        move || review.job.with(|job| job.as_ref().map(|job| job.ai_generation_state.clone()).unwrap_or_default());
    let generating = move || state().status == AiGenerationStatus::Generating;
    let brief = computed(move || review.job.with(|job| job.as_ref().and_then(|job| job.ai_brief.clone())));
    let configured = computed(move || store.setting(|s| s.llm_provider_settings.validate().is_none()));
    let unseen = move || {
        review.job.with(|job| {
            let Some(job) = job.as_ref() else {
                return 0;
            };
            match (job.document.as_ref(), job.ai_brief.as_ref()) {
                (Some(document), Some(brief)) => highlights::unseen(document, &brief.highlights_seen),
                _ => 0,
            }
        })
    };
    let error = move || {
        Some(state())
            .filter(|s| s.status == AiGenerationStatus::Failed)
            .and_then(|s| s.error_code)
            .map(|code| error_text(&code))
    };
    view().flex_1().min_h(px(0.0)).child(dynamic(move || {
        let (has_brief, generating) = (brief.with(Option::is_some), generating());
        untracked(|| {
            if generating {
                return view()
                    .flex_1()
                    .items_center()
                    .justify_center()
                    .gap_4()
                    .p_8()
                    .child(
                        text(move || match state().stage.as_str() {
                            "synthesizing" => tr("Organizing the brief…"),
                            "studying" => tr("Reading your highlights…"),
                            _ => tr("Analyzing the transcript…"),
                        })
                        .text_sm()
                        .text_color(|| theme().muted_foreground),
                    )
                    .child(
                        progress_bar(move || {
                            let state = state();
                            (state.total_chunks > 1).then(|| state.completed_chunks as f32 / state.total_chunks as f32)
                        })
                        .w(px(280.0)),
                    )
                    .child(button(Variant::Outline, Size::Md, l("Cancel")).on_press(move || llm::cancel_brief(&review.id())))
                    .into_element();
            }
            if !has_brief {
                return empty_state(
                    Icon::Sparkles,
                    l("No AI Brief yet"),
                    move || {
                        error().unwrap_or_else(|| {
                            if configured.get() {
                                tr("Create an evidence-backed overview, chapters, decisions, actions, and open questions.")
                            } else {
                                tr("Configure the AI provider in Settings before creating a brief.")
                            }
                        })
                    },
                    dynamic(move || {
                        let configured = configured.get();
                        untracked(|| {
                            if configured {
                                icon_text_button(Variant::Primary, Size::Md, Icon::Sparkles, l("Create AI Brief"))
                                    .on_press(move || dialog.set(true))
                                    .into_element()
                            } else {
                                button(Variant::Default, Size::Md, l("Open Settings"))
                                    .on_press(move || store.settings_open().set(true))
                                    .into_element()
                            }
                        })
                    }),
                )
                .into_element();
            }
            scroll()
                .flex_1()
                .child(
                    view()
                        .p_4()
                        .gap_6()
                        .child(
                            view()
                                .flex_row()
                                .flex_wrap()
                                .items_center()
                                .gap_2()
                                .child(hint(l("AI-generated draft · verify against evidence")).w_full())
                                .child(button(Variant::Ghost, Size::Sm, l("Copy")).on_press(move || {
                                    if let (Some(job), Some(brief)) = (store.job_now(&review.id()), brief.get_untracked()) {
                                        set_clipboard(export::export_brief(&job, &brief));
                                        toast(Tone::Success, tr("AI Brief copied"));
                                    }
                                }))
                                .child(
                                    menu(button(Variant::Ghost, Size::Sm, l("Export…")))
                                        .child(menu_action(Icon::Export, l("AI Brief (Markdown)…"), move || {
                                            if let (Some(job), Some(brief)) =
                                                (store.job_now(&review.id()), brief.get_untracked())
                                            {
                                                let name =
                                                    format!("{} - brief.md", safe_file_name(&job.title(), "transcript"));
                                                save_text(name, export::export_brief(&job, &brief));
                                            }
                                        }))
                                        .child(when(
                                            move || brief.with(|b| b.as_ref().is_some_and(|b| !b.language_notes.is_empty())),
                                            move || {
                                                menu_action(Icon::Export, l("Flashcards (CSV)…"), move || {
                                                    if let (Some(job), Some(brief)) =
                                                        (store.job_now(&review.id()), brief.get_untracked())
                                                    {
                                                        save_text(
                                                            export::flashcards_file_name(&job),
                                                            export::export_flashcards(&job, &brief),
                                                        );
                                                    }
                                                })
                                            },
                                        )),
                                )
                                .child(
                                    icon_text_button(Variant::Outline, Size::Sm, Icon::Refresh, l("Refresh AI Brief"))
                                        .on_press(move || dialog.set(true)),
                                ),
                        )
                        .child(when(move || error().is_some(), move || {
                            text(move || error().unwrap_or_default()).text_sm().text_color(|| theme().destructive)
                        }))
                        .child(when(move || unseen() > 0, move || {
                            card()
                                .p_3()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(icon(Icon::Bold, 14.0))
                                .child(
                                    text(move || -> SharedString {
                                        format!("{} {}", unseen(), tr("new highlights since this brief")).into()
                                    })
                                    .flex_1()
                                    .text_sm()
                                    .text_color(|| theme().foreground),
                                )
                                .child(button(Variant::Outline, Size::Sm, l("Refresh")).on_press(move || dialog.set(true)))
                        }))
                        .child(dynamic(move || {
                            let Some(brief) = brief.get() else {
                                return view().into_element();
                            };
                            untracked(|| content(review, &brief).into_element())
                        })),
                )
                .into_element()
        })
    }))
}

fn evidence(review: Review, ids: &[String]) -> impl IntoElement {
    let moments: Vec<(usize, i64)> = review.job.with_untracked(|job| {
        let Some(document) = job.as_ref().and_then(|job| job.document.as_ref()) else {
            return Vec::new();
        };
        document
            .segments
            .iter()
            .enumerate()
            .filter(|(_, segment)| ids.contains(&segment.id))
            .map(|(index, segment)| (index, segment.start_ms))
            .take(6)
            .collect()
    });
    view().flex_row().flex_wrap().gap_1().children(moments.into_iter().map(move |(index, start_ms)| {
        nsh_base::button()
            .accessibility_label(format!("Play from {}", clock(start_ms)))
            .on_press(move || review.play_from(index))
            .flex_row()
            .items_center()
            .gap_1()
            .h(px(24.0))
            .px_2()
            .rounded(tokens::radius_sm)
            .bg(|| theme().muted)
            .text_color(|| theme().muted_foreground)
            .transition_colors()
            .duration(motion::INSTANT)
            .hover(|s| s.bg(|| theme().accent))
            .active(|s| s.bg(|| theme().input))
            .focus_visible(tokens::focus_ring)
            .child(icon(Icon::Play, 12.0))
            .child(text(clock(start_ms)).text_xs().tabular_nums())
    }))
}

fn item(review: Review, part: BriefPart, body: impl IntoElement, ids: &[String]) -> View {
    card()
        .p_3()
        .gap_2()
        .child(view().flex_row().items_start().gap_2().child(view().flex_1().min_w(px(0.0)).child(body)).child(
            icon_button(Icon::Pencil, tr("Edit"), Size::Sm, move || review.brief_editing.set(Some(part.clone()))),
        ))
        .child(evidence(review, ids))
}

pub(super) fn edit_dialog(review: Review) -> impl IntoElement {
    let open = signal(false);
    let (title, body) = (signal(String::new()), signal(String::new()));
    let titled = move || matches!(review.brief_editing.get(), Some(BriefPart::Chapter(_) | BriefPart::Note(_)));
    effect(move || {
        let part = review.brief_editing.get();
        untracked(|| {
            let brief = review.job.with_untracked(|job| job.as_ref().and_then(|job| job.ai_brief.clone()));
            let (Some(part), Some(brief)) = (part, brief) else {
                open.set(false);
                return;
            };
            let found = match &part {
                BriefPart::Overview => Some((String::new(), brief.overview.clone())),
                BriefPart::Chapter(id) => {
                    brief.chapters.iter().find(|c| &c.id == id).map(|c| (c.title.clone(), c.summary.clone()))
                }
                BriefPart::Insight(id) => {
                    brief.insights.iter().find(|i| &i.id == id).map(|i| (String::new(), i.text.clone()))
                }
                BriefPart::Note(id) => {
                    brief.language_notes.iter().find(|n| &n.id == id).map(|n| (n.term.clone(), n.explanation.clone()))
                }
            };
            if let Some((found_title, found_body)) = found {
                batch(|| {
                    title.set(found_title);
                    body.set(found_body);
                    open.set(true);
                });
            }
        });
    });
    effect(move || {
        if !open.get() {
            untracked(|| review.brief_editing.set(None));
        }
    });
    let save = move || {
        let Some(part) = review.brief_editing.get_untracked() else {
            return;
        };
        let (new_title, new_body) = (title.get_untracked().trim().to_owned(), body.get_untracked().trim().to_owned());
        let id = review.job.with_untracked(|job| job.as_ref().map(|job| job.id.clone()).unwrap_or_default());
        review.store.update_job(&id, |job| {
            let Some(brief) = &mut job.ai_brief else {
                return;
            };
            match &part {
                BriefPart::Overview => brief.overview = new_body,
                BriefPart::Chapter(id) => {
                    if let Some(chapter) = brief.chapters.iter_mut().find(|c| &c.id == id) {
                        (chapter.title, chapter.summary, chapter.edited) = (new_title, new_body, true);
                    }
                }
                BriefPart::Insight(id) => {
                    if let Some(insight) = brief.insights.iter_mut().find(|i| &i.id == id) {
                        (insight.text, insight.edited) = (new_body, true);
                    }
                }
                BriefPart::Note(id) => {
                    if let Some(note) = brief.language_notes.iter_mut().find(|n| &n.id == id) {
                        (note.term, note.explanation, note.edited) = (new_title, new_body, true);
                    }
                }
            }
            brief.edited = true;
        });
        open.set(false);
    };
    modal(
        open,
        l("Edit"),
        520.0,
        move || {
            view()
                .gap_4()
                .child(when(titled, move || field(l("Title"), text_field(title, SharedString::default))))
                .child(text_area(body, SharedString::default).h(px(180.0)))
                .into_element()
        },
        move || modal_actions(open, l("Cancel"), l("Save"), move || !body.with(|text| text.trim().is_empty()), save),
    )
}

fn body_text(content: impl Into<SharedString>) -> Text {
    text(content.into()).text_sm().line_height(nsh_core::LineHeight::Multiple(1.5)).text_color(|| theme().foreground)
}

fn labeled(label: &'static str, content: String) -> impl IntoElement {
    view()
        .gap_0p5()
        .child(text(l(label)).text_xs().font_weight(FontWeight::MEDIUM).text_color(|| theme().muted_foreground))
        .child(body_text(content))
}

fn language_note(review: Review, note: &AiLanguageNote) -> View {
    let kind_label = match note.kind {
        AiLanguageNoteKind::Vocabulary => "Vocabulary",
        AiLanguageNoteKind::Expression => "Expression",
        AiLanguageNoteKind::Grammar => "Grammar",
    };
    let marked = note.highlight.clone().filter(|marked| marked.to_lowercase() != note.term.to_lowercase());
    item(
        review,
        BriefPart::Note(note.id.clone()),
        view()
            .gap_2()
            .child(
                view()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(
                        text(note.term.clone())
                            .text_sm()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(|| theme().foreground),
                    )
                    .child(hint(l(kind_label))),
            )
            .child(marked.map(|marked| -> AnyElement {
                hint(SharedString::from(format!("{} “{marked}”", tr("You marked")))).into_element()
            }))
            .child(body_text(note.explanation.clone()))
            .child((!note.usage.is_empty()).then(|| labeled("How to use", note.usage.clone())))
            .child((!note.examples.is_empty()).then(|| {
                view().gap_0p5().children(note.examples.iter().map(|example| {
                    text(example.clone())
                        .text_sm()
                        .italic()
                        .line_height(nsh_core::LineHeight::Multiple(1.5))
                        .text_color(|| theme().foreground)
                }))
            }))
            .child((!note.related.is_empty()).then(|| labeled("Related", note.related.join(", "))))
            .child((!note.pitfalls.is_empty()).then(|| labeled("Watch out", note.pitfalls.clone())))
            .child(
                text(format!("“{}”", note.source_excerpt)).text_sm().italic().text_color(|| theme().muted_foreground),
            ),
        &note.evidence_segment_ids,
    )
}

fn content(review: Review, brief: &AiBrief) -> impl IntoElement {
    let mut sections: Vec<AnyElement> = Vec::new();
    if !brief.overview.trim().is_empty() {
        sections.push(
            section(
                l("Overview"),
                item(
                    review,
                    BriefPart::Overview,
                    body_text(brief.overview.clone()),
                    &brief.overview_evidence_segment_ids,
                ),
            )
            .into_element(),
        );
    }
    if !brief.chapters.is_empty() {
        sections.push(
            section(
                l("Chapters"),
                view().gap_2().children(brief.chapters.iter().map(|chapter| {
                    item(
                        review,
                        BriefPart::Chapter(chapter.id.clone()),
                        view()
                            .gap_1()
                            .child(
                                text(chapter.title.clone())
                                    .text_sm()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(|| theme().foreground),
                            )
                            .child(body_text(chapter.summary.clone())),
                        &chapter.evidence_segment_ids,
                    )
                })),
            )
            .into_element(),
        );
    }
    let groups: [(&'static str, &[AiInsightType]); 4] = [
        ("Key ideas", &[AiInsightType::KeyIdea, AiInsightType::NotableMoment]),
        ("Decisions", &[AiInsightType::Decision]),
        ("Action items", &[AiInsightType::ActionItem]),
        ("Open questions", &[AiInsightType::OpenQuestion]),
    ];
    for (title, kinds) in groups {
        let items: Vec<_> = brief.insights.iter().filter(|insight| kinds.contains(&insight.kind)).collect();
        if items.is_empty() {
            continue;
        }
        sections.push(
            section(
                l(title),
                view().gap_2().children(items.into_iter().map(|insight| {
                    let people: Vec<String> =
                        [insight.owner.clone(), insight.deadline.clone()].into_iter().flatten().collect();
                    let marked = insight.highlighted;
                    item(
                        review,
                        BriefPart::Insight(insight.id.clone()),
                        view()
                            .gap_1()
                            .child(
                                view()
                                    .flex_row()
                                    .items_start()
                                    .gap_2()
                                    .child(marked.then(|| {
                                        view()
                                            .pt(px(3.0))
                                            .label(tr("You marked this"))
                                            .text_color(|| theme().primary)
                                            .child(icon(Icon::Bold, 14.0))
                                    }))
                                    .child(body_text(insight.text.clone()).flex_1()),
                            )
                            .child((!people.is_empty()).then(|| hint(SharedString::from(people.join(" · "))))),
                        &insight.evidence_segment_ids,
                    )
                })),
            )
            .into_element(),
        );
    }
    if !brief.language_notes.is_empty() {
        let (mine, others): (Vec<&AiLanguageNote>, Vec<&AiLanguageNote>) =
            brief.language_notes.iter().partition(|note| note.highlight.is_some());
        let group = |title: &'static str, notes: Vec<&AiLanguageNote>| -> Option<AnyElement> {
            (!notes.is_empty()).then(|| {
                view()
                    .gap_2()
                    .child(
                        text(l(title))
                            .text_xs()
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(|| theme().muted_foreground),
                    )
                    .children(notes.into_iter().map(|note| language_note(review, note)))
                    .into_element()
            })
        };
        let grouped = !mine.is_empty();
        sections.push(
            section(
                l("Language notes"),
                view()
                    .gap_4()
                    .child(
                        (!brief.learner_profile.trim().is_empty())
                            .then(|| body_text(brief.learner_profile.clone()).text_color(|| theme().muted_foreground)),
                    )
                    .child(group("From your highlights", mine))
                    .child(if grouped {
                        group("Also worth learning", others)
                    } else {
                        Some(
                            view()
                                .gap_2()
                                .children(others.into_iter().map(|note| language_note(review, note)))
                                .into_element(),
                        )
                    }),
            )
            .into_element(),
        );
    }
    view().gap_6().children(sections)
}

pub(super) fn generate_dialog(review: Review, open: Signal<bool>) -> impl IntoElement {
    let store = review.store;
    let sections = signal(BriefRequest::default_sections());
    let output = signal(SharedString::from(if store.lang().code() == "zh" { "zh-Hans" } else { "en" }));
    let level = signal(AiLearningLevel::Intermediate);
    let languages: Vec<(SharedString, SharedString)> =
        TRANSLATION_LANGUAGES.iter().map(|(code, name)| ((*code).into(), (*name).into())).collect();
    let marked =
        move || review.job.with(|job| job.as_ref().and_then(|job| job.document.as_ref()).map_or(0, highlights::count));
    effect(move || {
        if !open.get() {
            return;
        }
        untracked(|| {
            let learning = review.job.with(|job| {
                job.as_ref()
                    .and_then(|job| job.document.as_ref())
                    .is_some_and(|d| highlights::looks_like_learning(d, &output.get()))
            });
            batch(|| {
                if learning {
                    sections.update(|s| {
                        if !s.contains(&AiBriefSection::LanguageNotes) {
                            s.push(AiBriefSection::LanguageNotes);
                            s.sort();
                        }
                    });
                }
                if marked() > 0 && level.get() == AiLearningLevel::Intermediate {
                    level.set(AiLearningLevel::Auto);
                } else if marked() == 0 && level.get() == AiLearningLevel::Auto {
                    level.set(AiLearningLevel::Intermediate);
                }
            });
        });
    });
    modal(
        open,
        l("Create AI Brief"),
        460.0,
        move || {
            view()
                .gap_4()
                .child(field(
                    l("Include sections"),
                    view().gap_2().children(AiBriefSection::ALL.iter().map(move |section| {
                        let section = *section;
                        checkbox(
                            l(section_label(section)),
                            move || sections.with(|s| s.contains(&section)),
                            move |on| {
                                sections.update(|s| {
                                    s.retain(|other| *other != section);
                                    if on {
                                        s.push(section);
                                        s.sort();
                                    }
                                })
                            },
                        )
                    })),
                ))
                .child(when(
                    move || sections.with(|s| s.contains(&AiBriefSection::LanguageNotes)),
                    move || {
                        field(
                            l("Proficiency"),
                            select(
                                "Proficiency",
                                (marked() > 0)
                                    .then(|| ("auto".into(), tr("Auto (from my highlights)")))
                                    .into_iter()
                                    .chain([
                                        ("beginner".into(), "Beginner (A1–A2)".into()),
                                        ("intermediate".into(), "Intermediate (B1–B2)".into()),
                                        ("advanced".into(), "Advanced (C1–C2)".into()),
                                    ])
                                    .collect(),
                                move || SharedString::from(level.get().as_str()),
                                move |value| level.set(AiLearningLevel::parse(&value)),
                            ),
                        )
                    },
                ))
                .child(field(
                    l("Output language"),
                    select("Output language", languages.clone(), move || output.get(), move |value| output.set(value)),
                ))
                .child(when(
                    move || marked() > 0,
                    move || {
                        hint(move || -> SharedString {
                            format!(
                                "{} {} {}",
                                marked(),
                                tr("highlights ·"),
                                tr("the AI decides whether each is a word to learn or a key point.")
                            )
                            .into()
                        })
                    },
                ))
                .child(hint(move || -> SharedString {
                    format!("{} {}", tr("Model:"), store.setting(|s| s.llm_provider_settings.model.clone())).into()
                }))
                .into_element()
        },
        move || {
            modal_actions(
                open,
                l("Cancel"),
                l("Generate"),
                move || !sections.with(Vec::is_empty),
                move || {
                    let request = BriefRequest {
                        sections: sections.get_untracked(),
                        output_language: output.get_untracked().to_string(),
                        learning_language: None,
                        learning_level: level.get_untracked(),
                        model: store.settings().llm_provider_settings.model,
                        highlights: review.job.with_untracked(|job| {
                            job.as_ref()
                                .and_then(|job| job.document.as_ref())
                                .map(highlights::contexts)
                                .unwrap_or_default()
                        }),
                    };
                    llm::start_brief(&review.id(), request);
                    batch(|| {
                        review.side.set(Side::Brief);
                        open.set(false);
                    });
                },
            )
        },
    )
}
