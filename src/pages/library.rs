use std::rc::Rc;

use listenook_core::{
    Job, JobSourceOrigin, JobStatus, TRANSLATION_LANGUAGES, TranscriptionProvider, TranslationStatus, format,
    l10n::status_label,
};
use nsh_base::theme;
use nsh_core::{element::Position, prelude::*};

use super::dialogs::{ExportDialog, JobDialog, export_dialog, group_dialog, rename_dialog, tags_dialog};
use crate::services::secrets;
use crate::ui::{error_text, l, tr};
use crate::work::{ai, podcasts, timing, transcribe};
use crate::{
    pages::chrome::top_bar,
    platform,
    services::local,
    state::{AiSetup, Filter, SettingsTab, store},
    ui::{
        self, EmptyState, Icon, MenuAction, MenuChoice, MenuDanger, MenuDivider, Separator, Size, Status, TextField,
        Variant, button, confirm_destructive, field, hint, icon_of, icon_text_button, popover, progress_bar,
        search_field_ref, select, switch, text_area,
        tokens::{self, motion},
    },
    work::import,
};

#[derive(Clone, Copy)]
struct Dialogs {
    export: ExportDialog,
    rename: JobDialog,
    group: JobDialog,
    tags: JobDialog,
}

/// The order the Library lists recordings in, kept in the settings.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Sort {
    #[default]
    Added,
    Played,
    Title,
    Length,
}

impl Sort {
    const ALL: [(Sort, &'static str); 4] = [
        (Sort::Added, "Recently added"),
        (Sort::Played, "Last played"),
        (Sort::Title, "Title"),
        (Sort::Length, "Shortest first"),
    ];
    const SETTING: &'static str = "library_sort";

    fn key(self) -> &'static str {
        match self {
            Sort::Added => "added",
            Sort::Played => "played",
            Sort::Title => "title",
            Sort::Length => "length",
        }
    }

    fn saved() -> Self {
        let saved = store().setting(|s| s.extra.get(Self::SETTING).and_then(|v| v.as_str().map(str::to_owned)));
        Self::ALL
            .into_iter()
            .map(|(sort, _)| sort)
            .find(|sort| saved.as_deref() == Some(sort.key()))
            .unwrap_or_default()
    }

    fn save(self) {
        store().update_settings(|s| drop(s.extra.insert(Self::SETTING.into(), self.key().into())));
    }

    /// Never played and unknown lengths go last; ties keep the newest first.
    fn apply(self, jobs: &mut [Rc<Job>]) {
        jobs.sort_by(|a, b| b.cmp_added(a));
        match self {
            Sort::Added => {}
            Sort::Played => {
                let played = store().last_played();
                jobs.sort_by(|a, b| played.get(&b.id).cmp(&played.get(&a.id)));
            }
            Sort::Title => jobs.sort_by_cached_key(|job| job.title().to_lowercase()),
            Sort::Length => jobs.sort_by_key(|job| Some(job.duration_ms()).filter(|ms| *ms > 0).unwrap_or(i64::MAX)),
        }
    }
}

