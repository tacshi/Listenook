use std::rc::Rc;

use listenook_core::{
    Job, JobSourceOrigin, JobStatus, TRANSLATION_LANGUAGES, TranscriptionProvider, TranslationStatus,
    format::{clock, date},
    l10n::status_label,
};
use nsh_base::theme;
use nsh_core::{element::Position, prelude::*};

use super::dialogs::{JobDialog, export_dialog, group_dialog, rename_dialog, tags_dialog};
use crate::{
    platform,
    services::{llm, local, podcasts, transcribe},
    shell::top_bar,
    state::{Filter, error_text, l, secrets, store, tr},
    ui::{
        self, Icon, Size, Status, Variant, button, confirm_destructive, empty_state, field, hint, icon_of,
        icon_text_button, menu_action, menu_danger, menu_divider, popover, progress_bar, search_field, select,
        separator, switch, text_area, text_field,
        tokens::{self, motion},
    },
    util,
};

#[derive(Clone, Copy)]
struct Dialogs {
    export: JobDialog,
    rename: JobDialog,
    group: JobDialog,
    tags: JobDialog,
}

pub(crate) fn library() -> impl IntoElement {
    let store = store();
    let query = signal(String::new());
    let dialogs =
        Dialogs { export: JobDialog::new(), rename: JobDialog::new(), group: JobDialog::new(), tags: JobDialog::new() };
    let shown = computed(move || {
        let needle = query.with(|q| q.trim().to_lowercase());
        store
            .library()
            .into_iter()
            .filter(|job| {
                needle.is_empty()
                    || job.title().to_lowercase().contains(&needle)
                    || job.file_name().to_lowercase().contains(&needle)
            })
            .collect::<Vec<Rc<Job>>>()
    });
    let waiting = move || store.jobs().iter().filter(|job| job.status.is_transcribable()).count();
    on_key("mod+enter", move |_| transcribe::start_ready());
    view()
        .flex_1()
        .child(
            top_bar()
                .child(search_field(query, l("Search your library")).flex_1().min_w(px(96.0)).max_w(px(420.0)).window_drag(false))
                .child(view().style_with(|s| if crate::shell::page_narrow() { s } else { s.flex_1() }))
                .child(when(
                    move || waiting() > 0,
                    move || {
                        view()
                            .flex_row()
                            .items_center()
                            .gap_1()
                            .window_drag(false)
                            .child(
                                icon_text_button(Variant::Primary, Size::Sm, Icon::Transcribe, move || -> SharedString {
                                    if crate::shell::page_narrow() {
                                        waiting().to_string().into()
                                    } else {
                                        format!("{} ({})", tr("Transcribe all"), waiting()).into()
                                    }
                                })
                                .on_press(transcribe::start_ready),
                            )
                            .child({
                                let open = signal(false);
                                popover(
                                    ui::menu_trigger(Icon::Tune, tr("Transcription options"), Size::Sm, open),
                                    || options().into_element(),
                                )
                                .open(move || Some(open.get()))
                                .on_open_change(move |event: &nsh_base::PopoverEvent| {
                                    if let nsh_base::PopoverEvent::OpenChange(next, _) = event {
                                        open.set(*next);
                                    }
                                })
                            })
                    },
                ))
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .gap_1()
                        .window_drag(false)
                        .child(when(
                            || !crate::shell::system_header(),
                            || ui::icon_button(Icon::Plus, tr("Add media…"), Size::Sm, util::pick_media),
                        ))
                        .child(ui::icon_button(Icon::Devices, tr("Sync with another device…"), Size::Sm, move || {
                            store.sync.show()
                        }))
                        .child(ui::icon_button(Icon::Export, tr("Export shown as ZIP…"), Size::Sm, move || {
                            super::dialogs::export_zip(shown.get_untracked())
                        })),
                ),
        )
        .child(
            when(
                move || store.jobs().is_empty(),
                || {
                    empty_state(
                        Icon::Wave,
                        move || tr(if platform::is_phone() { "Add audio or video" } else { "Drop audio or video here" }),
                        move || {
                            tr(if cfg!(target_os = "ios") {
                                "Choose audio or video from the Files app. Up to 5 hours each."
                            } else if platform::is_phone() {
                                "Put files in the Listenook folder in the Files app, then tap Add media. Up to 5 hours each."
                            } else {
                                "A subtitle file with the same name becomes its transcript. Up to 5 hours each."
                            })
                        },
                        icon_text_button(Variant::Primary, Size::Md, Icon::Plus, l("Add media…"))
                            .on_press(util::pick_media),
                    )
                },
            )
            .otherwise(move || {
                virtual_list(move || shown.with(Vec::len), move |at| row(shown, at, dialogs))
                    .keys(move || shown.with(|jobs| jobs.iter().map(|job| job.id.clone()).collect::<Vec<_>>()))
                    .estimated_item_size(px(64.0))
                    .content_padding(px(ui::PAGE_INSET - 12.0))
                    .empty(
                        text(move || {
                            if query.with(|q| !q.trim().is_empty()) {
                                return tr("No recordings match your search.");
                            }
                            tr(match store.filter() {
                                Filter::All => "No recordings match your search.",
                                Filter::InProgress => "Nothing is waiting or being transcribed.",
                                Filter::Group(_) => "No recordings in this group. Add one with Group… in its menu.",
                                Filter::Tag(_) => "No recordings carry this tag. Add it with Tags… in a recording's menu.",
                            })
                        })
                        .text_sm()
                        .p(px(ui::PAGE_INSET))
                        .text_color(|| theme().muted_foreground),
                    )
                    .flex_1()
            }),
        )
        .child(export_dialog(dialogs.export))
        .child(rename_dialog(dialogs.rename))
        .child(group_dialog(dialogs.group))
        .child(tags_dialog(dialogs.tags))
}

