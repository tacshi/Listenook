//! Dialogs more than one page opens: exporting and renaming a transcript.

use listenook_core::{ContentMode, ExportFormat, export};
use nsh_core::prelude::*;

use crate::{
    state::{l, store, tr},
    ui::{Tone, checkbox, field, hint, modal, modal_actions, select, text_field, toast},
};

/// A dialog about one job: which job, and whether it is open.
#[derive(Clone, Copy)]
pub(crate) struct JobDialog {
    job: Signal<String>,
    open: Signal<bool>,
}

impl JobDialog {
    /// A closed dialog. Make it in a page's body.
    pub(crate) fn new() -> Self {
        Self { job: signal(String::new()), open: signal(false) }
    }

    /// Opens it for a job.
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

/// Writes `contents` where the user chooses, proposing `file_name`.
pub(crate) fn save_text(file_name: String, contents: String) {
    store().run(async move {
        let Some(path) = crate::util::save_target(file_name).await else {
            return;
        };
        match blocking(move || std::fs::write(path, contents)).await {
            Ok(Ok(())) => toast(Tone::Success, crate::util::saved_text()),
            _ => toast(Tone::Error, tr("Couldn’t save the file. Choose another folder and try again.")),
        }
    });
}

/// The export dialog: format, content and labels, remembered for next time.
pub(crate) fn export_dialog(dialog: JobDialog) -> impl IntoElement {
    let store = store();
    let options = move || store.setting(|s| s.export_options.clone());
    let cues = move || matches!(options().format, ExportFormat::Srt | ExportFormat::WebVtt);
    let untranslated = move || {
        options().content_mode != ContentMode::Original
            && store
                .job(&dialog.job.get())
                .and_then(|job| job.document.as_ref().map(|d| d.segments.iter().any(|s| !s.has_translation())))
                .unwrap_or(false)
    };
    modal(
        dialog.open,
        l("Export transcript"),
        420.0,
        move || {
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
                            move |value| {
                                store.update_settings(|s| s.export_options.content_mode = ContentMode::parse(&value))
                            },
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
                .into_element()
        },
        move || {
            modal_actions(
                dialog.open,
                l("Cancel"),
                l("Export"),
                || true,
                move || {
                    let Some(job) = store.job_now(&dialog.id()) else {
                        return;
                    };
                    let mut options = store.settings().export_options;
                    options.locale_code = store.lang().code().to_owned();
                    dialog.open.set(false);
                    save_text(
                        export::export_file_name(&job, options.format),
                        export::export_transcript(&job, &options),
                    );
                },
            )
        },
    )
}

/// The rename dialog: a transcript's display title.
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
            store.update_job(&dialog.id(), |job| job.display_title = Some(next));
            dialog.open.set(false);
        }
    };
    modal(
        dialog.open,
        l("Rename"),
        420.0,
        move || {
            field(
                l("Title"),
                text_field(title, SharedString::default).auto_focus(true).on_submit(move |_: &str| rename()),
            )
            .into_element()
        },
        move || {
            modal_actions(dialog.open, l("Cancel"), l("Rename"), move || !title.with(|t| t.trim().is_empty()), rename)
        },
    )
}

/// The group dialog: file a recording in a group, a new one, or none.
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
    modal(
        dialog.open,
        l("Group"),
        420.0,
        move || {
            let mut options: Vec<(SharedString, SharedString)> = vec![(SharedString::default(), tr("No group"))];
            options.extend(store.catalog().groups.into_iter().map(|group| (group.id.into(), group.name.into())));
            view()
                .gap_4()
                .child(field(
                    l("Group"),
                    select("Group", options, move || chosen.get(), move |value| chosen.set(value)),
                ))
                .child(field(l("Or a new group"), text_field(new_name, l("Name"))))
                .into_element()
        },
        move || {
            modal_actions(
                dialog.open,
                l("Cancel"),
                l("Save"),
                || true,
                move || {
                    let named = store.add_group(&new_name.get_untracked());
                    let group = named.or_else(|| Some(chosen.get_untracked().to_string()).filter(|id| !id.is_empty()));
                    store.set_group(&dialog.id(), group);
                    dialog.open.set(false);
                },
            )
        },
    )
}