pub(crate) fn library() -> impl IntoElement {
    let store = store();
    let query = signal(String::new());
    let dialogs = Dialogs {
        export: ExportDialog::new(),
        rename: JobDialog::new(),
        group: JobDialog::new(),
        tags: JobDialog::new(),
    };
    let sort = computed(Sort::saved);
    let shown = computed(move || {
        let needle = query.with(|q| q.trim().to_lowercase());
        let mut jobs = store
            .library()
            .into_iter()
            .filter(|job| {
                needle.is_empty()
                    || job.title().to_lowercase().contains(&needle)
                    || job.file_name().to_lowercase().contains(&needle)
            })
            .collect::<Vec<Rc<Job>>>();
        sort.get().apply(&mut jobs);
        jobs
    });
    let waiting = move || store.jobs().iter().filter(|job| job.status().is_transcribable()).count();
    let search_input = element_ref();
    on_key("mod+enter", move |_| transcribe::start_ready());
    on_key("mod+f", move |_| search_input.focus());
    let options_open = signal(false);
    let sort_open = signal(false);
    view()
        .flex_1()
        .child(
            top_bar()
                .child(
                    search_field_ref(query, l("Search your library"), &search_input)
                        .flex_1()
                        .min_w(px(96.0))
                        .max_w(px(420.0))
                        .window_drag(false),
                )
                .child(view().style_with(|s| if crate::pages::chrome::page_narrow() { s } else { s.flex_1() }))
                .child(
                    view().window_drag(false).child(
                        popover(
                            ui::menu_choice_trigger(
                                Icon::Tune,
                                tr("Transcription options"),
                                engine_label,
                                Size::Sm,
                                options_open,
                                crate::pages::chrome::page_narrow,
                            ),
                            || options().into_element(),
                        )
                        .open(move || Some(options_open.get()))
                        .on_open_change(move |event: &nsh_base::PopoverEvent| {
                            if let nsh_base::PopoverEvent::OpenChange(next, _) = event {
                                options_open.set(*next);
                            }
                        }),
                    ),
                )
                .child(when(
                    move || waiting() > 0,
                    move || {
                        view().flex_row().items_center().gap_1().window_drag(false).child(
                            icon_text_button(Variant::Primary, Size::Sm, Icon::Transcribe, move || -> SharedString {
                                if crate::pages::chrome::page_narrow() {
                                    waiting().to_string().into()
                                } else {
                                    format!("{} ({})", tr("Transcribe all"), waiting()).into()
                                }
                            })
                            .on_press(transcribe::start_ready),
                        )
                    },
                ))
                .child(
                    view()
                        .flex_row()
                        .items_center()
                        .gap_1()
                        .window_drag(false)
                        .child(
                            ui::menu_with(sort_open, ui::menu_trigger(Icon::Sort, tr("Sort"), Size::Sm, sort_open))
                                .children(Sort::ALL.map(|(choice, label)| {
                                    MenuChoice { label: l(label), checked: move || sort.get() == choice, on_select: move || choice.save() }
                                })),
                        )
                        .child(when(|| !crate::pages::chrome::system_header(), super::capture::add_button))
                        .child(ui::IconButton { glyph: Icon::Export, name: tr("Export shown as ZIP…"), size: Size::Sm, on_press: move || {
                            super::dialogs::export_zip(shown.get_untracked())
                        } }),
                ),
        )
        .child(
            when(
                move || store.jobs().is_empty(),
                move || {
                    EmptyState { glyph: Icon::Wave, title: move || tr(if platform::is_phone() { "Add audio or video" } else { "Drop audio or video here" }), description: move || {
                            tr(if cfg!(target_os = "ios") {
                                "Choose audio or video from the Files app. Up to 5 hours each."
                            } else if platform::is_phone() {
                                "Put files in the Listenook folder in the Files app, then tap Add media. Up to 5 hours each."
                            } else if super::capture::offered() {
                                "A subtitle file with the same name can become its transcript. Or record a video or \
                                 audio as it plays in another app. Up to 5 hours each."
                            } else {
                                "A subtitle file with the same name can become its transcript. Up to 5 hours each."
                            })
                        }, action: view()
                            .flex_row()
                            .flex_wrap()
                            .justify_center()
                            .gap_2()
                            .child(
                                icon_text_button(Variant::Primary, Size::Md, Icon::Plus, l("Add media…"))
                                    .on_press(import::pick_media),
                            )
                            .child(when(super::capture::offered, move || {
                                icon_text_button(Variant::Outline, Size::Md, Icon::Record, l("Record what’s playing"))
                                    .on_press(move || crate::work::capture::CaptureState::get().act(crate::work::capture::CaptureAction::Record))
                            })) }
                },
            )
            .otherwise(move || {
                virtual_list(move || shown.with(Vec::len), move |at| row(shown, at, dialogs))
                    .smooth_wheel(true)
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

pub(super) fn kind_icon(job: &Job) -> Icon {
    if matches!(job.status, JobStatus::Failed | JobStatus::MissingSource | JobStatus::Empty) {
        Icon::Alert
    } else if job.source_origin == JobSourceOrigin::Podcast {
        Icon::Podcast
    } else if job.has_video()
        || matches!(listenook_core::media::subtitles::extension(&job.source_path).as_str(), "mp4" | "mkv" | "avi")
    {
        Icon::Film
    } else {
        Icon::Headphones
    }
}

pub(super) fn detail(job: &Job) -> SharedString {
    if let Some(code) = job.error_code.as_deref().filter(|_| !job.status().is_active() && !job.has_transcript()) {
        return error_text(code);
    }
    let translating = job.translation_state.status == TranslationStatus::Translating;
    let mut parts = Vec::new();
    if job.status().is_transcribable() {
        parts.push(tr("Not transcribed").to_string());
    } else if job.status().is_active() || !job.has_transcript() {
        parts.push(tr(status_label(job.status)).to_string());
    } else if translating {
        let state = job.translation();
        parts.push(format!("{} {}/{}", tr("Translating"), state.completed_segments, state.total_segments));
    }
    if job.duration_ms() > 0 {
        parts.push(format::shown(format::Shown::Clock(job.duration_ms())));
    }
    if job.has_transcript() && !translating {
        if job.document().is_some_and(|d| d.segments.iter().any(|s| s.has_translation())) {
            parts.push(tr("Bilingual").to_string());
        }
        if job.has_brief() {
            parts.push(tr("AI Brief").to_string());
        }
    }
    if let Some(podcast) = job.podcast() {
        parts.push(podcast.show_title.clone());
    }
    parts.push(format::shown(format::Shown::Date(&job.created_at)));
    parts.join(" · ").into()
}

fn row_menu(menu: ui::Menu, id: impl Fn() -> String + Copy + 'static, dialogs: Dialogs) -> ui::Menu {
    let store = store();
    menu.child(MenuAction { glyph: Icon::Pencil, label: l("Rename…"), on_select: move || dialogs.rename.show(&id()) })
        .child(MenuAction { glyph: Icon::Folder, label: l("Group…"), on_select: move || dialogs.group.show(&id()) })
        .child(MenuAction { glyph: Icon::Tag, label: l("Tags…"), on_select: move || dialogs.tags.show(&id()) })
        .child(MenuAction {
            glyph: Icon::Export,
            label: l("Export…"),
            on_select: move || {
                if store.job_now(&id()).is_some_and(|job| job.has_transcript()) {
                    dialogs.export.show(&id());
                } else {
                    ui::toast(ui::Tone::Info, tr("There is no transcript to export yet."));
                }
            },
        })
        .child(when(
            || !platform::is_phone(),
            move || MenuAction {
                glyph: Icon::Languages,
                label: l("Use a subtitle file…"),
                on_select: move || import::attach_subtitles(id()),
            },
        ))
        .child(when(
            move || store.job(&id()).is_some_and(|job| can_transcribe_again(&job)),
            move || MenuAction {
                glyph: Icon::Transcribe,
                label: l("Transcribe again…"),
                on_select: move || transcribe_again(&id()),
            },
        ))
        .child(when(
            move || {
                store
                    .job(&id())
                    .is_some_and(|job| job.status == listenook_core::JobStatus::Completed && local::can_align(&job))
            },
            move || MenuAction {
                glyph: Icon::Wave,
                label: l("Time the words"),
                on_select: move || timing::align(&id()),
            },
        ))
        .child(when(
            || !platform::is_phone(),
            move || MenuAction {
                glyph: Icon::Open,
                label: l(if cfg!(target_os = "macos") { "Show in Finder" } else { "Show in folder" }),
                on_select: move || {
                    if let Some(job) = store.job_now(&id()) {
                        import::reveal(job.source_path.clone());
                    }
                },
            },
        ))
        .child(when(
            || !platform::is_phone() || cfg!(target_os = "ios"),
            move || MenuAction {
                glyph: Icon::Refresh,
                label: l("Relink media…"),
                on_select: move || import::relink(id()),
            },
        ))
        .child(when(
            move || {
                store.job(&id()).is_some_and(|job| {
                    job.source_origin == JobSourceOrigin::Podcast && std::path::Path::new(&job.source_path).exists()
                })
            },
            move || MenuAction {
                glyph: Icon::Export,
                label: l("Save episode as…"),
                on_select: move || {
                    if let Some(job) = store.job_now(&id()) {
                        import::save_copy(job.source_path.clone());
                    }
                },
            },
        ))
        .child(MenuDivider)
        .child(MenuDanger {
            glyph: Icon::Trash,
            label: l("Remove…"),
            on_select: move || {
                let id = id();
                let Some(job) = store.job_now(&id) else {
                    return;
                };
                let owned =
                    store.data_root().is_some_and(|root| std::path::Path::new(&job.source_path).starts_with(root));
                if !job.has_transcript() && !owned && !job.status().is_active() {
                    store.act(crate::state::Action::RemoveJob(&id));
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
                    move || store.act(crate::state::Action::RemoveJob(&id)),
                );
            },
        })
}

pub(crate) fn retry(id: &str) {
    let failed_download =
        store().job_now(id).is_some_and(|job| job.error_code.as_deref() == Some("podcast_download_failed"));
    if failed_download { podcasts::download(id) } else { transcribe::retry(id) }
}

pub(crate) fn can_transcribe_again(job: &Job) -> bool {
    job.has_transcript() && !job.is_busy()
}

/// Asks before transcribing a recording once more, since the new transcript replaces this one.
///
/// Asked under the store, not the menu: a menu item shown only sometimes goes with the menu as
/// it closes, and the answer would go with it.
pub(crate) fn transcribe_again(id: &str) {
    let store = store();
    let Some(job) = store.job_now(id) else {
        return;
    };
    let id = id.to_owned();
    if !std::path::Path::new(&job.source_path).is_file() {
        return missing_source(id);
    }
    store.run(async move {
        confirm_destructive(
            format!("{} “{}”?", tr("Transcribe again"), job.title()),
            tr(
                "It’s transcribed with your current settings. This transcript stays until the new one is ready, which then replaces it with its edits, translation and AI Brief.",
            ),
            tr("Cancel"),
            tr("Transcribe again"),
            move || transcribe::again(&id),
        );
    });
}

fn missing_source(id: String) {
    if !platform::is_phone() || cfg!(target_os = "ios") {
        ui::toast_with_action(ui::Tone::Info, error_text("missing_source"), tr("Relink media…"), move || {
            import::relink(id.clone())
        });
    } else {
        ui::toast(ui::Tone::Info, error_text("missing_source"));
    }
}

/// Whether the reader can open `job`: to read its transcript, or else to play its media.
pub(crate) fn can_open(job: &Job) -> bool {
    job.has_transcript() || (job.status != JobStatus::Downloading && std::path::Path::new(&job.source_path).is_file())
}

/// Opens a recording, or says why it cannot open yet and offers what would make it playable.
pub(crate) fn open(id: &str) {
    let store = store();
    let Some(job) = store.job_now(id) else {
        return;
    };
    if can_open(&job) {
        return store.act(crate::state::Action::OpenTranscript(id));
    }
    let id = id.to_owned();
    if job.status == JobStatus::Downloading {
        ui::toast(ui::Tone::Info, tr("It opens once it’s downloaded."));
    } else if job.error_code.as_deref() == Some("podcast_download_failed") {
        ui::toast_with_action(ui::Tone::Info, error_text("podcast_download_failed"), tr("Retry"), move || retry(&id));
    } else {
        missing_source(id);
    }
}

fn tag_pill(name: impl Into<SharedString>) -> View {
    view()
        .px_1p5()
        .py(px(1.0))
        .rounded(|| tokens::corner(tokens::Corner::Small))
        .bg(|| theme().muted)
        .child(text(name.into()).text_xs().number_of_lines(1).text_color(|| theme().muted_foreground))
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
        store.tags().into_iter().filter(|tag| carried.contains(&tag.id)).map(|tag| tag.name).collect::<Vec<_>>()
    });
    let tag_room = computed(|| if crate::pages::chrome::page_narrow() { 1 } else { 2 });
    let more_open = signal(false);
    let content = view()
        .flex_row()
        .items_center()
        .gap_1()
        .child(
            ui::list_row(|| false)
                .on_press(move || open(&id()))
                .flex_1()
                .min_w(px(0.0))
                .child(
                    view()
                        .size(px(36.0))
                        .items_center()
                        .justify_center()
                        .rounded(|| tokens::corner(tokens::Corner::Medium))
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
                                    let (names, room) = (tags.get(), tag_room.get());
                                    let rest = SharedString::from(names.get(room..).unwrap_or_default().join(", "));
                                    let more = names.len().saturating_sub(room);
                                    view()
                                        .flex_row()
                                        .flex_shrink_0()
                                        .gap_1()
                                        .children(
                                            names.into_iter().take(room).map(|name| tag_pill(name).max_w(px(112.0))),
                                        )
                                        .children((more > 0).then(|| {
                                            tag_pill(format!("+{more}")).label(rest.clone()).tooltip(ui::tip(rest))
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
                                        let state = job.translation();
                                        Some(state.completed_segments as f32 / state.total_segments.max(1) as f32)
                                    } else {
                                        job.fraction()
                                    }
                                })
                            })
                            .mt_1()
                        })),
                ),
        )
        .child(when(
            move || read(|job| job.status().is_transcribable()),
            move || button(Variant::Outline, Size::Sm, l("Transcribe")).on_press(move || transcribe::start(&id())),
        ))
        .child(when(busy, move || {
            button(Variant::Ghost, Size::Sm, l("Cancel")).on_press(move || {
                let id = id();
                ai::cancel_translation(&id);
                ai::cancel_brief(&id);
                if store.job_now(&id).is_some_and(|job| job.status().is_active()) {
                    transcribe::cancel(&id);
                }
            })
        }))
        .child(when(
            move || read(|job| job.status().is_retryable() && !job.has_transcript()),
            move || button(Variant::Outline, Size::Sm, l("Retry")).on_press(move || retry(&id())),
        ))
        .child(row_menu(
            ui::menu_with(more_open, ui::menu_trigger(Icon::More, tr("More actions"), Size::Sm, more_open)),
            id,
            dialogs,
        ));
    if platform::is_phone() {
        content.into_element()
    } else {
        row_menu(ui::context_menu(content), id, dialogs).into_element()
    }
}

