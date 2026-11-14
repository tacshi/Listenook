use listenook_core::{LlmProvider, LocaleMode, ThemeMode, local::Model};

use nsh_base::theme;
use nsh_core::prelude::*;

use crate::{
    services::{
        llm,
        local::{self, ModelState},
        remote::Provider,
        updater::{self, UpdateState},
    },
    state::{
        error_text, l,
        secrets::{self, Secret},
        store, tr,
    },
    ui::{
        Size, Status, Tone, Variant, badge, bound_field_with, button, card, confirm_destructive, field, hint, key_cap,
        modal_sized, progress_bar, section, segmented, select, separator, switch, text_field_with, toast,
    },
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tab {
    General,
    Transcription,
    Ai,
    Shortcuts,
    About,
}

impl Tab {
    const ALL: [Tab; 5] = [Tab::General, Tab::Transcription, Tab::Ai, Tab::Shortcuts, Tab::About];

    fn key(self) -> &'static str {
        match self {
            Tab::General => "General",
            Tab::Transcription => "Transcription",
            Tab::Ai => "AI",
            Tab::Shortcuts => "Shortcuts",
            Tab::About => "About",
        }
    }
}

pub(crate) const VERSION: &str = match option_env!("LISTENOOK_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

pub(crate) fn settings_dialog() -> impl IntoElement {
    let open = store().settings_open();
    let tab = signal(Tab::General);
    effect(move || {
        if store().update_check().get() {
            tab.set(Tab::About);
        }
    });
    modal_sized(
        open,
        l("Settings"),
        720.0,
        Some(620.0),
        move || {
            view()
                .gap_5()
                .child(
                    when(crate::platform::compact, move || {
                        scroll().horizontal().scrollbar(false).child(segmented(
                            Tab::ALL.iter().map(|tab| (*tab, tab.key())).collect(),
                            move || tab.get(),
                            move |next| tab.set(next),
                        ))
                    })
                    .otherwise(move || {
                        segmented(
                            Tab::ALL.iter().map(|tab| (*tab, tab.key())).collect(),
                            move || tab.get(),
                            move |next| tab.set(next),
                        )
                    }),
                )
                .child(dynamic(move || {
                    let tab = tab.get();
                    untracked(|| match tab {
                        Tab::General => general().into_element(),
                        Tab::Transcription => transcription().into_element(),
                        Tab::Ai => ai().into_element(),
                        Tab::Shortcuts => shortcuts().into_element(),
                        Tab::About => about().into_element(),
                    })
                }))
                .into_element()
        },
        move || button(Variant::Default, Size::Md, l("Done")).on_press(move || open.set(false)).into_element(),
    )
}

fn panel() -> View {
    card().p_4().gap_4()
}

fn general() -> impl IntoElement {
    let store = store();
    view().gap_6().child(section(
        l("Appearance"),
        panel()
            .child(field(
                l("Theme"),
                segmented(
                    vec![
                        (ThemeMode::System, "System"),
                        (ThemeMode::Light, "Light"),
                        (ThemeMode::Dark, "Dark"),
                    ],
                    move || store.setting(|s| s.theme_mode),
                    move |mode| store.update_settings(|s| s.theme_mode = mode),
                ),
            ))
            .child(field(
                l("Language"),
                segmented(
                    vec![
                        (LocaleMode::System, "System"),
                        (LocaleMode::English, "English"),
                        (LocaleMode::SimplifiedChinese, "简体中文"),
                    ],
                    move || store.setting(|s| s.locale_mode),
                    move |mode| store.update_settings(|s| s.locale_mode = mode),
                ),
            ))
    ))
    .child(section(
        l("Background"),
        panel()
            .child(switch(
                l("Notify me when transcriptions and downloads finish"),
                move || store.setting(|s| s.extra.get("notify_when_done").and_then(|v| v.as_bool()).unwrap_or(true)),
                move |on| store.update_settings(|s| drop(s.extra.insert("notify_when_done".into(), on.into()))),
            ))
            .child(when(crate::platform::has_tray, move || {
                view()
                    .gap_1()
                    .child(switch(
                        l(if cfg!(target_os = "macos") {
                            "Keep Listenook in the menu bar"
                        } else {
                            "Keep Listenook in the tray"
                        }),
                        move || store.tray_enabled(),
                        move |on| store.set_tray_enabled(on),
                    )
                    .disabled(move || !store.dock_visible()))
                    .child(hint(move || {
                        tr(if store.dock_visible() {
                            "Closing the window then hides it; Listenook keeps running."
                        } else {
                            "Show the Dock icon first, so Listenook stays reachable."
                        })
                    }))
            }))
            .child(when(|| cfg!(target_os = "macos"), move || {
                view()
                    .gap_1()
                    .child(
                        switch(l("Show Dock icon"), move || store.dock_visible(), move |on| store.set_dock_visible(on))
                            .disabled(move || !store.tray_enabled()),
                    )
                    .child(hint(move || {
                        tr(if store.tray_enabled() {
                            "When hidden, the menu bar icon opens Listenook and its settings."
                        } else {
                            "Show the menu bar icon first, so Listenook stays reachable."
                        })
                    }))
            }))
            .child(when(crate::services::login::supported, move || {
                view()
                    .gap_1()
                    .child(switch(
                        l("Open Listenook at login"),
                        move || store.opens_at_login(),
                        move |on| store.set_opens_at_login(on),
                    ))
                    .child(when(move || store.tray_enabled(), || {
                        hint(l(if cfg!(target_os = "macos") {
                            "Starts hidden in the menu bar."
                        } else {
                            "Starts hidden in the system tray."
                        }))
                    }))
            })),
    ))
    .child(when(|| !crate::platform::is_phone(), move || section(
        l("Watched folder"),
        panel()
            .child(hint(l("Audio and video that appear in this folder, and its subfolders, are added to the Library. Nothing is transcribed until you ask.")))
            .child(
                when(move || store.monitor().folder_path.is_empty(), move || {
                    button(Variant::Default, Size::Md, l("Choose folder")).self_start().on_press(choose_watched_folder)
                })
                .otherwise(move || {
                    view()
                        .gap_3()
                        .child(
                            text(move || SharedString::from(store.monitor().folder_path))
                                .text_sm()
                                .number_of_lines(2)
                                .text_color(|| theme().foreground),
                        )
                        .child(switch(
                            l("Watching"),
                            move || !store.monitor().paused,
                            move |on| store.set_monitor_paused(!on),
                        ))
                        .child(
                            view()
                                .flex_row()
                                .gap_2()
                                .child(button(Variant::Outline, Size::Md, l("Change folder")).on_press(choose_watched_folder))
                                .child(button(Variant::Ghost, Size::Md, l("Stop watching")).on_press(move || store.watch_folder(""))),
                        )
                }),
            ),
    )))
}

fn key_field(
    secret: Secret,
    keyless: impl Fn() -> bool + Copy + 'static,
    test: impl Fn(String, Signal<SharedString>) + Copy + 'static,
) -> impl IntoElement {
    let draft = signal(String::new());
    let saved = signal(secrets::read(secret).is_some());
    let status = signal(SharedString::default());
    let save = move || {
        let value = draft.get_untracked();
        match secrets::write(secret, &value) {
            Ok(()) => {
                batch(|| {
                    saved.set(!value.trim().is_empty());
                    draft.set(String::new());
                    status.set(SharedString::default());
                });
                toast(
                    Tone::Success,
                    tr(if secrets::uses_system_store() { "Key saved in the system keychain." } else { "Key saved." }),
                );
            }
            Err(error) => {
                log::error!("saving a key: {error}");
                toast(Tone::Error, tr("Couldn’t save the key. Unlock your keychain and try again."));
            }
        }
    };
    view()
        .gap_2()
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .child(
                    text_field_with(
                        draft,
                        move || {
                            if saved.get() {
                                "••••••••••••••••".into()
                            } else {
                                tr("Paste your API key")
                            }
                        },
                        |input| input.masked(true),
                    )
                    .flex_1(),
                )
                .child(
                    button(Variant::Default, Size::Md, l("Save"))
                        .disabled(move || draft.with(|d| d.trim().is_empty()))
                        .on_press(save),
                )
                .child(
                    button(Variant::Outline, Size::Md, l("Test"))
                        .disabled(move || !keyless() && !saved.get() && draft.with(|d| d.trim().is_empty()))
                        .on_press(move || {
                            let typed = draft.get_untracked().trim().to_owned();
                            let key = if typed.is_empty() { secrets::read(secret).unwrap_or_default() } else { typed };
                            status.set(tr("Testing…"));
                            test(key, status);
                        }),
                )
                .child(button(Variant::Ghost, Size::Md, l("Remove")).disabled(move || !saved.get()).on_press(
                    move || {
                        if secrets::write(secret, "").is_ok() {
                            saved.set(false);
                            status.set(SharedString::default());
                        }
                    },
                )),
        )
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .child(
                    when(saved, || badge(l("Saved"), || Status::Success))
                        .otherwise(|| badge(l("Setup required"), || Status::Warning)),
                )
                .child(hint(status)),
        )
}