fn status_of(job: &Job) -> Status {
    match job.status {
        JobStatus::Failed | JobStatus::MissingSource => Status::Danger,
        JobStatus::Empty | JobStatus::Cancelled => Status::Warning,
        _ if job.is_busy() => Status::Active,
        _ => Status::Neutral,
    }
}

fn kind_icon(job: &Job) -> Icon {
    if matches!(job.status, JobStatus::Failed | JobStatus::MissingSource | JobStatus::Empty) {
        Icon::Alert
    } else if job.source_origin == JobSourceOrigin::Podcast {
        Icon::Podcast
    } else if job.has_video()
        || matches!(listenook_core::subtitles::extension(&job.source_path).as_str(), "mp4" | "mkv" | "avi")
    {
        Icon::Film
    } else {
        Icon::Headphones
    }
}

fn detail(job: &Job) -> SharedString {
    if let Some(code) = job.error_code.as_deref().filter(|_| !job.status.is_active() && !job.has_transcript()) {
        return error_text(code);
    }
    let translating = job.translation_state.status == TranslationStatus::Translating;
    let mut parts = Vec::new();
    if job.status.is_transcribable() {
        parts.push(tr("Not transcribed").to_string());
    } else if job.status.is_active() || !job.has_transcript() {
        parts.push(tr(status_label(job.status)).to_string());
    } else if translating {
        let state = &job.translation_state;
        parts.push(format!("{} {}/{}", tr("Translating"), state.completed_segments, state.total_segments));
    }
    if job.duration_ms() > 0 {
        parts.push(clock(job.duration_ms()));
    }
    if job.has_transcript() && !translating {
        if job.document.as_ref().is_some_and(|d| d.segments.iter().any(|s| s.has_translation())) {
            parts.push(tr("Bilingual").to_string());
        }
        if job.ai_brief.is_some() {
            parts.push(tr("AI Brief").to_string());
        }
    }
    if let Some(podcast) = &job.podcast_provenance {
        parts.push(podcast.show_title.clone());
    }
    parts.push(date(&job.created_at));
    parts.join(" · ").into()
}

