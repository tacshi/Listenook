use listenook_core::{
    ContentMode, ExportFormat,
    transcript::export::{self, Export, File},
};
use nsh_core::prelude::*;

use nsh_base::theme;

use crate::ui::{l, tr};
use crate::{
    state::store,
    ui::{
        Icon, Modal, ModalActions, TextField, Tone, card, checkbox, checkbox_row, field, hint, icon, select, switch,
        text_field_with, toast, tokens,
    },
};

#[derive(Clone, Copy)]
pub(crate) struct JobDialog {
    job: Signal<String>,
    open: Signal<bool>,
}

impl JobDialog {
    pub(crate) fn new() -> Self {
        Self { job: signal(String::new()), open: signal(false) }
    }

    pub(crate) fn show(&self, id: &str) {
        batch(|| {
            self.job.set(id.to_owned());
            self.open.set(true);
        });
    }

    fn id(&self) -> String {
        self.job.get_untracked()
    }
}

pub(crate) fn save_text(file_name: String, contents: String) {
    store().run(async move {
        let Some(path) = crate::work::import::save_target(file_name).await else {
            return;
        };
        saved(blocking(move || std::fs::write(path, contents)).await);
    });
}

fn saved<E>(written: Result<std::io::Result<()>, E>) {
    match written {
        Ok(Ok(())) => toast(Tone::Success, crate::work::import::saved_text()),
        _ => toast(Tone::Error, tr("Couldn’t save the file. Choose another folder and try again.")),
    }
}

fn save_files(bundle: String, mut files: Vec<File>) {
    if files.len() <= 1 {
        if let Some(File { name, contents }) = files.pop() {
            save_text(name, contents);
        }
        return;
    }
    if !crate::platform::is_phone() {
        save_zip(bundle, files);
        return;
    }
    store().run(async move {
        saved(
            blocking(move || {
                files.into_iter().try_for_each(|File { name, contents }| {
                    let path =
                        crate::platform::export_path(&name).ok_or_else(|| std::io::Error::other("no export folder"))?;
                    std::fs::write(path, contents)
                })
            })
            .await,
        );
    });
}

fn save_zip(name: String, files: Vec<File>) {
    store().run(async move {
        let Some(path) = crate::work::import::save_target(name).await else {
            return;
        };
        saved(
            blocking(move || -> std::io::Result<()> {
                use std::io::Write;
                let mut archive = zip::ZipWriter::new(std::fs::File::create(path)?);
                for File { name, contents } in files {
                    archive
                        .start_file(name, zip::write::SimpleFileOptions::default())
                        .map_err(std::io::Error::other)?;
                    archive.write_all(contents.as_bytes())?;
                }
                archive.finish().map_err(std::io::Error::other)?;
                Ok(())
            })
            .await,
        );
    });
}

#[derive(Clone, Copy, PartialEq, Eq, Default)]
struct Parts {
    transcript: bool,
    brief: bool,
    flashcards: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct ExportDialog {
    dialog: JobDialog,
    parts: Signal<Parts>,
}

impl ExportDialog {
    pub(crate) fn new() -> Self {
        Self { dialog: JobDialog::new(), parts: signal(Parts { transcript: true, ..Parts::default() }) }
    }