fn test_provider(provider: Provider) -> impl Fn(String, Signal<SharedString>) + Copy + 'static {
    move |key, status| {
        store().run(async move {
            let result = provider.validate_key(&key).await;
            status.try_set(match result {
                Ok(()) => format!("{} {}", provider.name(), tr("key is valid.")).into(),
                Err(failure) => error_text(&failure.code),
            });
        });
    }
}

fn transcription() -> impl IntoElement {
    let store = store();
    let soniox_languages: Vec<(SharedString, SharedString)> = listenook_core::TRANSLATION_LANGUAGES
        .iter()
        .filter(|(code, _)| !code.contains('-') && *code != "yue")
        .map(|(code, name)| ((*code).into(), (*name).into()))
        .chain([("zh".into(), "Chinese".into())])
        .collect();
    view()
        .gap_6()
        .child(section(
            "Soniox",
            panel()
                .child(hint(l(
                    "Speaker labels, word timing, language detection and optional translation during transcription.",
                )))
                .child(field(l("API key"), key_field(Secret::Soniox, || false, test_provider(Provider::Soniox))))
                .child(separator())
                .child(switch(
                    l("Translate during transcription"),
                    move || store.setting(|s| s.soniox_translation.enabled),
                    move |on| {
                        store.update_settings(|s| {
                            s.soniox_translation.enabled = on;
                            if s.soniox_translation.target_language.is_empty() {
                                s.soniox_translation.target_language = "en".into();
                            }
                        })
                    },
                ))
                .child(when(
                    move || store.setting(|s| s.soniox_translation.enabled),
                    move || {
                        field(
                            l("Target language"),
                            select(
                                "Soniox target language",
                                soniox_languages.clone(),
                                move || {
                                    SharedString::from(store.setting(|s| s.soniox_translation.target_language.clone()))
                                },
                                move |value| {
                                    store.update_settings(|s| s.soniox_translation.target_language = value.to_string())
                                },
                            )
                            .w(px(240.0)),
                        )
                    },
                )),
        ))
        .child(section(
            "MOSS Pro",
            panel()
                .child(hint(l(
                    "Multilingual transcription with speaker labels through MOSI. Language and context are automatic.",
                )))
                .child(field(l("API key"), key_field(Secret::Moss, || false, test_provider(Provider::Moss)))),
        ))
        .child(when(local::supported, on_this_mac))
}