/// The tags dialog: each tag is on or off at once; a new name makes a tag.
pub(crate) fn tags_dialog(dialog: JobDialog) -> impl IntoElement {
    let store = store();
    let new_name = signal(String::new());
    let add = move || {
        let name = new_name.get_untracked();
        let name = name.trim();
        if !name.is_empty() {
            // A tag the recording already carries stays on it.
            let carried = store.job_now(&dialog.id()).is_some_and(|job| job.tag_ids.iter().any(|tag| tag == name));
            if !carried {
                store.toggle_tag(&dialog.id(), name);
            }
            new_name.set(String::new());
        }
    };
    let carries =
        move |tag: &str| store.job(&dialog.job.get()).is_some_and(|job| job.tag_ids.iter().any(|other| other == tag));
    modal(
        dialog.open,
        l("Tags"),
        420.0,
        move || {
            view()
                .gap_4()
                .child(
                    view()
                        .flex_row()
                        .gap_2()
                        .child(text_field(new_name, l("New tag")).on_submit(move |_: &str| add()).flex_1())
                        .child(
                            crate::ui::button(crate::ui::Variant::Default, crate::ui::Size::Md, l("Add"))
                                .disabled(move || new_name.with(|n| n.trim().is_empty()))
                                .on_press(add),
                        ),
                )
                .child(view().gap_2().child(each(
                    move || store.catalog().tags,
                    |tag| tag.id.clone(),
                    move |tag, _| {
                        let name = tag.get_untracked().name;
                        checkbox(
                            SharedString::from(name.clone()),
                            move || carries(&tag.with(|t| t.id.clone())),
                            move |_| store.toggle_tag(&dialog.id(), &name),
                        )
                    },
                )))
                .into_element()
        },
        move || {
            crate::ui::button(crate::ui::Variant::Primary, crate::ui::Size::Md, l("Done"))
                .on_press(move || dialog.open.set(false))
                .into_element()
        },
    )
}

/// Saves the transcripts of `jobs` as one ZIP, with the export options last
/// used. Names that repeat get `-2`, `-3`, ...
pub(crate) fn export_zip(jobs: Vec<std::rc::Rc<listenook_core::Job>>) {
    let store = store();
    let mut options = store.settings().export_options;
    options.locale_code = store.lang().code().to_owned();
    let mut used: Vec<String> = Vec::new();
    let files: Vec<(String, String)> = jobs
        .iter()
        .filter(|job| job.has_transcript())
        .map(|job| {
            let name = export::export_file_name(job, options.format);
            let (stem, extension) = name.rsplit_once('.').unwrap_or((&name, "txt"));
            let mut unique = name.clone();
            let mut count = 1;
            while used.iter().any(|other| other.eq_ignore_ascii_case(&unique)) {
                count += 1;
                unique = format!("{stem}-{count}.{extension}");
            }
            used.push(unique.clone());
            (unique, export::export_transcript(job, &options))
        })
        .collect();
    if files.is_empty() {
        toast(Tone::Info, tr("There is no transcript to export yet."));
        return;
    }
    store.run(async move {
        let Some(path) = crate::util::save_target("Listenook-transcripts.zip".to_owned()).await else {
            return;
        };
        let written = blocking(move || -> std::io::Result<()> {
            use std::io::Write;
            let mut archive = zip::ZipWriter::new(std::fs::File::create(path)?);
            for (name, contents) in files {
                archive.start_file(name, zip::write::SimpleFileOptions::default()).map_err(std::io::Error::other)?;
                archive.write_all(contents.as_bytes())?;
            }
            archive.finish().map_err(std::io::Error::other)?;
            Ok(())
        })
        .await;
        match written {
            Ok(Ok(())) => toast(Tone::Success, tr("Export complete")),
            _ => toast(Tone::Error, tr("Couldn’t save the file. Choose another folder and try again.")),
        }
    });
}

/// Asks which of several subtitle files beside a new recording is its
/// transcript. Placed once, in the shell.
pub(crate) fn subtitle_choice_dialog() -> impl IntoElement {
    let store = store();
    let open = signal(false);
    let chosen = signal(SharedString::default());
    effect(move || {
        let waiting = store.subtitle_choice();
        untracked(|| {
            if let Some((_, files)) = &waiting {
                chosen.set(files[0].clone().into());
            }
            open.set(waiting.is_some());
        });
    });
    // Closed any other way, the recording stays without a transcript.
    effect(move || {
        if !open.get() && untracked(|| store.subtitle_choice().is_some()) {
            store.subtitle_chosen();
        }
    });
    modal(
        open,
        l("Choose a subtitle file"),
        460.0,
        move || {
            let (job, files) = store.subtitle_choice().unwrap_or_default();
            let title = store.job_now(&job).map(|job| job.title()).unwrap_or_default();
            let name = |path: &String| -> SharedString {
                std::path::Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_owned().into()
            };
            let options = files.iter().map(|path| (SharedString::from(path.clone()), name(path))).collect();
            view()
                .gap_4()
                .child(hint(move || SharedString::from(format!("{} “{title}”.", tr("Several subtitle files match")))))
                .child(field(
                    l("Subtitle file"),
                    select("Subtitle file", options, move || chosen.get(), move |value| chosen.set(value)),
                ))
                .into_element()
        },
        move || {
            modal_actions(
                open,
                l("Not now"),
                l("Use it"),
                || true,
                move || {
                    if let Some((job, _)) = store.subtitle_choice() {
                        crate::util::import_subtitle_file(job, chosen.get_untracked().to_string());
                    }
                    open.set(false);
                },
            )
        },
    )
}