fn row(shown: Memo<Vec<Rc<Job>>>, at: Position, dialogs: Dialogs) -> impl IntoElement {
    let store = store();
    let job = computed(move || shown.with(|jobs| jobs.get(at.index()).cloned()));
    let read = move |f: fn(&Job) -> bool| job.with(|job| job.as_deref().is_some_and(f));
    let id = move || job.with_untracked(|job| job.as_ref().map(|job| job.id.clone()).unwrap_or_default());
    let status = move || job.with(|job| job.as_deref().map_or(Status::Neutral, status_of));
    let busy = move || read(Job::is_busy);
    let tags = computed(move || {
        let carried = job.with(|job| job.as_ref().map(|job| job.tag_ids.clone()).unwrap_or_default());
        if carried.is_empty() {
            return Vec::new();
        }
        store.catalog().tags.into_iter().filter(|tag| carried.contains(&tag.id)).map(|tag| tag.name).collect::<Vec<_>>()
    });
    let more_open = signal(false);
    view()
        .flex_row()
        .items_center()
        .gap_1()
        .child(
            ui::list_row(|| false)
                .disabled(move || !read(Job::has_transcript))
                .on_press(move || store.open_transcript(&id()))
                .flex_1()
                .min_w(px(0.0))
                .child(
                    view()
                        .size(px(36.0))
                        .items_center()
                        .justify_center()
                        .rounded(tokens::radius)
                        .transition_colors()
                        .duration(motion::BASE)
                        .bg(move || status().color().opacity(0.12))
                        .text_color(move || status().color())
                        .child(icon_of(
                            move || job.with(|job| job.as_deref().map_or(Icon::Headphones, kind_icon)),
                            18.0,
                        )),
                )
                .child(
                    view()
                        .flex_1()
                        .min_w(px(0.0))
                        .gap_0p5()
                        .child(
                            view()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(
                                    text(move || {
                                        job.with(|job| {
                                            job.as_ref().map(|job| SharedString::from(job.title())).unwrap_or_default()
                                        })
                                    })
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .number_of_lines(1)
                                    .flex_shrink(1.0)
                                    .min_w(px(0.0))
                                    .text_color(move || {
                                        if read(Job::has_transcript) {
                                            theme().foreground
                                        } else {
                                            theme().muted_foreground
                                        }
                                    }),
                                )
                                .child(dynamic(move || {
                                    let names = tags.get();
                                    view()
                                        .flex_row()
                                        .flex_shrink_0()
                                        .gap_1()
                                        .children(names.into_iter().map(|name| {
                                            view()
                                                .px_1p5()
                                                .py(px(1.0))
                                                .rounded(tokens::radius_sm)
                                                .bg(|| theme().muted)
                                                .child(
                                                    text(SharedString::from(name))
                                                        .text_xs()
                                                        .number_of_lines(1)
                                                        .text_color(|| theme().muted_foreground),
                                                )
                                        }))
                                        .into_element()
                                })),
                        )
                        .child(
                            text(move || job.with(|job| job.as_deref().map(detail).unwrap_or_default()))
                                .text_xs()
                                .number_of_lines(1)
                                .text_color(move || {
                                    if status() == Status::Danger {
                                        theme().destructive
                                    } else {
                                        theme().muted_foreground
                                    }
                                }),
                        )
                        .child(when(busy, move || {
                            progress_bar(move || {
                                job.with(|job| {
                                    let job = job.as_ref()?;
                                    if job.translation_state.status == TranslationStatus::Translating {
                                        let state = &job.translation_state;
                                        Some(state.completed_segments as f32 / state.total_segments.max(1) as f32)
                                    } else {
                                        job.progress.fraction.map(|fraction| fraction as f32)
                                    }
                                })
                            })
                            .mt_1()
                        })),
                ),
        )
        .child(when(
            move || read(|job| job.status.is_transcribable()),
            move || button(Variant::Outline, Size::Sm, l("Transcribe")).on_press(move || transcribe::start(&id())),
        ))
        .child(when(busy, move || {
            button(Variant::Ghost, Size::Sm, l("Cancel")).on_press(move || {
                let id = id();
                llm::cancel_translation(&id);
                llm::cancel_brief(&id);
                if store.job_now(&id).is_some_and(|job| job.status.is_active()) {
                    transcribe::cancel(&id);
                }
            })
        }))
        .child(when(
            move || read(|job| job.status.is_retryable() && !job.has_transcript()),
            move || {
                button(Variant::Outline, Size::Sm, l("Retry")).on_press(move || {
                    let id = id();
                    let failed_download = store
                        .job_now(&id)
                        .is_some_and(|job| job.error_code.as_deref() == Some("podcast_download_failed"));
                    if failed_download { podcasts::download(&id) } else { transcribe::retry(&id) }
                })
            },
        ))
        .child(
            ui::menu_with(more_open, ui::menu_trigger(Icon::More, tr("More actions"), Size::Sm, more_open))
            .child(menu_action(Icon::Pencil, l("Rename…"), move || dialogs.rename.show(&id())))
            .child(menu_action(Icon::Folder, l("Group…"), move || dialogs.group.show(&id())))
            .child(menu_action(Icon::Tag, l("Tags…"), move || dialogs.tags.show(&id())))
            .child(menu_action(Icon::Export, l("Export…"), move || {
                if store.job_now(&id()).is_some_and(|job| job.has_transcript()) {
                    dialogs.export.show(&id());
                } else {
                    ui::toast(ui::Tone::Info, tr("There is no transcript to export yet."));
                }
            }))
            .child(when(
                || !platform::is_phone(),
                move || menu_action(Icon::Languages, l("Use a subtitle file…"), move || util::attach_subtitles(id())),
            ))
            .child(when(
                move || {
                    store
                        .job(&id())
                        .is_some_and(|job| job.status == listenook_core::JobStatus::Completed && local::can_align(&job))
                },
                move || menu_action(Icon::Wave, l("Time the words"), move || transcribe::align(&id())),
            ))
            .child(when(
                || !platform::is_phone(),
                move || {
                    menu_action(
                        Icon::Open,
                        l(if cfg!(target_os = "macos") { "Show in Finder" } else { "Show in folder" }),
                        move || {
                            if let Some(job) = store.job_now(&id()) {
                                util::reveal(job.source_path.clone());
                            }
                        },
                    )
                },
            ))
            .child(when(
                || !platform::is_phone() || cfg!(target_os = "ios"),
                move || menu_action(Icon::Refresh, l("Relink media…"), move || util::relink(id())),
            ))
            .child(when(
                move || {
                    store.job(&id()).is_some_and(|job| {
                        job.source_origin == JobSourceOrigin::Podcast && std::path::Path::new(&job.source_path).exists()
                    })
                },
                move || {
                    menu_action(Icon::Export, l("Save episode as…"), move || {
                        if let Some(job) = store.job_now(&id()) {
                            util::save_copy(job.source_path.clone());
                        }
                    })
                },
            ))
            .child(menu_divider())
            .child(menu_danger(Icon::Trash, l("Remove…"), move || {
                let id = id();
                let Some(job) = store.job_now(&id) else {
                    return;
                };
                let owned =
                    store.data_root().is_some_and(|root| std::path::Path::new(&job.source_path).starts_with(root));
                if !job.has_transcript() && !owned && !job.status.is_active() {
                    store.remove_job(&id);
                    return;
                }
                confirm_destructive(
                    format!("{} “{}”?", tr("Remove"), job.title()),
                    tr(if owned {
                        "Its transcript, translation and AI Brief are deleted, and so is Listenook’s copy of the media."
                    } else {
                        "Its transcript, translation and AI Brief are deleted. The media file stays where it is."
                    }),
                    tr("Cancel"),
                    tr("Remove"),
                    move || store.remove_job(&id),
                );
            })),
        )
}