fn state_of(models: &'static [Model]) -> ModelState {
    let states: Vec<ModelState> = models.iter().map(local::model_state).collect();
    let size = |model: &Model| model.size() as f64;
    if states.iter().any(|state| matches!(state, ModelState::Downloading(_))) {
        let done: f64 = models
            .iter()
            .zip(&states)
            .map(|(model, state)| match state {
                ModelState::Downloading(fraction) => fraction * size(model),
                ModelState::Ready => size(model),
                _ => 0.0,
            })
            .sum();
        ModelState::Downloading(done / models.iter().map(size).sum::<f64>().max(1.0))
    } else if states.iter().all(|state| *state == ModelState::Ready) {
        ModelState::Ready
    } else if states.iter().any(|state| *state != ModelState::Missing) {
        ModelState::Partial
    } else {
        ModelState::Missing
    }
}

fn model_row(title: &'static str, about: &'static str, models: &'static [Model]) -> impl IntoElement {
    let store = store();
    let state = move || state_of(models);
    let size = listenook_core::format::bytes(models.iter().map(Model::size).sum::<u64>() as i64);
    let failed = move || models.iter().find_map(local::model_error);
    let downloading = move || matches!(state(), ModelState::Downloading(_));
    view()
        .gap_2()
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_3()
                .child(
                    view()
                        .flex_1()
                        .gap_0p5()
                        .child(
                            view()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(text(l(title)).text_sm().font_weight(FontWeight::MEDIUM))
                                .child(when(
                                    move || state() == ModelState::Ready,
                                    || badge(l("Ready"), || Status::Success),
                                )),
                        )
                        .child(hint(move || SharedString::from(format!("{} · {size}", tr(about))))),
                )
                .child(
                    when(downloading, move || {
                        button(Variant::Outline, Size::Sm, l("Cancel")).on_press(move || {
                            models.iter().for_each(local::cancel_download);
                        })
                    })
                    .otherwise(move || {
                        when(
                            move || state() == ModelState::Ready,
                            move || {
                                button(Variant::Ghost, Size::Sm, l("Remove")).on_press(move || {
                                    confirm_destructive(
                                        format!("{} {}?", tr("Remove"), tr(title)),
                                        tr("The download is deleted. You can download it again later."),
                                        tr("Cancel"),
                                        tr("Remove"),
                                        move || models.iter().for_each(local::remove_model),
                                    );
                                })
                            },
                        )
                        .otherwise(move || {
                            button(Variant::Outline, Size::Sm, move || {
                                tr(if state() == ModelState::Partial { "Resume" } else { "Download" })
                            })
                            .on_press(move || {
                                for model in models {
                                    if local::model_state(model) != ModelState::Ready {
                                        local::download_model(store, model);
                                    }
                                }
                            })
                        })
                    }),
                ),
        )
        .child(when(downloading, move || {
            progress_bar(move || match state() {
                ModelState::Downloading(fraction) => Some(fraction as f32),
                _ => None,
            })
        }))
        .child(when(
            move || failed().is_some() && !downloading(),
            move || {
                text(move || error_text(&failed().unwrap_or_default())).text_xs().text_color(|| theme().destructive)
            },
        ))
}