/// The engine the next transcription uses, as the toolbar names it.
fn engine_label() -> SharedString {
    match store().setting(|s| s.default_transcription_provider) {
        TranscriptionProvider::Soniox => "Soniox".into(),
        TranscriptionProvider::MossPro => "MOSS Pro".into(),
        TranscriptionProvider::Qwen3Local => "Qwen3".into(),
        TranscriptionProvider::MossLocal => "MOSS".into(),
    }
}

fn options() -> impl IntoElement {
    let store = store();
    let provider = move || store.setting(|s| s.default_transcription_provider);
    let is_local = move || local::is_local(provider());
    let has_key = move || match provider() {
        TranscriptionProvider::MossPro => store.has_key(secrets::Secret::Moss),
        TranscriptionProvider::Soniox => store.has_key(secrets::Secret::Soniox),
        other => local::provider_ready(other, store.large_local_model()),
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
                        .child(button(Variant::Outline, Size::Sm, l("Settings")).on_press(move || {
                            store.act(crate::state::Action::OpenSettings(SettingsTab::Transcription))
                        }))
                },
            )),
        )
        .child(when(
            move || provider() != TranscriptionProvider::MossPro,
            move || {
                view()
                    .gap_4()
                    .child(
                        field(
                            l("Language hints"),
                            TextField {
                                value: store.language_hints(),
                                placeholder: || SharedString::from("en, zh, ja"),
                            },
                        )
                        .child(hint(l("Language codes separated by commas. Leave empty to detect automatically."))),
                    )
                    .child(field(
                        l("Names and context terms"),
                        text_area(store.context_terms(), l("Product names, people, acronyms…")),
                    ))
            },
        ))
        .child(Separator)
        .child(switch(
            l("Translate after transcription"),
            move || store.setting(|s| s.translation_preferences.auto_translate),
            move |on| store.update_settings(|s| s.translation_preferences.auto_translate = on),
        ))
        .child(when(
            move || store.setting(|s| s.translation_preferences.auto_translate) && !store.ai_ready(),
            move || {
                view()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        hint(move || {
                            tr(match store.ai_setup() {
                                Some(AiSetup::Key) => "Add an API key for the AI provider in Settings to translate.",
                                Some(AiSetup::SignIn) => "Sign in with ChatGPT in Settings to translate.",
                                _ => "Configure the AI provider in Settings before translating.",
                            })
                        })
                        .flex_1(),
                    )
                    .child(
                        button(Variant::Outline, Size::Sm, l("Settings"))
                            .on_press(move || store.act(crate::state::Action::OpenSettings(SettingsTab::Ai))),
                    )
            },
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