fn options() -> impl IntoElement {
    let store = store();
    let provider = move || store.setting(|s| s.default_transcription_provider);
    let is_local = move || local::is_local(provider());
    let has_key = move || match provider() {
        TranscriptionProvider::MossPro => secrets::read(secrets::Secret::Moss).is_some(),
        TranscriptionProvider::Soniox => secrets::read(secrets::Secret::Soniox).is_some(),
        other => local::provider_ready(other),
    };
    let mut providers: Vec<(SharedString, SharedString)> =
        vec![("soniox".into(), "Soniox".into()), ("mossPro".into(), "MOSS Pro".into())];
    if local::offered(TranscriptionProvider::Qwen3Local) {
        providers.push((
            "qwen3Local".into(),
            tr(if cfg!(target_os = "macos") { "Qwen3 — on this Mac" } else { "Qwen3 — on this device" }),
        ));
    }
    if local::offered(TranscriptionProvider::MossLocal) {
        providers.push((
            "mossLocal".into(),
            tr(if cfg!(target_os = "macos") { "MOSS — on this Mac" } else { "MOSS — on this device" }),
        ));
    }
    let languages: Vec<(SharedString, SharedString)> =
        TRANSLATION_LANGUAGES.iter().map(|(code, name)| ((*code).into(), (*name).into())).collect();
    view()
        .gap_4()
        .child(
            field(
                l("Provider"),
                select(
                    "Provider",
                    providers,
                    move || SharedString::from(provider().as_str()),
                    move |value| {
                        store.update_settings(|s| {
                            s.default_transcription_provider = TranscriptionProvider::parse(&value)
                        })
                    },
                ),
            )
            .child(when(
                move || !has_key(),
                move || {
                    view()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(
                            hint(move || {
                                tr(if is_local() {
                                    "This model is not downloaded yet."
                                } else {
                                    "This provider has no API key yet."
                                })
                            })
                            .flex_1(),
                        )
                        .child(
                            button(Variant::Outline, Size::Sm, l("Settings"))
                                .on_press(move || store.settings_open().set(true)),
                        )
                },
            )),
        )
        .child(when(
            move || provider() != TranscriptionProvider::MossPro,
            move || {
                view()
                    .gap_4()
                    .child(
                        field(l("Language hints"), text_field(store.language_hints(), || "en, zh, ja".into()))
                            .child(hint(l("Language codes separated by commas. Leave empty to detect automatically."))),
                    )
                    .child(field(
                        l("Names and context terms"),
                        text_area(store.context_terms(), l("Product names, people, acronyms…")),
                    ))
            },
        ))
        .child(separator())
        .child(switch(
            l("Translate after transcription"),
            move || store.setting(|s| s.translation_preferences.auto_translate),
            move |on| store.update_settings(|s| s.translation_preferences.auto_translate = on),
        ))
        .child(when(
            move || store.setting(|s| s.translation_preferences.auto_translate),
            move || {
                field(
                    l("Target language"),
                    select(
                        "Target language",
                        languages.clone(),
                        move || {
                            let target = store.setting(|s| s.translation_preferences.target_language.clone());
                            SharedString::from(if target.is_empty() { "en".to_owned() } else { target })
                        },
                        move |value| {
                            store.update_settings(|s| s.translation_preferences.target_language = value.to_string())
                        },
                    ),
                )
            },
        ))
}