fn on_this_mac() -> impl IntoElement {
    let store = store();
    let ready = |model: &'static Model| local::model_state(model) == ModelState::Ready;
    section(
        l(if cfg!(target_os = "macos") { "On this Mac" } else { "On this device" }),
        panel()
            .child(hint(l("Transcribe without sending audio anywhere. Each model is downloaded once.")))
            .child(model_row(
                "Qwen3",
                "Multilingual; follows a language hint and context terms",
                &[local::catalog::QWEN3],
            ))
            .child(model_row(
                "Qwen3, large",
                "More accurate on difficult audio; several times slower",
                &[local::catalog::QWEN3_LARGE],
            ))
            .child(when(
                move || ready(&local::catalog::QWEN3) && ready(&local::catalog::QWEN3_LARGE),
                move || {
                    field(
                        l("Qwen3 model"),
                        segmented(
                            vec![("0.6b", "Standard"), ("1.7b", "Large")],
                            move || {
                                let large = store.setting(|s| {
                                    s.extra.get("qwen3_local_model").and_then(|v| v.as_str()) == Some("1.7b")
                                });
                                if large { "1.7b" } else { "0.6b" }
                            },
                            move |value: &'static str| {
                                store.update_settings(|s| {
                                    s.extra.insert("qwen3_local_model".into(), value.into());
                                })
                            },
                        ),
                    )
                },
            ))
            .child(separator())
            .child(model_row(
                "Word timing",
                "Needed by Qwen3 for sentence times; highlights each word as it is spoken",
                &[local::catalog::ALIGNER],
            ))
            .child(switch(
                l("Time each word of MOSS transcripts"),
                move || store.setting(|s| s.auto_align_transcripts),
                move |on| store.update_settings(|s| s.auto_align_transcripts = on),
            ))
            .child(when(
                || local::offered(listenook_core::TranscriptionProvider::MossLocal),
                || {
                    view().gap_4().child(separator()).child(model_row(
                        "MOSS",
                        "Multilingual, with speaker labels",
                        &[local::catalog::MOSS],
                    ))
                },
            )),
    )
}