    pub(crate) fn show(&self, id: &str) {
        self.dialog.show(id);
    }
}

fn transcript_options(dialog: JobDialog) -> View {
    let store = store();
    let options = move || store.setting(|s| s.export_options.clone());
    let cues = move || matches!(options().format, ExportFormat::Srt | ExportFormat::WebVtt);
    let untranslated = move || {
        options().content_mode != ContentMode::Original
            && store
                .job(&dialog.job.get())
                .and_then(|job| job.document().map(|d| d.segments.iter().any(|s| !s.has_translation())))
                .unwrap_or(false)
    };
    view()
        .gap_4()
        .child(field(
            l("Format"),
            select(
                "Format",
                ExportFormat::ALL.iter().map(|f| (f.as_str().into(), f.label().into())).collect(),
                move || SharedString::from(options().format.as_str()),
                move |value| store.update_settings(|s| s.export_options.format = ExportFormat::parse(&value)),
            ),
        ))
        .child(
            field(
                l("Content"),
                select(
                    "Content",
                    vec![
                        ("original".into(), tr("Original")),
                        ("translated".into(), tr("Translated")),
                        ("bilingual".into(), tr("Bilingual")),
                    ],
                    move || SharedString::from(options().content_mode.as_str()),
                    move |value| store.update_settings(|s| s.export_options.content_mode = ContentMode::parse(&value)),
                ),
            )
            .child(when(untranslated, || {
                hint(l("Some sentences are not translated; they are exported in the original."))
            })),
        )
        .child(checkbox(
            l("Speaker labels"),
            move || options().show_speakers,
            move |on| store.update_settings(|s| s.export_options.show_speakers = on),
        ))
        .child(
            checkbox(
                l("Timestamps"),
                move || options().show_timestamps || cues(),
                move |on| store.update_settings(|s| s.export_options.show_timestamps = on),
            )
            .disabled(cues),
        )
        .child(when(cues, || hint(l("Subtitle formats always include timestamps."))))
}

fn part_card(
    glyph: Icon,
    title: &'static str,
    detail: &'static str,
    on: impl Fn() -> bool + Copy + 'static,
    set: impl Fn(bool) + 'static,
) -> View {
    card().border_color(move || if on() { theme().primary } else { theme().border }).overflow_hidden().child(
        checkbox_row(tr(title), on, set)
            .child(
                view()
                    .size(px(32.0))
                    .flex_shrink_0()
                    .items_center()
                    .justify_center()
                    .rounded(|| tokens::corner(tokens::Corner::Medium))
                    .bg(|| theme().muted)
                    .text_color(|| theme().primary)
                    .child(icon(glyph, 16.0)),
            )
            .child(
                view()
                    .flex_1()
                    .min_w(px(0.0))
                    .gap_0p5()
                    .child(text(l(title)).text_sm().font_weight(FontWeight::MEDIUM).text_color(|| theme().foreground))
                    .child(hint(l(detail))),
            ),
    )
}

pub(crate) fn export_dialog(export: ExportDialog) -> impl IntoElement {
    let store = store();
    let (dialog, parts) = (export.dialog, export.parts);
    let brief = move || store.job(&dialog.job.get()).and_then(|job| job.ai_brief.clone());
    let briefed = move || brief().is_some();
    let carded = move || brief().is_some_and(|brief| !brief.language_notes.is_empty());
    let chosen = move || {
        let picked = parts.get();
        if !briefed() {
            return Parts { transcript: true, ..Parts::default() };
        }
        Parts { flashcards: picked.flashcards && carded(), ..picked }
    };
    let count = move || {
        let chosen = chosen();
        [chosen.transcript, chosen.brief, chosen.flashcards].into_iter().filter(|on| *on).count()
    };
    Modal {
        open: dialog.open,
        title: move || if briefed() { tr("Export") } else { tr("Export transcript") },
        width: 460.0,
        content: move || {
            dynamic(move || {
                if !briefed() {
                    return untracked(|| transcript_options(dialog).into_element());
                }
                untracked(|| {
                    view()
                        .gap_4()
                        .child(field(
                            l("Include"),
                            view()
                                .gap_2()
                                .child(
                                    part_card(
                                        Icon::Captions,
                                        "Transcript",
                                        "Text, Markdown, or subtitles",
                                        move || chosen().transcript,
                                        move |on| parts.update(|p| p.transcript = on),
                                    )
                                    .child(when(
                                        move || chosen().transcript,
                                        move || {
                                            transcript_options(dialog)
                                                .p_3()
                                                .border_t_1()
                                                .border_color(|| theme().border)
                                        },
                                    )),
                                )
                                .child(part_card(
                                    Icon::Sparkles,
                                    "AI Brief",
                                    "Markdown, with the times behind each point",
                                    move || chosen().brief,
                                    move |on| parts.update(|p| p.brief = on),
                                ))
                                .child(when(carded, move || {
                                    part_card(
                                        Icon::Practice,
                                        "Flashcards",
                                        "CSV, for Anki and other flashcard apps",
                                        move || chosen().flashcards,
                                        move |on| parts.update(|p| p.flashcards = on),
                                    )
                                })),
                        ))
                        .child(when(move || count() == 0, || hint(l("Choose at least one to export."))))
                        .child(when(
                            move || count() > 1,
                            || {
                                hint(if crate::platform::is_phone() {
                                    l("Each is saved as its own file in the Listenook folder in Files, under Exports.")
                                } else {
                                    l("Saved together in one .zip file.")
                                })
                            },
                        ))
                        .into_element()
                })
            })
            .into_element()
        },
        actions: move || {
            ModalActions {
                open: dialog.open,
                cancel: l("Cancel"),
                commit: l("Export"),
                enabled: move || count() > 0,
                on_commit: move || {
                    let Some(job) = store.job_now(&dialog.id()) else {
                        return;
                    };
                    let chosen = chosen();
                    let mut files = Vec::new();
                    if chosen.transcript {
                        let mut options = store.settings().export_options;
                        options.locale_code = store.lang().code().to_owned();
                        files.push(export::export(&job, Export::Transcript(&options)));
                    }
                    if let Some(brief) = job.brief() {
                        if chosen.brief {
                            files.push(export::export(&job, Export::Brief(&brief)));
                        }
                        if chosen.flashcards {
                            files.push(export::export(&job, Export::Flashcards(&brief)));
                        }
                    }
                    dialog.open.set(false);
                    save_files(export::bundle_file_name(&job), files);
                },
            }
            .into_element()
        },
    }
}

pub(crate) fn rename_dialog(dialog: JobDialog) -> impl IntoElement {
    let store = store();
    let title = signal(String::new());
    effect(move || {
        if dialog.open.get() {
            let current = store.job_now(&dialog.job.get_untracked()).map(|job| job.title()).unwrap_or_default();
            title.set(current);
        }
    });
    let rename = move || {
        let next = title.get_untracked().trim().to_owned();
        if !next.is_empty() {
            store.update_job(&dialog.id(), |job| job.apply(listenook_core::Change::Rename(&next)));
            dialog.open.set(false);
        }
    };
    Modal {
        open: dialog.open,
        title: l("Rename"),
        width: 420.0,
        content: move || {
            field(
                l("Title"),
                text_field_with(title, SharedString::default, move |input| {
                    input.auto_focus(true).on_submit(move |_: &str| rename())
                }),
            )
            .into_element()
        },
        actions: move || {
            ModalActions {
                open: dialog.open,
                cancel: l("Cancel"),
                commit: l("Rename"),
                enabled: move || !title.with(|t| t.trim().is_empty()),
                on_commit: rename,
            }
            .into_element()
        },
    }
}

pub(crate) fn group_dialog(dialog: JobDialog) -> impl IntoElement {
    let store = store();
    let chosen = signal(SharedString::default());
    let new_name = signal(String::new());
    effect(move || {
        if dialog.open.get() {
            let current = store.job_now(&dialog.job.get_untracked()).and_then(|job| job.group_id.clone());
            batch(|| {
                chosen.set(current.unwrap_or_default().into());
                new_name.set(String::new());
            });
        }
    });
    Modal {
        open: dialog.open,
        title: l("Group"),
        width: 420.0,
        content: move || {
            let mut options: Vec<(SharedString, SharedString)> = vec![(SharedString::default(), tr("No group"))];
            options.extend(store.groups().into_iter().map(|group| (group.id.into(), group.name.into())));
            view()
                .gap_4()
                .child(field(
                    l("Group"),
                    select("Group", options, move || chosen.get(), move |value| chosen.set(value)),
                ))
                .child(field(l("Or a new group"), TextField { value: new_name, placeholder: l("Name") }))
                .into_element()
        },
        actions: move || {
            ModalActions {
                open: dialog.open,
                cancel: l("Cancel"),
                commit: l("Save"),
                enabled: || true,
                on_commit: move || {
                    let named = store.add_group(&new_name.get_untracked());
                    let group = named.or_else(|| Some(chosen.get_untracked().to_string()).filter(|id| !id.is_empty()));
                    store.act(crate::state::Action::SetGroup(&dialog.id(), group));
                    dialog.open.set(false);
                },
            }
            .into_element()
        },
    }
}

pub(crate) fn tags_dialog(dialog: JobDialog) -> impl IntoElement {
    let store = store();
    let new_name = signal(String::new());
    let add = move || {
        let name = new_name.get_untracked();
        let name = name.trim();
        if !name.is_empty() {
            let carried = store.job_now(&dialog.id()).is_some_and(|job| job.has_tag(name));
            if !carried {
                store.act(crate::state::Action::ToggleTag(&dialog.id(), name));
            }
            new_name.set(String::new());
        }
    };
    let carries = move |tag: &str| store.job(&dialog.job.get()).is_some_and(|job| job.has_tag(tag));
    Modal {
        open: dialog.open,
        title: l("Tags"),
        width: 420.0,
        content: move || {
            view()
                .gap_4()
                .child(
                    view()
                        .flex_row()
                        .gap_2()
                        .child(
                            text_field_with(new_name, l("New tag"), move |input| input.on_submit(move |_: &str| add()))
                                .flex_1(),
                        )
                        .child(
                            crate::ui::button(crate::ui::Variant::Default, crate::ui::Size::Md, l("Add"))
                                .disabled(move || new_name.with(|n| n.trim().is_empty()))
                                .on_press(add),
                        ),
                )
                .child(view().gap_2().child(each(
                    move || store.tags(),
                    |tag| tag.id.clone(),
                    move |tag, _| {
                        let name = tag.get_untracked().name;
                        checkbox(
                            SharedString::from(name.clone()),
                            move || carries(&tag.with(|t| t.id.clone())),
                            move |_| store.act(crate::state::Action::ToggleTag(&dialog.id(), &name)),
                        )
                    },
                )))
                .into_element()
        },
        actions: move || {
            crate::ui::button(crate::ui::Variant::Primary, crate::ui::Size::Md, l("Done"))
                .on_press(move || dialog.open.set(false))
                .into_element()
        },
    }
}

pub(crate) fn export_zip(jobs: Vec<std::rc::Rc<listenook_core::Job>>) {
    let store = store();
    let mut options = store.settings().export_options;
    options.locale_code = store.lang().code().to_owned();
    let mut used: Vec<String> = Vec::new();
    let files: Vec<File> = jobs
        .iter()
        .filter(|job| job.has_transcript())
        .map(|job| {
            let file = export::export(job, Export::Transcript(&options));
            let name = file.name;
            let (stem, extension) = name.rsplit_once('.').unwrap_or((&name, "txt"));
            let mut unique = name.clone();
            let mut count = 1;
            while used.iter().any(|other| other.eq_ignore_ascii_case(&unique)) {
                count += 1;
                unique = format!("{stem}-{count}.{extension}");
            }
            used.push(unique.clone());
            File { name: unique, contents: file.contents }
        })
        .collect();
    if files.is_empty() {
        toast(Tone::Info, tr("There is no transcript to export yet."));
        return;
    }
    save_zip("Listenook-transcripts.zip".to_owned(), files);
}

/// Asks whether a subtitle file found with a newly added recording becomes its transcript.
/// It is off until turned on: subtitles from YouTube often read badly, and transcribing the
/// audio usually does better.
pub(crate) fn subtitle_choice_dialog() -> impl IntoElement {
    let store = store();
    let open = signal(false);
    let showing = signal(String::new());
    let chosen = signal(SharedString::default());
    let use_it = signal(false);
    effect(move || {
        let waiting = store.subtitle_choice();
        untracked(|| {
            if let Some((job, files)) = &waiting
                && showing.get_untracked() != *job
            {
                showing.set(job.clone());
                chosen.set(files[0].clone().into());
                use_it.set(false);
            }
            open.set(waiting.is_some());
        });
    });
    effect(move || {
        if !open.get() && untracked(|| store.subtitle_choice().is_some()) {
            store.act(crate::state::Action::SubtitleChosen);
        }
    });
    Modal {
        open,
        title: l("Use the subtitle file?"),
        width: 460.0,
        content: move || {
            let (job, files) = store.subtitle_choice().unwrap_or_default();
            let title = store.job_now(&job).map(|job| job.title()).unwrap_or_default();
            let name = |path: &String| -> SharedString {
                std::path::Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_owned().into()
            };
            let several = files.len() > 1;
            let matched = tr(if several { "Several subtitle files match" } else { "A subtitle file matches" });
            let file = if several {
                let options = files.iter().map(|path| (SharedString::from(path.clone()), name(path))).collect();
                select("Subtitle file", options, move || chosen.get(), move |value| chosen.set(value)).into_element()
            } else {
                let only = files.first().map(name).unwrap_or_default();
                text(only).text_sm().text_color(|| theme().foreground).into_element()
            };
            view()
                .gap_4()
                .child(hint(move || SharedString::from(format!("{matched} “{title}”."))))
                .child(field(l("Subtitle file"), file))
                .child(
                    view()
                        .gap_1()
                        .child(switch(l("Use it as the transcript"), move || use_it.get(), move |on| use_it.set(on)))
                        .child(hint(l(
                            "Subtitles from YouTube are often auto-generated: sentences break in odd places and the \
                             timing drifts, which makes reading and practice harder. Leave this off to transcribe \
                             the audio instead.",
                        ))),
                )
                .into_element()
        },
        actions: move || {
            crate::ui::button(crate::ui::Variant::Primary, crate::ui::Size::Md, l("Done"))
                .on_press(move || {
                    if use_it.get_untracked()
                        && let Some((job, _)) = store.subtitle_choice()
                    {
                        crate::work::import::import_subtitle_file(job, chosen.get_untracked().to_string());
                    }
                    open.set(false);
                })
                .into_element()
        },
    }
}