fn ai() -> impl IntoElement {
    let store = store();
    let models = signal(Vec::<String>::new());
    let llm_settings = move || store.setting(|s| s.llm_provider_settings.clone());
    let test = move |key: String, status: Signal<SharedString>| {
        store.run(async move {
            let settings = store.settings().llm_provider_settings;
            match llm::list_models(&settings, Some(key)).await {
                Ok(found) => {
                    if !status.try_set(format!("{} {}", found.len(), tr("models available.")).into()) {
                        return;
                    }
                    if settings.model.is_empty()
                        && let Some(first) = found.first().cloned()
                    {
                        store.update_settings(|s| s.llm_provider_settings.model = first);
                    }
                    models.try_set(found);
                }
                Err(failure) => drop(status.try_set(error_text(&failure.code))),
            }
        });
    };
    view().gap_6().child(section(
        l("AI provider"),
        panel()
            .child(hint(l("One OpenAI-compatible endpoint shared by translation and AI Briefs. Transcript text is sent to it only when you translate or create a brief.")))
            .child(field(
                l("Provider"),
                select(
                    "Provider",
                    LlmProvider::ALL.iter().map(|p| (p.as_str().into(), p.label().into())).collect(),
                    move || SharedString::from(llm_settings().provider.as_str()),
                    move |value| {
                        let provider = LlmProvider::parse(&value);
                        models.set(Vec::new());
                        store.update_settings(|s| {
                            s.llm_provider_settings.provider = provider;
                            if provider != LlmProvider::Custom {
                                s.llm_provider_settings.base_url = provider.base_url().into();
                            }
                            s.llm_provider_settings.model.clear();
                        });
                    },
                )
                .w(px(240.0)),
            ))
            .child(field(
                l("Base URL"),
                settings_input(
                    move || llm_settings().base_url,
                    move |value| store.update_settings(|s| s.llm_provider_settings.base_url = value),
                    "https://api.openai.com/v1",
                ),
            ))
            .child(
                field(l("API key"), key_field(Secret::Llm, move || llm_settings().is_loopback(), test))
                    .child(when(move || llm_settings().is_loopback(), || hint(l("No API key is required for a provider on this computer.")))),
            )
            .child(
                field(
                    l("Model"),
                    when(move || !models.with(Vec::is_empty), move || {
                        select(
                            "Model",
                            models.get_untracked().into_iter().map(|m| (m.clone().into(), m.into())).collect(),
                            move || SharedString::from(llm_settings().model),
                            move |value| store.update_settings(|s| s.llm_provider_settings.model = value.to_string()),
                        )
                    })
                    .otherwise(move || {
                        settings_input(
                            move || llm_settings().model,
                            move |value| store.update_settings(|s| s.llm_provider_settings.model = value),
                            "gpt-4.1-mini",
                        )
                    }),
                )
                .child(hint(l("Press Test to list the models your endpoint offers."))),
            ),
    ))
}

fn settings_input(
    value: impl Fn() -> String + 'static,
    set: impl Fn(String) + 'static,
    placeholder: &'static str,
) -> impl IntoElement {
    bound_field_with(
        value,
        set,
        move || placeholder.into(),
        |input| input.auto_capitalize(AutoCapitalize::None).auto_correct(false),
    )
}

fn shortcuts() -> impl IntoElement {
    let group = |title: &'static str, rows: Vec<(&'static str, &'static str)>| {
        section(
            l(title),
            card().children(rows.into_iter().enumerate().map(|(index, (keystroke, action))| {
                view()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .px_4()
                    .py_2()
                    .when(index > 0, |row| row.border_t_1().border_color(|| theme().border))
                    .child(text(l(action)).text_sm().text_color(|| theme().foreground))
                    .child(key_cap(keystroke))
            })),
        )
    };
    let store = store();
    let anywhere = move || {
        section(
        l("From any app"),
        panel()
            .child(switch(
                l(if cfg!(target_os = "macos") { "Play or pause with ⌃⌥Space" } else { "Play or pause with Ctrl+Alt+Space" }),
                move || store.setting(|s| s.extra.get("global_play_pause").and_then(|v| v.as_bool()).unwrap_or(false)),
                move |on| store.update_settings(|s| drop(s.extra.insert("global_play_pause".into(), on.into()))),
            ))
            .child(hint(l("Works while another app is in front. Off unless you turn it on: it takes the keystroke from every app."))),
    )
    };
    view()
        .gap_6()
        .child(when(|| !crate::platform::is_phone(), anywhere))
        .child(group(
            "Application",
            vec![
                ("mod+1", "Library"),
                ("mod+2", "Podcasts"),
                ("mod+,", "Settings"),
                ("mod+b", "Show or hide the sidebar"),
                ("mod+o", "Add media"),
                ("mod+shift+o", "Open video"),
                ("mod+enter", "Transcribe everything that is ready"),
            ],
        ))
        .child(group(
            "Playback",
            vec![
                ("space", "Play or pause"),
                ("left", "Previous sentence"),
                ("right", "Next sentence"),
                ("r", "Repeat the sentence while held"),
                ("s", "Reveal current sentence"),
                ("e", "Edit current sentence"),
            ],
        ))
        .child(group(
            "Transcript",
            vec![
                ("mod+f", "Search transcript"),
                ("mod+enter", "Save an edit, or check your answer"),
                ("mod+z", "Undo the last sentence change"),
                ("escape", "Cancel an edit, close search, or go back"),
            ],
        ))
}

fn about() -> impl IntoElement {
    let store = store();
    let state = signal(UpdateState::default());
    effect(move || {
        if store.update_check().get() {
            store.update_check().set(false);
            updater::check(state);
        }
    });
    let status = move || -> SharedString {
        match state.get() {
            UpdateState::Idle => SharedString::default(),
            UpdateState::Checking => tr("Checking for updates…"),
            UpdateState::UpToDate => tr("Listenook is up to date."),
            UpdateState::Available(version) => format!("{} {version}", tr("A new version is available:")).into(),
            UpdateState::Manual(version, _) => {
                format!("{} {version}. {}", tr("A new version is available:"), tr("Download it from the release page."))
                    .into()
            }
            UpdateState::Installing => tr("Downloading and installing the update…"),
            UpdateState::Unpackaged => tr("Updates apply to the installed app, not to a development run."),
            UpdateState::Failed(message) => format!("{} {message}", tr("Couldn’t check for updates.")).into(),
        }
    };
    view().gap_6().child(section(
        move || SharedString::from(store.lang().app_name()),
        panel()
            .child(
                view()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(
                        view()
                            .gap_1()
                            .flex_1()
                            .child(text(move || SharedString::from(format!("{} {VERSION}", tr("Version")))).text_sm().text_color(|| theme().foreground))
                            .child(hint(status)),
                    )
                    .child(when(|| updater::SELF_UPDATING, move || {
                        when(move || matches!(state.get(), UpdateState::Available(_)), move || {
                            button(Variant::Primary, Size::Md, l("Restart to update"))
                                .on_press(move || updater::install_and_restart(state))
                        })
                        .otherwise(move || {
                            button(Variant::Default, Size::Md, l("Check for updates"))
                                .disabled(move || matches!(state.get(), UpdateState::Checking | UpdateState::Installing))
                                .on_press(move || updater::check(state))
                        })
                    })),
            )
            .child(when(move || matches!(state.get(), UpdateState::Manual(..)), move || {
                button(Variant::Outline, Size::Md, l("Open release page")).self_start().on_press(move || {
                    if let UpdateState::Manual(_, url) = state.get_untracked() {
                        drop(open_url(url.to_string()));
                    }
                })
            })),
    ))
    .child(section(
        l("Privacy"),
        panel().child(
            text(l("Listenook has no backend. Cloud transcription sends media directly to the provider you choose when you start a job; translation and AI Briefs send transcript text to your AI endpoint. API keys are kept in the system’s secure storage, or on Android and Linux in a file only Listenook can read. Transcripts and settings stay on this device."))
                .text_sm()
                .text_color(|| theme().muted_foreground),
        ),
    ))
}

fn choose_watched_folder() {
    let answer = pick_paths(nsh_core::file_dialog::OpenDialog::folders());
    store().run(async move {
        if let Ok(Some(paths)) = answer.await
            && let Some(folder) = paths.first().and_then(|path| path.to_str())
        {
            store().watch_folder(folder);
        }
    });
}
